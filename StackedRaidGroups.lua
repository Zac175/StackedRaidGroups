--[[---------------------------------------------------------------------------
	StackedRaidGroups  v1.1.4

	Wraps the new (Edit Mode / patch 1.15.9, 2.5.6 and WoW Forever) raid frames' separate groups
	into rows, e.g. Groups 1-4 on the first row with Groups 5-8 stacked
	directly beneath them. Main Tank / Main Assist frames and pet frames
	can be placed on any side of the group grid.

	Requirement: raid frames must be showing SEPARATE groups
	("Keep Groups Together"), not combined groups.

	/srg          -> open the options window
	/srg help     -> list chat commands

	v1.1.4
	- WoW Forever (1.60.1) support. Its raid frames are the same Edit Mode
	  frames with three differences this version accounts for: the
	  container also re-flows on LFG_UPDATE (now held by the combat guard
	  along with the roster and pet events, and only where the container
	  really listens for it); the container re-measures itself one frame
	  after every layout (the grid's size is put back in the same frame);
	  and the game can hide a frame's size, place or protection from addons
	  (such a pass is skipped and retried, never an error).
	- A layout pass that fails for any reason can no longer repeat its
	  error several times a second: it is reported once (/srg status shows
	  it) and tried again at the next roster change or combat end.

	v1.1.3
	- Dual-client packaging: one folder now loads on both WoW Classic Era
	  (1.15.9) and Burning Crusade Anniversary (2.5.6) via client-specific
	  TOC files (_Vanilla / _TBC, shared fallback kept). Both clients run
	  the same modern raid-frame UI code, so no gameplay code changed.

	v1.1.0
	- Combat guard: mid-combat roster changes (logoffs, leaves, subgroup
	  moves) no longer snap the frames back to the game's single-line
	  layout. The game's container re-flows on GROUP_ROSTER_UPDATE /
	  UNIT_PET; each CompactRaidGroup frame separately registers
	  GROUP_ROSTER_UPDATE and keeps its own members current. So while in
	  combat we unregister those two events on the CONTAINER ONLY (event
	  registration is not a protected operation - no taint, no blocked
	  actions) and the grid simply never gets disturbed, while member
	  frames keep updating through each group's own secure handler.
	  Frames that would need to be CREATED mid-combat (new pets, MT/MA
	  changes, someone joining an empty group) wait for combat end; a
	  roster event is deliberately let through if a whole group frame is
	  missing, so new players are never left invisible.
-----------------------------------------------------------------------------]]

local PREFIX = "|cff33ff99StackedRaidGroups|r: "
local VERSION = "1.1.4"

local POSITIONS = { "TOP", "BOTTOM", "LEFT", "RIGHT" }
local POSITION_LABELS = { TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right" }
local VALID_POSITION = { TOP = true, BOTTOM = true, LEFT = true, RIGHT = true }

local defaults = {
	groupsPerRow = 4,
	xGap = 2,
	yGap = 2,
	resizeContainer = true,
	keepEmptySlots = false,
	combatNotice = true,
	loginMessage = true,
	combatGuard = true,
	fillOrder = "rows", -- "rows" (1-4 on top) or "columns" (1,3,5,7 on top)
	tanks = { position = "TOP",    gap = 6, perLine = 4, offsetX = 0, offsetY = 0,
		showTargets = true },
	pets  = { position = "BOTTOM", gap = 6, perLine = 4, offsetX = 0, offsetY = 0 },
}

local db
local pendingUpdate = false -- a re-stack is waiting for combat to end
local isRestacking = false  -- reentrancy guard (our own SetSize can re-trigger layout)
local queued = false        -- a deferred settle pass is already scheduled
local lastPlan = nil        -- snapshot of target positions, used by the watchdog
local combatGroupMoveBlocked = nil -- nil=untested, false=engine allows, true=engine blocks
local noticeShownThisCombat = false
local managing = false        -- true while separate raid groups are on screen
local guardActive = false     -- container roster events currently unregistered
local suppressedEvents = 0    -- roster/pet events swallowed this combat
local lastError = nil         -- text of the last layout pass that failed
local errorShown = false      -- its one chat line was printed this session
local hiddenPasses = 0        -- passes skipped because the game hid a value

-- WoW Forever (and any client with "secret values") can hand an addon a
-- value it may not read: comparing it or doing arithmetic with it is a Lua
-- error. The engine documents a frame's size and place as hidden while its
-- anchoring is hidden, and IsProtected() as hidden for some objects. Raid
-- group frames are not normally in that state, but a pass that meets one
-- must stop cleanly and try again later, not throw. On Classic Era and
-- Burning Crusade there is no such thing and these helpers cost nothing.
local issecretvalue = _G.issecretvalue
local HIDDEN = {} -- thrown (as a value) to abandon a pass that met a hidden value
local function IsHidden(v)
	return issecretvalue ~= nil and issecretvalue(v) or false
end
local function Plain(...)
	if issecretvalue ~= nil then
		for i = 1, select("#", ...) do
			if issecretvalue((select(i, ...))) then
				error(HIDDEN, 0)
			end
		end
	end
	return ...
end

local function CopyDefaults(src, dst)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			CopyDefaults(v, dst[k])
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

-------------------------------------------------------------------------------
-- Frame discovery

-- Returns three ordered lists of shown frames belonging to the raid container:
--   flagged : Main Tank / Main Assist (and their target) frames
--   groups  : CompactRaidGroup1..8 group frames
--   pets    : pet frames (anything Blizzard adds after the groups)
local function CollectLayoutFrames(container)
	local flagged, groups, pets = {}, {}, {}

	-- Preferred source: the container's own flow list, which preserves the
	-- order Blizzard intended (flagged units first, then groups, then pets).
	local list = container.flowFrames
	if type(list) == "table" then
		local seenGroup = false
		for i = 1, #list do
			local obj = list[i]
			if type(obj) == "table" and obj.IsShown and obj:IsShown() then
				local name = (obj.GetName and obj:GetName()) or ""
				if name:match("^CompactRaidGroup%d+$") then
					seenGroup = true
					groups[#groups + 1] = obj
				elseif seenGroup then
					pets[#pets + 1] = obj
				else
					flagged[#flagged + 1] = obj
				end
			end
		end
	end

	-- Fallbacks in case the flow list is empty / renamed in a future build.
	if #groups == 0 then
		for i = 1, 8 do
			local g = _G["CompactRaidGroup" .. i]
			if g and g:IsShown() then
				groups[#groups + 1] = g
			end
		end
	end
	if type(list) ~= "table" and #groups > 0 then
		for _, child in ipairs({ container:GetChildren() }) do
			if child:IsShown() and child.unit then
				local name = (child.GetName and child:GetName()) or ""
				if not name:match("^CompactRaidGroup%d+$") then
					if tostring(child.unit):find("pet") then
						pets[#pets + 1] = child
					else
						flagged[#flagged + 1] = child
					end
				end
			end
		end
	end

	-- Stale-flow safety net: while the combat guard holds (and right after
	-- combat, before Blizzard's next pass), the container's flow list can
	-- lag reality - e.g. a group frame we re-show at combat end. A shown
	-- group the flow list missed must still be laid out, or it would sit
	-- wherever it was left and overlap the grid.
	local seen = {}
	for _, g in ipairs(groups) do seen[g] = true end
	local appended = false
	for i = 1, 8 do
		local g = _G["CompactRaidGroup" .. i]
		if g and g:IsShown() and not seen[g] then
			groups[#groups + 1] = g
			appended = true
		end
	end
	if appended then
		table.sort(groups, function(a, b)
			local na = tonumber(((a:GetName() or ""):match("CompactRaidGroup(%d+)")) or 99) or 99
			local nb = tonumber(((b:GetName() or ""):match("CompactRaidGroup(%d+)")) or 99) or 99
			return na < nb
		end)
	end

	return flagged, groups, pets
end

-- A group frame can be "shown" while not actually rendering members - either
-- genuinely empty, or the game has stopped drawing it/them (seen after heavy
-- roster churn). Judge by real on-screen visibility, children first (their
-- parentage is authoritative), with named-member lookup as a fallback.
local function GroupHasVisibleMembers(group)
	local sawUnitChild = false
	for _, child in ipairs({ group:GetChildren() }) do
		if child.unit ~= nil then
			sawUnitChild = true
			if child:IsVisible() then
				return true
			end
		end
	end
	if sawUnitChild then
		return false
	end
	local name = group.GetName and group:GetName()
	if name then
		for j = 1, 5 do
			local m = _G[name .. "Member" .. j]
			if m and m:GetParent() == group and m:IsVisible() then
				return true
			end
		end
		if _G[name .. "Member1"] then
			return false -- member frames exist and none render inside this group
		end
	end
	return true -- couldn't identify member frames; assume the group is real
end

-------------------------------------------------------------------------------
-- Core layout

local QueueRestack -- forward declaration

-- Re-run the layout whenever Blizzard resizes one of the frames we manage
-- (e.g. a group growing when a member joins it).
local sizeHooked = {}
local function EnsureSizeHook(frame)
	if not sizeHooked[frame] then
		sizeHooked[frame] = true
		frame:HookScript("OnSizeChanged", function()
			if not isRestacking then
				QueueRestack()
			end
		end)
	end
end

-- Measures a list of frames into a block laid out either in horizontal lines
-- (wrapping after perLine frames) or vertical columns (wrapping after perLine
-- frames per column). Returns { placements = {{frame,x,y},...}, width, height }
-- with x/y relative to the block's own top-left, y growing downward.
local function MeasureBlock(frames, perLine, vertical, xGap, yGap)
	local block = { placements = {}, width = 0, height = 0 }
	if #frames == 0 then return block end
	perLine = math.max(1, math.floor(perLine or 4))

	if not vertical then
		local x, y, lineH, count = 0, 0, 0, 0
		for _, fr in ipairs(frames) do
			if count >= perLine then
				block.width = math.max(block.width, x - xGap)
				y = y + lineH + yGap
				x, lineH, count = 0, 0, 0
			end
			local w, h = Plain(fr:GetSize())
			block.placements[#block.placements + 1] = { frame = fr, x = x, y = y }
			x = x + (w or 0) + xGap
			lineH = math.max(lineH, h or 0)
			count = count + 1
		end
		block.width = math.max(block.width, x - xGap)
		block.height = y + lineH
	else
		local x, y, colW, count = 0, 0, 0, 0
		for _, fr in ipairs(frames) do
			if count >= perLine then
				block.height = math.max(block.height, y - yGap)
				x = x + colW + xGap
				y, colW, count = 0, 0, 0
			end
			local w, h = Plain(fr:GetSize())
			block.placements[#block.placements + 1] = { frame = fr, x = x, y = y }
			y = y + (h or 0) + yGap
			colW = math.max(colW, w or 0)
			count = count + 1
		end
		block.height = math.max(block.height, y - yGap)
		block.width = x + colW
	end
	return block
end

-- The flagged section isn't uniform: each Main Tank / Assist frame comes
-- with small target (and target-of-target) mini-frames. Group them into
-- per-tank "cells" so the little target frames sit tucked directly beneath
-- their tank instead of being wrapped through the grid as equal items.
local function BuildFlaggedCells(flagged)
	local cells = {}
	local current
	for _, fr in ipairs(flagged) do
		local unit = tostring(fr.unit or fr.displayedUnit or "")
		local isTargetFrame = unit:find("target", 1, true) ~= nil
		if isTargetFrame and current then
			current[#current + 1] = fr
		else
			current = { fr }
			cells[#cells + 1] = current
		end
	end
	return cells
end

-- Like MeasureBlock, but the wrapped items are whole cells (tank + its
-- target frames stacked vertically inside the cell). perLine counts CELLS,
-- i.e. tanks per line, so mixed frame sizes can never overlap.
local FLAGGED_INNER_GAP = 1
local function MeasureFlaggedBlock(cells, perLine, vertical, xGap, yGap)
	local block = { placements = {}, width = 0, height = 0 }
	if #cells == 0 then return block end
	perLine = math.max(1, math.floor(perLine or 4))

	local sizes = {}
	for i, cell in ipairs(cells) do
		local w, h = 0, 0
		for _, fr in ipairs(cell) do
			local fw, fh = Plain(fr:GetSize())
			w = math.max(w, fw or 0)
			h = h + (fh or 0) + FLAGGED_INNER_GAP
		end
		sizes[i] = { w = w, h = h - FLAGGED_INNER_GAP }
	end

	local function placeCell(cell, x, y)
		local cy = y
		for _, fr in ipairs(cell) do
			block.placements[#block.placements + 1] = { frame = fr, x = x, y = cy }
			local _, fh = Plain(fr:GetSize())
			cy = cy + (fh or 0) + FLAGGED_INNER_GAP
		end
	end

	if not vertical then
		local x, y, lineH, count = 0, 0, 0, 0
		for i, cell in ipairs(cells) do
			if count >= perLine then
				block.width = math.max(block.width, x - xGap)
				y = y + lineH + yGap
				x, lineH, count = 0, 0, 0
			end
			placeCell(cell, x, y)
			x = x + sizes[i].w + xGap
			lineH = math.max(lineH, sizes[i].h)
			count = count + 1
		end
		block.width = math.max(block.width, x - xGap)
		block.height = y + lineH
	else
		local x, y, colW, count = 0, 0, 0, 0
		for i, cell in ipairs(cells) do
			if count >= perLine then
				block.height = math.max(block.height, y - yGap)
				x = x + colW + xGap
				y, colW, count = 0, 0, 0
			end
			placeCell(cell, x, y)
			y = y + sizes[i].h + yGap
			colW = math.max(colW, sizes[i].w)
			count = count + 1
		end
		block.height = math.max(block.height, y - yGap)
		block.width = x + colW
	end
	return block
end

-- Where does a side-section start, relative to the grid's top-left?
-- `occupied` tracks how much space earlier sections already took on each side,
-- so tanks and pets can share a side without overlapping.
local function SectionOrigin(cfg, blockW, blockH, grid, occupied)
	local pos = VALID_POSITION[cfg.position] and cfg.position or "TOP"
	local gap = cfg.gap or 6
	local x, y
	if pos == "TOP" then
		x = 0
		y = -(blockH + gap) - (occupied.TOP or 0)
		occupied.TOP = (occupied.TOP or 0) + blockH + gap
	elseif pos == "BOTTOM" then
		x = 0
		y = grid.height + gap + (occupied.BOTTOM or 0)
		occupied.BOTTOM = (occupied.BOTTOM or 0) + blockH + gap
	elseif pos == "LEFT" then
		x = -(blockW + gap) - (occupied.LEFT or 0)
		y = 0
		occupied.LEFT = (occupied.LEFT or 0) + blockW + gap
	else -- RIGHT
		x = grid.width + gap + (occupied.RIGHT or 0)
		y = 0
		occupied.RIGHT = (occupied.RIGHT or 0) + blockW + gap
	end
	return x + (cfg.offsetX or 0), y + (cfg.offsetY or 0)
end

-- Is this frame already sitting exactly where we want it?
local function PointMatches(fr, anchorFrame, x, y)
	if Plain(fr:GetNumPoints()) ~= 1 then return false end
	local point, rel, relPoint, cx, cy = Plain(fr:GetPoint(1))
	return point == "TOPLEFT" and rel == anchorFrame and relPoint == "TOPLEFT"
		and cx and cy and math.abs(cx - x) < 0.5 and math.abs(cy - y) < 0.5
end

local function BlockNeedsMove(anchorFrame, block, originX, originY)
	for _, p in ipairs(block.placements) do
		if not PointMatches(p.frame, anchorFrame, originX + p.x, -(originY + p.y)) then
			return true
		end
	end
	return false
end

-- Only touches frames whose target position actually changed; everything
-- already in place is left completely alone.
local function ApplyBlock(anchorFrame, block, originX, originY)
	for _, p in ipairs(block.placements) do
		local fr = p.frame
		local x = originX + p.x
		local y = -(originY + p.y)
		if not PointMatches(fr, anchorFrame, x, y) then
			fr:ClearAllPoints()
			fr:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", x, y)
		end
	end
end

-- Fixed screen anchor for the grid. The grid is pinned to this (not to the
-- Blizzard container) so that Blizzard resizing/re-anchoring its container
-- mid-combat cannot drag the visible grid around. Synced to the container's
-- top-left only out of combat (i.e. it tracks Edit Mode positioning).
local anchor = CreateFrame("Frame", nil, UIParent)
anchor:SetSize(1, 1)
anchor:SetPoint("TOPLEFT", UIParent, "CENTER")
local anchorSynced = false

local function SyncAnchor(container)
	local left, top = container:GetLeft(), container:GetTop()
	if IsHidden(left) or IsHidden(top) then return end -- (not readable right now)
	if not left or not top then return end
	local cs, us = container:GetEffectiveScale(), UIParent:GetEffectiveScale()
	if IsHidden(cs) or IsHidden(us) then return end
	local scale = cs / us
	local tx, ty = left * scale, top * scale
	local ax, ay = anchor:GetLeft(), anchor:GetTop()
	if IsHidden(ax) or IsHidden(ay) then ax, ay = nil, nil end
	if anchorSynced and ax and ay
		and math.abs(ax - tx) < 0.5 and math.abs(ay - ty) < 0.5 then
		return -- already pinned to the right spot
	end
	anchor:ClearAllPoints()
	anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", tx, ty)
	anchorSynced = true
end

local function RestackNow()
	if not db or isRestacking then return end

	local container = _G.CompactRaidFrameContainer
	if not container then return end

	local flagged, groups, pets = CollectLayoutFrames(container)
	if #groups == 0 then
		-- Combined-groups mode, or not currently in a raid. Nothing to do.
		managing = false
		lastPlan = nil
		return
	end
	managing = true

	-- Optionally hide the Main Tank target / target-of-target mini-frames
	-- (self-targeting as MT shows you twice; some prefer them gone). They
	-- must still be managed, so they get parked with the empties.
	local parkedTargets = {}
	if db.tanks and db.tanks.showTargets == false and #flagged > 0 then
		local kept = {}
		for _, fr in ipairs(flagged) do
			if tostring(fr.unit or ""):find("target", 1, true) then
				parkedTargets[#parkedTargets + 1] = fr
			else
				kept[#kept + 1] = fr
			end
		end
		flagged = kept
	end

	-- Make sure every managed frame re-triggers us if Blizzard resizes it
	-- (idempotent; must happen even on passes that end up changing nothing).
	for _, fr in ipairs(groups) do EnsureSizeHook(fr) end
	for _, fr in ipairs(flagged) do EnsureSizeHook(fr) end
	for _, fr in ipairs(pets) do EnsureSizeHook(fr) end

	-- Groups that are shown but have no visible members (e.g. everyone left
	-- them after a raid) must not occupy grid slots - they'd hold invisible
	-- full-width columns and shove the real groups around. With
	-- keepEmptySlots enabled the user instead wants group-number-stable
	-- slots, so empties stay in the sequence.
	local activeGroups, emptyGroups = {}, {}
	if db.keepEmptySlots then
		activeGroups = groups
	else
		for _, g in ipairs(groups) do
			if GroupHasVisibleMembers(g) then
				activeGroups[#activeGroups + 1] = g
			else
				emptyGroups[#emptyGroups + 1] = g
			end
		end
		if #activeGroups == 0 then
			-- Detection came up empty-handed; fall back to treating
			-- everything as active rather than laying out nothing.
			activeGroups, emptyGroups = groups, {}
		end
	end

	-- ---- Plan (read-only): measure everything and work out target positions.

	local xGap = db.xGap or 2
	local yGap = db.yGap or 2

	-- Horizontal groups (members side by side) make a 4-wide grid span the
	-- whole screen. Unless the user explicitly chose a row count, default
	-- horizontal setups to 1 group per row. Decided once, announced in chat.
	if not db.rowsCustomized and not db.autoRowsDone then
		local sniff = activeGroups[1]
		for _, g in ipairs(activeGroups) do
			if GroupHasVisibleMembers(g) then sniff = g break end
		end
		local gw, gh = Plain(sniff:GetSize())
		if gw and gh and gh > 0 and gw > gh * 1.5 then
			db.groupsPerRow = 1
			db.autoRowsDone = true
			print(PREFIX .. "horizontal groups detected - defaulting to 1 group per row."
				.. " Change it with /srg rows <n> or in /srg.")
		elseif gw and gh and gw > 0 and gh > gw * 1.5 then
			db.autoRowsDone = true -- vertical confirmed; keep the normal default
		end
	end

	local perRow = math.max(1, math.min(8, db.groupsPerRow or 4))

	-- Fill order "columns": groups run down each column instead of across
	-- each row, so with 4 per row you get 1,3,5,7 on top and 2,4,6,8 below.
	local layoutPerRow = perRow
	if db.fillOrder == "columns" and #activeGroups > perRow then
		local n = #activeGroups
		local numRows = math.ceil(n / perRow)
		local numCols = math.ceil(n / numRows)
		local reordered = {}
		for r = 0, numRows - 1 do
			for c = 0, numCols - 1 do
				local src = c * numRows + r + 1
				if src <= n then
					reordered[#reordered + 1] = activeGroups[src]
				end
			end
		end
		activeGroups = reordered
		layoutPerRow = numCols
	end

	local grid = MeasureBlock(activeGroups, layoutPerRow, false, xGap, yGap)

	local occupied = {}
	local tankBlock, tankX, tankY
	if #flagged > 0 then
		local cfg = db.tanks
		local vertical = (cfg.position == "LEFT" or cfg.position == "RIGHT")
		local cells = BuildFlaggedCells(flagged)
		tankBlock = MeasureFlaggedBlock(cells, cfg.perLine, vertical, xGap, yGap)
		tankX, tankY = SectionOrigin(cfg, tankBlock.width, tankBlock.height, grid, occupied)
	end
	local petBlock, petX, petY
	if #pets > 0 then
		local cfg = db.pets
		local vertical = (cfg.position == "LEFT" or cfg.position == "RIGHT")
		petBlock = MeasureBlock(pets, cfg.perLine, vertical, xGap, yGap)
		petX, petY = SectionOrigin(cfg, petBlock.width, petBlock.height, grid, occupied)
	end

	-- Park empty groups well clear of the grid and of any side sections
	-- (they usually render nothing but a faint title, but they must still be
	-- managed or Blizzard's flow would drop them on top of the grid).
	local emptyBlock
	local parkedFrames = {}
	for _, g in ipairs(emptyGroups) do parkedFrames[#parkedFrames + 1] = g end
	for _, fr in ipairs(parkedTargets) do parkedFrames[#parkedFrames + 1] = fr end
	if #parkedFrames > 0 then
		emptyBlock = { placements = {}, width = 0, height = 0 }
		local px = grid.width + (occupied.RIGHT or 0) + 100
		for _, fr in ipairs(parkedFrames) do
			emptyBlock.placements[#emptyBlock.placements + 1] = { frame = fr, x = px, y = 0 }
		end
	end

	-- ---- Per-section combat handling. Group container frames are usually
	-- movable even in combat; the MT/pet frames are secure unit buttons and
	-- never are. Gate each section on ITS OWN frames, so one protected tank
	-- button can't freeze the whole grid for an entire fight.

	local inCombat = InCombatLockdown()
	local function sectionLocked(frames)
		if not inCombat then return false end
		for _, fr in ipairs(frames) do
			-- (an answer the game will not let us read counts as protected)
			local protected = fr:IsProtected()
			if IsHidden(protected) or protected then return true end
		end
		return false
	end

	local sections = {
		{ block = grid,       ox = 0,     oy = 0,     frames = activeGroups, isGrid = true },
	}
	if tankBlock then
		sections[#sections + 1] = { block = tankBlock, ox = tankX, oy = tankY, frames = flagged }
	end
	if petBlock then
		sections[#sections + 1] = { block = petBlock, ox = petX, oy = petY, frames = pets }
	end
	if emptyBlock then
		sections[#sections + 1] = { block = emptyBlock, ox = 0, oy = 0, frames = parkedFrames }
	end

	local touchable = {}
	local deferredAny = false
	local gridDeferred = false
	for _, sec in ipairs(sections) do
		local locked = sectionLocked(sec.frames)
		if sec.isGrid and inCombat then
			if combatGroupMoveBlocked == true then
				-- The engine already refused group moves this session;
				-- don't burn attempts every roster event.
				locked = true
			elseif locked then
				combatGroupMoveBlocked = true
			end
		end
		if locked then
			deferredAny = true
			if sec.isGrid then gridDeferred = true end
		else
			touchable[#touchable + 1] = sec
		end
	end
	if deferredAny then
		pendingUpdate = true -- repaired the moment combat drops
	end

	local relTo = anchorSynced and anchor or container

	-- One-line heads-up (once per combat) the moment the engine locks a
	-- broken layout in, so healers instantly know it's the known limitation
	-- and that the game's default row applies until combat ends.
	if gridDeferred and db.combatNotice ~= false and not noticeShownThisCombat
		and BlockNeedsMove(relTo, grid, 0, 0) then
		noticeShownThisCombat = true
		print(PREFIX .. "the game locked the raid frame layout for this fight"
			.. " (roster changed in combat). Default row until combat ends,"
			.. " then the grid restores itself. /srg notice off to silence.")
		-- On-screen flash too: a healer mid-cast needs to know their frame
		-- positions just became invalid BEFORE the next mouseover heal.
		if UIErrorsFrame and UIErrorsFrame.AddMessage then
			UIErrorsFrame:AddMessage(
				"Raid frames re-arranged by combat - positions changed!",
				1.0, 0.35, 0.35)
		end
	end

	-- ---- Decide: does anything we're allowed to touch need to change?

	local needResize = false
	if db.resizeContainer ~= false and not inCombat
		and grid.width > 0 and grid.height > 0 then
		local cw, ch = Plain(container:GetSize())
		needResize = math.abs(cw - grid.width) > 0.5 or math.abs(ch - grid.height) > 0.5
	end

	local needMove = false
	for _, sec in ipairs(touchable) do
		if BlockNeedsMove(relTo, sec.block, sec.ox, sec.oy) then
			needMove = true
			break
		end
	end

	-- Snapshot builder: the watchdog only polices sections we actually manage
	-- right now, so deferred (combat-locked) sections can't make it spin.
	local function BuildPlan(secs)
		local plan = { relTo = relTo }
		if db.resizeContainer ~= false and not inCombat
			and grid.width > 0 and grid.height > 0 then
			plan.width, plan.height = grid.width, grid.height
		end
		for _, sec in ipairs(secs) do
			for _, p in ipairs(sec.block.placements) do
				local w, h = Plain(p.frame:GetSize())
				plan[#plan + 1] = {
					frame = p.frame, x = sec.ox + p.x, y = -(sec.oy + p.y), w = w, h = h,
				}
			end
		end
		return plan
	end

	if not needResize and not needMove then
		-- Everything we may touch is already exactly where it belongs. Still
		-- track Edit Mode positioning: if the container was dragged, moving
		-- the anchor carries the whole grid along automatically.
		if not inCombat then
			SyncAnchor(container)
		end
		lastPlan = BuildPlan(touchable)
		return
	end

	-- ---- Apply.

	isRestacking = true

	-- Keep the container's rect matching the group grid (out of combat only;
	-- resizing it inside a combat-time update can re-enter Blizzard's layout
	-- code in a state where it is blocked from showing member frames).
	if needResize then
		pcall(container.SetSize, container, grid.width, grid.height)
	end
	if not inCombat then
		-- Track Edit Mode positioning: pin the screen anchor to the
		-- container's (post-resize) top-left.
		SyncAnchor(container)
	end

	-- The engine can reject an in-combat move of a restricted frame with a
	-- HARD LUA ERROR (secure frame anchoring restriction), not just a
	-- silent no-op. An uncaught error here would abort the pass with
	-- isRestacking still true, freezing the addon for the whole session -
	-- so every section's application is pcall'd, and a rejected section is
	-- simply treated as combat-deferred.
	local applied = {}
	for _, sec in ipairs(touchable) do
		local ok = pcall(ApplyBlock, relTo, sec.block, sec.ox, sec.oy)
		if ok then
			applied[#applied + 1] = sec
		else
			pendingUpdate = true
			if sec.isGrid then combatGroupMoveBlocked = true end
		end
	end

	-- In combat, the engine can also refuse individual moves silently even
	-- when IsProtected() said we were clear. Verify per section; any
	-- section that didn't land is dropped from the watchdog's plan (so it
	-- can't spin on blocked calls) and repaired when combat ends.
	local landedSections = applied
	if inCombat then
		landedSections = {}
		for _, sec in ipairs(applied) do
			if BlockNeedsMove(relTo, sec.block, sec.ox, sec.oy) then
				pendingUpdate = true
				if sec.isGrid then combatGroupMoveBlocked = true end
			else
				landedSections[#landedSections + 1] = sec
				if sec.isGrid then combatGroupMoveBlocked = false end
			end
		end
	end

	if #landedSections > 0 then
		lastPlan = BuildPlan(landedSections)
	else
		lastPlan = nil
	end

	isRestacking = false
end

-- Every pass goes through here. A pass that cannot finish - the game hid a
-- value from us, or anything unforeseen in a client build this was not
-- written against - must not throw out of Blizzard's layout hook, and must
-- not be retried by the watchdog several times a second. It is dropped,
-- remembered for /srg status, announced once, and the layout is tried again
-- at the next roster change, Edit Mode change or combat end.
local function Restack()
	local ok, err = pcall(RestackNow)
	if ok then return end
	isRestacking = false
	lastPlan = nil -- nothing for the watchdog to police until a pass lands
	if err == HIDDEN then
		hiddenPasses = hiddenPasses + 1
		pendingUpdate = true
		return
	end
	lastError = tostring(err)
	if not errorShown then
		errorShown = true
		print(PREFIX .. "a layout pass failed and was skipped (the raid frames"
			.. " keep the game's own layout until the next one works)."
			.. " /srg status shows the error - please report it.")
	end
end

-- A deferred, debounced settle pass. Restack() already runs synchronously
-- inside Blizzard's layout hooks; this only re-applies the identical layout
-- afterwards, so it never causes a visible change of its own.
QueueRestack = function()
	if queued then return end
	queued = true
	C_Timer.After(0, function()
		queued = false
		Restack()
	end)
end

-------------------------------------------------------------------------------
-- Combat guard: prevent the mid-combat break instead of repairing it.
--
-- The engine rule that breaks the grid: during combat, Blizzard's SECURE
-- container code re-flows all frames into one line on every roster event,
-- and our INSECURE code is then forbidden from moving them back.
--
-- But the container only re-flows because IT listens for
-- GROUP_ROSTER_UPDATE / UNIT_PET. Each CompactRaidGroup frame ALSO
-- registers GROUP_ROSTER_UPDATE itself and keeps its own members mapped
-- and shown/hidden through Blizzard's own (secure) handler. So while in
-- combat we unregister those two events on the CONTAINER ONLY:
--   * the one-line re-flow never runs -> the stacked grid is untouched;
--   * members still update live (offline greying, leavers hiding,
--     joiners appearing inside already-shown groups) via the groups'
--     own secure handlers.
-- Event (un)registration is not a protected operation and writes no Lua
-- state the secure code reads, so this is combat-legal and taint-free.
--
-- What CAN'T update while guarded: frames that don't exist yet (a newly
-- summoned pet, a new MT/MA assignment, a player joining a group whose
-- frame was never shown). Pets/MT wait for combat end. A missing GROUP
-- frame means an invisible player, so for that one case we re-register
-- and deliberately let the next roster event through (accepting one
-- re-flow, which is what would have happened anyway) - then re-arm.

-- WoW Forever's container re-flows on a third event, LFG_UPDATE (it does the
-- same full update as a roster change). It is held with the other two, but
-- only on a client whose container really listens for it, and it is only
-- given back if we were the ones who took it - Classic Era's and Burning
-- Crusade's container never registers it and must not start to.
local guardHeldLFG = false

local function GuardArm()
	if guardActive or not db or db.combatGuard == false or not managing then
		return
	end
	local container = _G.CompactRaidFrameContainer
	if not container then return end
	container:UnregisterEvent("GROUP_ROSTER_UPDATE")
	container:UnregisterEvent("UNIT_PET")
	guardHeldLFG = false
	local okR, listening = pcall(container.IsEventRegistered, container, "LFG_UPDATE")
	if okR and listening and not IsHidden(listening) then
		if pcall(container.UnregisterEvent, container, "LFG_UPDATE") then
			guardHeldLFG = true
		end
	end
	guardActive = true
end

local function GuardDisarm()
	if not guardActive then return end
	local container = _G.CompactRaidFrameContainer
	if container then
		container:RegisterEvent("GROUP_ROSTER_UPDATE")
		container:RegisterEvent("UNIT_PET")
		if guardHeldLFG then
			pcall(container.RegisterEvent, container, "LFG_UPDATE")
		end
	end
	guardHeldLFG = false
	guardActive = false
end

-- Does the current roster include someone whose group frame isn't on
-- screen? (Read-only; safe to call from any context.)
local function RosterNeedsNewGroupFrames()
	if not IsInRaid() then return false end
	for i = 1, GetNumGroupMembers() do
		local name, _, subgroup = GetRaidRosterInfo(i)
		if name and subgroup then
			-- Respect the user's group filter buttons: a group the user
			-- chose to hide is not "missing". (pcall: another addon
			-- replacing the filter table must not break the guard.)
			local okF, filteredOut = pcall(function()
				return _G.CRF_GetFilterGroup
					and not _G.CRF_GetFilterGroup(subgroup)
			end)
			local hiddenByFilter = okF and filteredOut
			if not hiddenByFilter then
				local f = _G["CompactRaidGroup" .. subgroup]
				if not f or not f:IsShown() then
					return true
				end
			end
		end
	end
	return false
end

-- Combat is over: bring group VISIBILITY back in line with the roster
-- ourselves instead of waiting for the game's next roster event. While
-- the guard held, each group's member frames were kept fully current by
-- the group's own secure handler (that runs even for hidden frames) -
-- the only things the suppressed container pass would have changed at
-- group level are Show/Hide of the group frames themselves. Group frames
-- are unprotected, so out of combat we may do that part directly:
--   * a roster-used group whose existing frame is hidden -> Show it
--     (a player moved/joined into it mid-fight);
--   * a shown group no one occupies anymore -> Hide it (it emptied
--     mid-fight), unless the user keeps empty slots.
-- Frames that must be CREATED by the game (a group frame that never
-- existed, new pets, MT/MA changes) still wait for its next pass.
local function ReconcileGroupVisibility()
	if InCombatLockdown() or not IsInRaid() then return end
	local used = {}
	for i = 1, GetNumGroupMembers() do
		local name, _, subgroup = GetRaidRosterInfo(i)
		if name and subgroup then used[subgroup] = true end
	end
	for g = 1, 8 do
		local f = _G["CompactRaidGroup" .. g]
		if f then
			local okF, filteredOut = pcall(function()
				return _G.CRF_GetFilterGroup and not _G.CRF_GetFilterGroup(g)
			end)
			local hiddenByFilter = okF and filteredOut
			if used[g] and not hiddenByFilter and not f:IsShown() then
				f:Show()
			elseif not used[g] and f:IsShown() and not db.keepEmptySlots then
				f:Hide()
			end
		end
	end
end

-- Anything container-level gone stale while the guard held? Used only to
-- tell the user at combat end that the game will fill things in on the
-- next roster update. Read-only.
local function ContainerLevelStale()
	local container = _G.CompactRaidFrameContainer
	if not container or not IsInRaid() then return false end
	if RosterNeedsNewGroupFrames() then return true end
	local flagged, _, pets = CollectLayoutFrames(container)
	if container.displayPets then
		local shown = {}
		for _, fr in ipairs(pets) do shown[tostring(fr.unit or "")] = true end
		for i = 1, (_G.MAX_RAID_MEMBERS or 40) do
			local u = "raidpet" .. i
			if UnitExists(u) and not shown[u] then return true end
		end
	end
	-- (WoW Forever: the container itself decides - a matchmade raid without
	-- role requirements shows no Main Tank / Assist frames at all)
	local showsFlagged = container.displayFlaggedMembers
	if type(container.ShouldDisplayMainTankAndAssist) == "function" then
		local okS, answer = pcall(container.ShouldDisplayMainTankAndAssist, container)
		if okS and not IsHidden(answer) then showsFlagged = answer end
	end
	if showsFlagged then
		local shown = {}
		for _, fr in ipairs(flagged) do
			local u = tostring(fr.unit or "")
			if not u:find("target", 1, true) then shown[u] = true end
		end
		for i = 1, GetNumGroupMembers() do
			local role = select(10, GetRaidRosterInfo(i))
			if (role == "MAINTANK" or role == "MAINASSIST")
				and not shown["raid" .. i] then
				return true
			end
		end
	end
	return false
end

local function OnBlizzardLayout()
	-- Immediately overwrite Blizzard's one-long-row layout in the same frame,
	-- before anything is drawn -> no flicker.
	Restack()
	QueueRestack()
	-- Any layout pass that runs while fighting (login into combat, or an
	-- event deliberately let through for a missing group frame) re-arms
	-- the guard so the rest of the fight stays protected.
	if InCombatLockdown() then
		GuardArm()
	end
end

-------------------------------------------------------------------------------
-- Watchdog: some encounter mechanics (a boss going untargetable, tank target
-- swaps, etc.) make the Main Tank target frames blink on/off mid-combat,
-- and depending on the build Blizzard may reposition the container through
-- paths our hooks don't cover. This runs every tick BEFORE the frame is
-- drawn: if anything has drifted off-plan, it is corrected invisibly.

local watchdog = CreateFrame("Frame")
local wdAccum = 0
watchdog:SetScript("OnUpdate", function(_, elapsed)
	-- Restack() is fully synchronous, so isRestacking can never be
	-- legitimately true between frames. If it is, an earlier pass was
	-- killed mid-apply by an engine error - clear it so the addon
	-- self-heals instead of staying frozen for the session.
	if isRestacking then
		isRestacking = false
	end
	if not lastPlan then return end
	local container = _G.CompactRaidFrameContainer
	if not container then return end

	wdAccum = wdAccum + elapsed

	-- (the reads below can meet a value the game hides on WoW Forever, or
	-- anything else unforeseen: then there is nothing to police this frame)
	local plan = lastPlan
	local okW, drift = pcall(function()
		if plan.width then
			local cw, ch = Plain(container:GetSize())
			if math.abs(cw - plan.width) > 0.5 or math.abs(ch - plan.height) > 0.5 then
				return true
			end
		end
		local planRelTo = plan.relTo or container
		for i = 1, #plan do
			local p = plan[i]
			local fr = p.frame
			if fr:IsShown() then
				if not PointMatches(fr, planRelTo, p.x, p.y) then
					return true
				end
				-- A resized frame (targets changing, frames being reused for
				-- a different role) shifts what the layout should be, even
				-- though its anchor point still matches.
				local w, h = Plain(fr:GetSize())
				if math.abs((w or 0) - (p.w or 0)) > 0.5
					or math.abs((h or 0) - (p.h or 0)) > 0.5 then
					return true
				end
			end
		end
		return false
	end)
	if not okW then
		lastPlan = nil
		pendingUpdate = true
		return
	end

	-- Fix drift instantly; additionally do a full low-frequency pass to catch
	-- membership changes (frames appearing/disappearing) that leave every
	-- previously-planned frame untouched.
	if drift or wdAccum >= 0.2 then
		wdAccum = 0
		Restack()
	end
end)

-------------------------------------------------------------------------------
-- Hooks: re-apply our layout every time Blizzard re-lays-out the raid frames

local hookedLayout = false
local hookedFlow = false
local hookedSize = false
local hookedEditMode = false

local function TryHook()
	local container = _G.CompactRaidFrameContainer

	if not hookedLayout and container then
		if type(container.LayoutFrames) == "function" then
			hooksecurefunc(container, "LayoutFrames", OnBlizzardLayout)
			hookedLayout = true
		elseif type(_G.CompactRaidFrameContainer_LayoutFrames) == "function" then
			hooksecurefunc("CompactRaidFrameContainer_LayoutFrames", OnBlizzardLayout)
			hookedLayout = true
		end
	end

	if not hookedFlow and type(_G.FlowContainer_DoLayout) == "function" then
		hooksecurefunc("FlowContainer_DoLayout", function(f)
			if f == _G.CompactRaidFrameContainer and not f.flowPauseUpdates then
				-- Deferred on purpose: this fires mid-flight inside
				-- Blizzard's own layout; the watchdog repaints before
				-- render, so deferring costs nothing visually.
				QueueRestack()
			end
		end)
		hookedFlow = true
	end

	-- Catches Blizzard/Edit Mode resizing the container outside a layout call.
	if not hookedSize and container then
		container:HookScript("OnSizeChanged", function()
			if not isRestacking then
				QueueRestack()
			end
		end)
		hooksecurefunc(container, "SetPoint", function()
			-- Edit Mode dragging repositions the container; queue a pass so
			-- the screen anchor re-syncs and the grid follows.
			if not isRestacking then
				QueueRestack()
			end
		end)
		hookedSize = true
	end

	-- Edit Mode recomputes the raid container's flow/size when settings
	-- change or Edit Mode is entered/left; re-stack right after it does.
	if not hookedEditMode and _G.EditModeManagerFrame
		and type(_G.EditModeManagerFrame.UpdateRaidContainerFlow) == "function" then
		hooksecurefunc(_G.EditModeManagerFrame, "UpdateRaidContainerFlow", OnBlizzardLayout)
		hookedEditMode = true
	end
end

-------------------------------------------------------------------------------
-- Options UI

local optionsFrame
local refreshers = {}

local function RefreshUI()
	for _, widget in ipairs(refreshers) do
		widget:Refresh()
	end
end

local function AddHeader(parent, x, text, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
end

local function AddNumberBox(parent, x, labelText, y, get, set)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", x + 8, y - 5)
	label:SetText(labelText)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(52, 18)
	box:SetPoint("TOPLEFT", x + 182, y - 1)
	box:SetAutoFocus(false)
	box:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then set(v) end
		self:ClearFocus()
		RefreshUI()
		QueueRestack()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		RefreshUI()
	end)
	box.Refresh = function(self)
		self:SetText(tostring(get()))
		self:SetCursorPosition(0)
	end
	refreshers[#refreshers + 1] = box
end

local function AddCycle(parent, x, labelText, y, values, valueLabels, get, set, tooltip)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", x + 8, y - 7)
	label:SetText(labelText)
	local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	btn:SetSize(120, 20)
	btn:SetPoint("TOPLEFT", x + 176, y)
	if tooltip then
		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(labelText)
			GameTooltip:AddLine(tooltip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	btn:SetScript("OnClick", function(self)
		local cur = get()
		local idx = 1
		for i, v in ipairs(values) do
			if v == cur then idx = i break end
		end
		set(values[(idx % #values) + 1])
		RefreshUI()
		QueueRestack()
	end)
	btn.Refresh = function(self)
		self:SetText(valueLabels[get()] or tostring(get()))
	end
	refreshers[#refreshers + 1] = btn
end

local function AddActionButton(parent, x, labelText, buttonText, y, onClick)
	local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", x + 8, y - 7)
	label:SetText(labelText)
	local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	btn:SetSize(120, 20)
	btn:SetPoint("TOPLEFT", x + 176, y)
	btn:SetText(buttonText)
	btn:SetScript("OnClick", onClick)
	return btn
end

local ONOFF = { on = "On", off = "Off" }

local function CreateOptionsUI()
	if optionsFrame then return optionsFrame end

	local f = CreateFrame("Frame", "StackedRaidGroupsOptions", UIParent,
		"BasicFrameTemplateWithInset")
	f:SetSize(650, 468)
	f:SetPoint("CENTER")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetFrameStrata("DIALOG")
	f:SetScript("OnShow", RefreshUI)
	f:Hide()
	tinsert(UISpecialFrames, "StackedRaidGroupsOptions")

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -5)
	title:SetText("Stacked Raid Groups  v" .. VERSION)

	local L, R = 8, 330
	local y

	-- ===== Left column =====
	y = -34
	AddHeader(f, L, "Group grid", y); y = y - 20
	AddNumberBox(f, L, "Groups per row (1-8)", y,
		function() return db.groupsPerRow end,
		function(v)
			db.groupsPerRow = math.max(1, math.min(8, math.floor(v)))
			db.rowsCustomized = true
		end); y = y - 24
	AddCycle(f, L, "Fill order", y, { "rows", "columns" },
		{ rows = "Rows (1-4 top)", columns = "Cols (1,3,5,7)" },
		function() return db.fillOrder or "rows" end,
		function(v) db.fillOrder = v end); y = y - 26
	AddNumberBox(f, L, "Horizontal gap", y,
		function() return db.xGap end, function(v) db.xGap = v end); y = y - 24
	AddNumberBox(f, L, "Vertical gap", y,
		function() return db.yGap end, function(v) db.yGap = v end); y = y - 24
	AddCycle(f, L, "Empty groups", y, { "hide", "keep" },
		{ hide = "Hide", keep = "Keep slot" },
		function() return db.keepEmptySlots and "keep" or "hide" end,
		function(v) db.keepEmptySlots = (v == "keep") end); y = y - 30

	AddHeader(f, L, "General", y); y = y - 20
	AddCycle(f, L, "Combat guard", y, { "on", "off" }, ONOFF,
		function() return (db.combatGuard ~= false) and "on" or "off" end,
		function(v)
			db.combatGuard = (v == "on")
			if not db.combatGuard then
				GuardDisarm()
			elseif InCombatLockdown() then
				GuardArm()
			end
		end,
		"In combat, the game re-arranges its raid frames into one long line"
		.. " whenever the roster changes - someone logging off is enough - and"
		.. " addons are forbidden from moving them back until combat ends."
		.. "|n|nThe guard prevents that: while you fight, the game's container"
		.. " stops reacting to roster changes, so the stacked grid stays put."
		.. " Members still update live (offline greying, leavers hiding,"
		.. " joiners filling visible groups)."
		.. "|n|nTradeoff: frames that would have to be CREATED mid-fight (a"
		.. " newly summoned pet, a changed Main Tank/Assist) appear right"
		.. " after combat instead. A player joining a group with no frame on"
		.. " screen is built immediately, at the cost of one re-arrangement."
		.. "|n|nType /srg guard for this explanation in chat."); y = y - 26
	AddCycle(f, L, "Combat notice", y, { "on", "off" }, ONOFF,
		function() return (db.combatNotice ~= false) and "on" or "off" end,
		function(v) db.combatNotice = (v == "on") end); y = y - 26
	AddCycle(f, L, "Login message", y, { "on", "off" }, ONOFF,
		function() return (db.loginMessage ~= false) and "on" or "off" end,
		function(v) db.loginMessage = (v == "on") end); y = y - 30

	AddHeader(f, L, "Diagnostics & maintenance", y); y = y - 20
	AddCycle(f, L, "Container resizing", y, { "on", "off" }, ONOFF,
		function() return (db.resizeContainer ~= false) and "on" or "off" end,
		function(v) db.resizeContainer = (v == "on") end); y = y - 26
	AddActionButton(f, L, "Diagnostics", "Print status", y, function()
		SlashCmdList["STACKEDRAIDGROUPS"]("status")
	end); y = y - 26
	AddActionButton(f, L, "Frame opacity", "Restore", y, function()
		SlashCmdList["STACKEDRAIDGROUPS"]("unfade")
	end); y = y - 26
	local resetBtn
	resetBtn = AddActionButton(f, L, "All settings", "Reset...", y, function(self)
		if self.srgArmed then
			self.srgArmed = nil
			self:SetText("Reset...")
			SlashCmdList["STACKEDRAIDGROUPS"]("reset")
			RefreshUI()
		else
			self.srgArmed = true
			self:SetText("Confirm reset")
			C_Timer.After(4, function()
				if resetBtn.srgArmed then
					resetBtn.srgArmed = nil
					resetBtn:SetText("Reset...")
				end
			end)
		end
	end); y = y - 26

	-- ===== Right column =====
	y = -34
	AddHeader(f, R, "Main Tank / Assist frames", y); y = y - 20
	AddCycle(f, R, "Target mini-frames", y, { "on", "off" }, ONOFF,
		function() return (db.tanks.showTargets ~= false) and "on" or "off" end,
		function(v) db.tanks.showTargets = (v == "on") end); y = y - 26
	AddCycle(f, R, "Position (vs grid)", y, POSITIONS, POSITION_LABELS,
		function() return db.tanks.position end,
		function(v) db.tanks.position = v end); y = y - 26
	AddNumberBox(f, R, "Gap from grid", y,
		function() return db.tanks.gap end, function(v) db.tanks.gap = v end); y = y - 24
	AddNumberBox(f, R, "Tanks per line", y,
		function() return db.tanks.perLine end,
		function(v) db.tanks.perLine = math.max(1, math.floor(v)) end); y = y - 24
	AddNumberBox(f, R, "Offset X", y,
		function() return db.tanks.offsetX end,
		function(v) db.tanks.offsetX = v end); y = y - 24
	AddNumberBox(f, R, "Offset Y", y,
		function() return db.tanks.offsetY end,
		function(v) db.tanks.offsetY = v end); y = y - 30

	AddHeader(f, R, "Pet frames", y); y = y - 20
	AddCycle(f, R, "Position (vs grid)", y, POSITIONS, POSITION_LABELS,
		function() return db.pets.position end,
		function(v) db.pets.position = v end); y = y - 26
	AddNumberBox(f, R, "Gap from grid", y,
		function() return db.pets.gap end, function(v) db.pets.gap = v end); y = y - 24
	AddNumberBox(f, R, "Frames per line", y,
		function() return db.pets.perLine end,
		function(v) db.pets.perLine = math.max(1, math.floor(v)) end); y = y - 24
	AddNumberBox(f, R, "Offset X", y,
		function() return db.pets.offsetX end,
		function(v) db.pets.offsetX = v end); y = y - 24
	AddNumberBox(f, R, "Offset Y", y,
		function() return db.pets.offsetY end,
		function(v) db.pets.offsetY = v end); y = y - 24

	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", 14, 10)
	hint:SetPoint("BOTTOMRIGHT", -14, 10)
	hint:SetJustifyH("LEFT")
	hint:SetText("Type a value and press Enter to apply. Offsets: +X = right,"
		.. " +Y = down.   Commands: /srg help   Diagnostics: /srg status")

	optionsFrame = f
	return f
end

local function ToggleOptions()
	local f = CreateOptionsUI()
	if f:IsShown() then f:Hide() else f:Show() end
end

-------------------------------------------------------------------------------
-- Events

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("ADDON_LOADED")

ev:SetScript("OnEvent", function(_, event, arg1)
	if event == "PLAYER_LOGIN" then
		StackedRaidGroupsDB = StackedRaidGroupsDB or {}
		db = StackedRaidGroupsDB
		CopyDefaults(defaults, db)
		if not VALID_POSITION[db.tanks.position] then db.tanks.position = "TOP" end
		if not VALID_POSITION[db.pets.position] then db.pets.position = "BOTTOM" end
		TryHook()
		if db.loginMessage ~= false then
			print(PREFIX .. "v" .. VERSION .. " loaded. Type /srg for options.")
		end
		-- One-time note when the addon is installed or updated, so the
		-- combat behavior is never a surprise (shown even with the login
		-- message off, but only once per version).
		if db.seenVersion ~= VERSION then
			db.seenVersion = VERSION
			print(PREFIX .. "v" .. VERSION .. ": now also loads on WoW Forever,"
				.. " as well as Classic Era (1.15.9) and Burning Crusade"
				.. " Anniversary (2.5.6)."
				.. " Since v1.1.0 the combat guard holds your layout through"
				.. " mid-combat roster changes - /srg guard for details, or"
				.. " /srg guard off to disable.")
		end
	elseif event == "ADDON_LOADED" and arg1 == "Blizzard_CompactRaidFrames" then
		TryHook()
	elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
		TryHook()
		if guardActive then
			if not InCombatLockdown() or not IsInRaid() then
				-- Combat is over (or we're no longer in a raid, where the
				-- container must run freely for party-style frames).
				GuardDisarm()
			elseif event == "GROUP_ROSTER_UPDATE" then
				suppressedEvents = suppressedEvents + 1
				if RosterNeedsNewGroupFrames() then
					-- Someone's group frame doesn't exist on screen. Let
					-- the next roster event through so the game can build
					-- it (secure); OnBlizzardLayout re-arms afterwards.
					GuardDisarm()
				end
			end
		end
		QueueRestack()
	elseif event == "PLAYER_REGEN_DISABLED" then
		GuardArm()
	elseif event == "PLAYER_REGEN_ENABLED" then
		local hadSuppressed = suppressedEvents > 0
		suppressedEvents = 0
		GuardDisarm()
		pendingUpdate = false
		noticeShownThisCombat = false
		combatGroupMoveBlocked = nil -- fresh fight, fresh probe
		isRestacking = false -- recover if a combat pass died mid-apply
		-- Roster changed during the fight? Fix group visibility ourselves
		-- right now instead of waiting for the game's next roster event.
		pcall(ReconcileGroupVisibility)
		-- The repair must run no matter what; everything optional (like
		-- the staleness message) comes after it and is error-isolated.
		QueueRestack()
		if hadSuppressed and db and db.combatNotice ~= false then
			local ok, stale = pcall(ContainerLevelStale)
			if ok and stale then
				print(PREFIX .. "the layout was protected through combat;"
					.. " anything still missing (new pets, tank"
					.. " assignments, or a group the game has never"
					.. " built) will be added by the game on its next"
					.. " roster update.")
			end
		end
	end
end)

-------------------------------------------------------------------------------
-- Slash commands

SLASH_STACKEDRAIDGROUPS1 = "/srg"
SLASH_STACKEDRAIDGROUPS2 = "/stackedraidgroups"

local function PrintHelp()
	print(PREFIX .. "commands ( /srg with nothing opens the options window ):")
	print("  /srg rows <1-8>            - groups per row")
	print("  /srg fill rows|columns     - Groups 1-4 on top, or 1,3,5,7 on top")
	print("  /srg xgap <n> | ygap <n>   - spacing between frames")
	print("  /srg empties hide|keep     - hide empty groups or keep their slot")
	print("  /srg tanks top|bottom|left|right   - tank section position")
	print("  /srg tanks targets on|off  - MT target mini-frames")
	print("  /srg tanks gap|perline|x|y <n>     - tank section tuning")
	print("  /srg pets  top|bottom|left|right   - pet section position")
	print("  /srg pets  gap|perline|x|y <n>     - pet section tuning")
	print("  /srg guard                 - explain the combat guard (on|off toggles it)")
	print("  /srg notice on|off  |  /srg loginmsg on|off")
	print("  /srg container on|off | unfade | status | reset")
end

SlashCmdList["STACKEDRAIDGROUPS"] = function(msg)
	if not db then return end

	msg = (msg or ""):lower()
	local cmd, a, b = msg:match("^%s*(%S*)%s*(%S*)%s*(%S*)")
	local n = tonumber(a)

	if cmd == "" then
		ToggleOptions()
	elseif (cmd == "rows" or cmd == "perrow") and n then
		db.groupsPerRow = math.max(1, math.min(8, math.floor(n)))
		db.rowsCustomized = true
		print(PREFIX .. db.groupsPerRow .. " group(s) per row.")
		QueueRestack()
	elseif cmd == "xgap" and n then
		db.xGap = n
		print(PREFIX .. "horizontal gap set to " .. n .. ".")
		QueueRestack()
	elseif cmd == "ygap" and n then
		db.yGap = n
		print(PREFIX .. "vertical gap set to " .. n .. ".")
		QueueRestack()
	elseif cmd == "fill" and (a == "rows" or a == "columns") then
		db.fillOrder = a
		print(PREFIX .. "fill order: " .. (a == "rows"
			and "rows (Groups 1-4 on top)"
			or "columns (Groups 1,3,5,7 on top)") .. ".")
		QueueRestack()
	elseif cmd == "tanks" or cmd == "pets" then
		local cfg = (cmd == "tanks") and db.tanks or db.pets
		if cmd == "tanks" and a == "targets" and (b == "on" or b == "off") then
			db.tanks.showTargets = (b == "on")
			print(PREFIX .. "tank target mini-frames: " .. b .. ".")
			QueueRestack()
			return
		end
		local num = tonumber(b)
		if VALID_POSITION[a:upper()] then
			cfg.position = a:upper()
			print(PREFIX .. cmd .. " position: " .. POSITION_LABELS[cfg.position] .. ".")
			QueueRestack()
		elseif a == "gap" and num then
			cfg.gap = num
			print(PREFIX .. cmd .. " gap set to " .. num .. ".")
			QueueRestack()
		elseif (a == "perline" or a == "line") and num then
			cfg.perLine = math.max(1, math.floor(num))
			print(PREFIX .. cmd .. " frames per line: " .. cfg.perLine .. ".")
			QueueRestack()
		elseif a == "x" and num then
			cfg.offsetX = num
			print(PREFIX .. cmd .. " offset X: " .. num .. ".")
			QueueRestack()
		elseif a == "y" and num then
			cfg.offsetY = num
			print(PREFIX .. cmd .. " offset Y: " .. num .. ".")
			QueueRestack()
		else
			PrintHelp()
		end
	elseif cmd == "unfade" then
		if InCombatLockdown() then
			print(PREFIX .. "can't do that during combat - try again after.")
		else
			local fixed = 0
			local function fix(fr)
				if fr and fr.GetAlpha and fr:GetAlpha() < 1 then
					fr:SetAlpha(1)
					fixed = fixed + 1
				end
			end
			local container = _G.CompactRaidFrameContainer
			if container then
				fix(container)
				local flagged, groups, pets = CollectLayoutFrames(container)
				local function fixList(t)
					for _, fr in ipairs(t) do
						fix(fr)
						for _, child in ipairs({ fr:GetChildren() }) do
							if child.unit ~= nil then fix(child) end
						end
					end
				end
				fixList(groups)
				fixList(flagged)
				fixList(pets)
			end
			print(PREFIX .. "restored default opacity (1.0) on " .. fixed .. " frame(s)."
				.. (fixed > 0
					and " Frames that just appeared were being faded by something else (another addon or a game setting)."
					or " Nothing was faded - the suppression is elsewhere (scale, clipping, or the game not drawing)."))
		end
	elseif cmd == "empties" and (a == "hide" or a == "keep") then
		db.keepEmptySlots = (a == "keep")
		print(PREFIX .. (a == "keep"
			and "empty groups now keep their grid slot (group-number-stable layout)."
			or "empty groups are now hidden from the grid (compact layout)."))
		QueueRestack()
	elseif cmd == "loginmsg" and (a == "on" or a == "off") then
		db.loginMessage = (a == "on")
		print(PREFIX .. "login message " .. a .. ".")
	elseif cmd == "guard" then
		if a == "on" or a == "off" then
			db.combatGuard = (a == "on")
			if db.combatGuard then
				if InCombatLockdown() then GuardArm() end
				print(PREFIX .. "combat guard on - mid-combat roster changes no"
					.. " longer re-arrange the raid frames.")
			else
				GuardDisarm()
				print(PREFIX .. "combat guard off - the game may re-arrange"
					.. " frames on mid-combat roster changes.")
			end
		else
			print(PREFIX .. "combat guard is "
				.. ((db.combatGuard ~= false) and "ON" or "OFF")
				.. " (default on). /srg guard on|off toggles it.")
			print("  In combat, the game re-arranges its raid frames into one long")
			print("  line whenever the roster changes - someone logging off is")
			print("  enough - and addons are forbidden from moving them back until")
			print("  combat ends. The guard PREVENTS the re-arrangement instead:")
			print("  while you fight, the game's container stops reacting to roster")
			print("  changes, so the stacked grid stays put. Members still update")
			print("  live: offline players grey out, leavers hide, joiners fill")
			print("  groups that are already on screen.")
			print("  Tradeoff: frames that would have to be CREATED mid-fight (a")
			print("  newly summoned pet, a changed Main Tank/Assist) appear right")
			print("  after combat instead. A player joining a group with no frame")
			print("  on screen is built immediately, at the cost of one")
			print("  re-arrangement of that fight's layout.")
		end
	elseif cmd == "notice" and (a == "on" or a == "off") then
		db.combatNotice = (a == "on")
		print(PREFIX .. "combat-lock chat notice " .. a .. ".")
	elseif cmd == "container" and (a == "on" or a == "off") then
		db.resizeContainer = (a == "on")
		print(PREFIX .. "container resizing " .. a .. ".")
		QueueRestack()
	elseif cmd == "status" then
		local container = _G.CompactRaidFrameContainer
		print(PREFIX .. "v" .. VERSION)
		do
			local okB, version, build, _, interface = pcall(GetBuildInfo)
			if okB then
				print("  game: " .. tostring(version) .. " (" .. tostring(build)
					.. "), interface " .. tostring(interface))
			end
		end
		print("  hooks: layout=" .. tostring(hookedLayout) .. ", flow=" .. tostring(hookedFlow)
			.. ", size=" .. tostring(hookedSize) .. ", editmode=" .. tostring(hookedEditMode))
		if container then
			local flagged, groups, pets = CollectLayoutFrames(container)
			local empty = 0
			local counts = {}
			for _, g in ipairs(groups) do
				if not GroupHasVisibleMembers(g) then empty = empty + 1 end
				local n = 0
				for _, child in ipairs({ g:GetChildren() }) do
					if child.unit ~= nil and child:IsVisible() then n = n + 1 end
				end
				counts[#counts + 1] = tostring(n)
			end
			print("  frames: " .. #groups .. " group(s) (" .. empty .. " empty), "
				.. #flagged .. " tank/target, " .. #pets .. " pet")
			print("  visible members per shown group: " .. table.concat(counts, ", ")
				.. "  (compare with the Raid roster panel - a populated group"
				.. " showing 0 here means the game isn't drawing it)")
			-- Render diagnostics: the things that make an IsVisible frame
			-- not actually draw. This addon writes none of them.
			local anomalies = {}
			if container.GetEffectiveAlpha then
				local ca = container:GetEffectiveAlpha()
				if ca < 0.99 then
					anomalies[#anomalies + 1] = ("container alpha %.2f"):format(ca)
				end
			end
			if container.GetClipsChildren and container:GetClipsChildren() then
				anomalies[#anomalies + 1] = "container clips children"
			end
			for i, g in ipairs(groups) do
				local gnum = ((g.GetName and g:GetName() or ""):match("CompactRaidGroup(%d+)")) or tostring(i)
				local ga = g.GetEffectiveAlpha and g:GetEffectiveAlpha() or 1
				local gs = g:GetScale() or 1
				local minMember = 1
				for _, child in ipairs({ g:GetChildren() }) do
					if child.unit ~= nil and child:IsVisible() and child.GetEffectiveAlpha then
						local aVal = child:GetEffectiveAlpha()
						if aVal < minMember then minMember = aVal end
					end
				end
				if ga < 0.99 or minMember < 0.99 or math.abs(gs - 1) > 0.05 then
					anomalies[#anomalies + 1] = ("group %s: alpha %.2f, min member alpha %.2f, scale %.2f")
						:format(gnum, ga, minMember, gs)
				end
			end
			if #anomalies > 0 then
				print("  render anomalies (something OTHER than layout is suppressing these):")
				for _, s in ipairs(anomalies) do print("    " .. s) end
				print("  try /srg unfade to restore default opacity.")
			else
				print("  render: no alpha/scale/clipping anomalies on managed frames")
			end
		else
			print("  raid container not found")
		end
		print("  settings: " .. (db.groupsPerRow or 4) .. "/row"
			.. (db.rowsCustomized and " (user set)"
				or (db.autoRowsDone and " (auto)" or " (default)"))
			.. ", tanks " .. tostring(db.tanks.position)
			.. ", pets " .. tostring(db.pets.position))
		print("  watchdog: " .. (lastPlan and "active" or "suspended")
			.. ", in combat: " .. tostring(InCombatLockdown())
			.. ", retry queued: " .. tostring(pendingUpdate))
		print("  combat guard: " .. ((db.combatGuard ~= false) and "on" or "off")
			.. (guardActive and " (ACTIVE - container roster events held)" or " (idle)")
			.. ", events held this combat: " .. suppressedEvents)
		local cm
		if combatGroupMoveBlocked == true then
			cm = "BLOCKED by the engine (grid waits for combat end; game limitation)"
		elseif combatGroupMoveBlocked == false then
			cm = "allowed by the engine (grid repairs live)"
		else
			cm = "untested this fight"
		end
		print("  in-combat group movement: " .. cm)
		if hiddenPasses > 0 then
			print("  passes skipped because the game hid a frame's size or place: "
				.. hiddenPasses)
		end
		if lastError then
			print("  last failed pass: " .. lastError)
		end
	elseif cmd == "reset" then
		wipe(db)
		CopyDefaults(defaults, db)
		print(PREFIX .. "settings reset to defaults.")
		if optionsFrame and optionsFrame:IsShown() then RefreshUI() end
		QueueRestack()
	else
		PrintHelp()
	end
end
