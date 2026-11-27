===============================================================================
 Stacked Raid Groups                                                  v1.1.6
===============================================================================

Stack the new raid frames' groups into rows - e.g. Groups 5-8 directly
underneath Groups 1-4 - instead of one long line across your screen.

-------------------------------------------------------------------------------
 WHY THIS EXISTS
-------------------------------------------------------------------------------
Patch 1.15.9 (and 2.5.6 on Burning Crusade Anniversary) replaced the old
raid frames with the modern Edit Mode versions. Those frames can only lay
out separate groups in a single row or column - the old drag-to-wrap resize
border is gone, and Edit Mode has no "groups per row" option. In a 40-man
raid that means eight groups stretched across half your monitor.

This addon hooks Blizzard's own layout and re-stacks the groups into a
grid of your choosing (4x2 by default), while keeping everything anchored
to wherever you placed the raid frames in Edit Mode.

-------------------------------------------------------------------------------
 FEATURES
-------------------------------------------------------------------------------
* Wrap separate raid groups into rows: 4x2, 2x4, or anything from 1 to 8
  groups per row.
* Main Tank / Main Assist frames get their own section, placeable on any
  side of the group grid (Top / Bottom / Left / Right) with its own gap,
  frames-per-line, and X/Y fine-tuning offsets.
* Pet frames get the same independent placement options.
* Simple options window (/srg) - every change applies instantly.
* Flicker-free: the layout is applied inside Blizzard's own layout pass,
  so the one-long-row arrangement is never drawn.
* Combat guard: mid-combat roster changes (logoffs, leavers, subgroup
  moves) no longer snap the frames back to the game's single-line layout
  mid-fight. See COMBAT STABILITY below for the exact tradeoffs.
* Handles uneven groups while the raid fills up - a half-empty group can't
  make the row below overlap it.
* Settings are saved per account.

-------------------------------------------------------------------------------
 SUPPORTED GAME VERSIONS
-------------------------------------------------------------------------------
* WoW Classic Era, Hardcore, and Season of Discovery (patch 1.15.9)
* Burning Crusade Classic Anniversary (patch 2.5.6)
* WoW Forever (1.60.1)

All three run the same modern (Edit Mode) raid frame code, which this
addon targets.

-------------------------------------------------------------------------------
 INSTALLATION
-------------------------------------------------------------------------------
CurseForge app: install like any other addon.

The same addon folder works on ALL of them - it ships one TOC file per
client (_Vanilla for 1.15.9, _TBC for 2.5.6) plus a shared one that WoW
Forever uses, and each game automatically picks the right one.

Manual install - Classic Era / Hardcore / SoD: copy the
"StackedRaidGroups" folder into
    World of Warcraft\_classic_era_\Interface\AddOns\

Manual install - Burning Crusade Anniversary: copy the SAME folder into
the TBC Anniversary client's Interface\AddOns folder. Each client has
its own AddOns folder, so it must be copied into both if you play both.
Not sure where the TBC one is? In the Battle.net app select your
Burning Crusade Anniversary install, click the gear icon next to Play,
choose "Show in Explorer" (Reveal in Finder on Mac), then open
Interface\AddOns from there.

Manual install - WoW Forever: copy the SAME folder into the WoW Forever
client's Interface\AddOns folder (found the same way: its gear icon in
the Battle.net app, "Show in Explorer").

Restart the game or /reload afterwards.

-------------------------------------------------------------------------------
 GETTING STARTED
-------------------------------------------------------------------------------
1. In your raid frame options / Edit Mode, set the raid frames to show
   SEPARATE groups ("Keep Groups Together"). The addon does nothing in
   combined-groups mode. Both vertical and horizontal group orientations
   work.
2. If you use the container "Display Border" option, turn it off - the
   border still traces Blizzard's one-line layout and will look wrong.
3. Position the raid frames in Edit Mode as usual. The group grid anchors
   to that spot; tank/pet sections hang off whichever side you choose.
4. Type /srg to open the options window and shape the layout to taste.

-------------------------------------------------------------------------------
 APPEARANCE
-------------------------------------------------------------------------------
This addon never changes how the raid frames LOOK. It does not touch
textures, colors, health bars, fonts, borders, highlights, or frame sizes.
The only things it ever sets are frame POSITIONS (and the size of the
invisible container rectangle they anchor to). If your frames look
different since patch 1.15.9 / 2.5.6, that is the game's new Midnight-style frames,
not this addon - their appearance is controlled by Blizzard's own Interface
options and CVars (e.g. raidFramesDispelIndicatorOverlay for the dispel
highlight).

-------------------------------------------------------------------------------
 OPTIONS WINDOW  ( /srg )
-------------------------------------------------------------------------------
Group grid:
  * Groups per row (1-8)   * Horizontal gap   * Vertical gap

Main Tank / Assist frames and Pet frames (each independent):
  * Position vs the grid: Top / Bottom / Left / Right
  * Gap from the grid
  * Frames per line before wrapping (Left/Right sections fill downward);
    for the tank section this counts tanks - each tank's target frames
    stay tucked directly beneath it
  * Offset X / Offset Y for pixel-level fine-tuning

Type a value and press Enter to apply. If tanks and pets share a side,
they stack automatically instead of overlapping.

-------------------------------------------------------------------------------
 CHAT COMMANDS
-------------------------------------------------------------------------------
/srg                       open the options window
/srg rows <1-8>            groups per row
/srg fill rows|columns     Groups 1-4 on top, or 1,3,5,7 on top
/srg xgap <n> | ygap <n>   spacing between frames
/srg empties hide|keep     hide empty groups or reserve their slot
/srg tanks top|bottom|left|right    tank section position
/srg tanks targets on|off  MT target mini-frames
/srg tanks gap|perline|x|y <n>      tank section tuning
/srg pets  (same options as tanks)
/srg guard                 explain the combat guard in chat
/srg guard on|off          combat guard (hold layout through mid-combat
                           roster changes) - default on
/srg notice on|off         combat-lock chat heads-up
/srg loginmsg on|off       load message at login
/srg status                diagnostics - include in bug reports
/srg reset                 restore defaults
/srg help                  list commands

-------------------------------------------------------------------------------
 KNOWN LIMITATIONS & COMBAT STABILITY
-------------------------------------------------------------------------------
IMPORTANT FOR HEALERS: a mid-combat re-layout by the game moves frames in
a single instant - a mouseover heal cast during that instant can land on
whoever's frame now occupies that pixel. Since v1.1.0 the COMBAT GUARD
(on by default) prevents nearly all of these.

HOW THE COMBAT GUARD WORKS
Why frames used to break: on every roster event (someone logging off is
enough), the game's own SECURE code re-flows the raid container into its
single-line layout, and during combat no addon is allowed to move the
frames back. Prevention, not repair, is the only fix - so while you are
in combat the addon unregisters the two events that trigger the
container's re-flow (GROUP_ROSTER_UPDATE / UNIT_PET) on the container
frame ONLY. Event registration is not a protected operation, so this is
combat-legal and taint-free. Each group frame separately registers
GROUP_ROSTER_UPDATE itself, so members still update normally the whole
time: logoffs grey out, leavers' frames hide, joiners appear inside
already-visible groups, and health/range/aura updates are untouched. The
grid simply never gets disturbed. Both events are restored the moment
combat ends (and the addon then re-syncs everything).

THE MOMENT COMBAT DROPS the addon squares everything away itself - it
does not wait for the game's next roster event. It re-applies the grid,
shows any existing group frame that players moved into mid-fight (their
member frames were kept current the whole time), and hides any group
that emptied mid-fight. So roster changes made during the fight are
reflected immediately at combat end.

The only things that wait for the game's own next roster update are
frames an addon cannot legally CREATE:
  * a frame for a brand-new pet summoned mid-fight (existing pet frames
    keep updating; despawned pets hide themselves normally),
  * Main Tank / Main Assist changes made mid-fight,
  * a group frame that has never existed this session - EXCEPT that
    this case is detected DURING combat and a roster event is
    deliberately let through so the game can build it (one re-flow,
    exactly what would have happened anyway), after which the guard
    re-arms.
The addon prints a heads-up at combat end when any of these apply.
/srg guard off restores the old behavior (live repair when the engine
allows it, single-line fallback when it does not).

OTHER NOTES
* If a mid-combat re-layout does happen (guard off, login during combat,
  or a deliberately passed-through event) and the engine blocks the
  repair, the default single-line layout shows until combat ends - the
  addon flashes an on-screen warning so mouseover healers know
  immediately. The frames remain fully functional and correctly bound
  the whole time; only the arrangement differs.
* Requires separate groups; combined ("flush") mode is intentionally left
  untouched.

-------------------------------------------------------------------------------
 BUGS & FEEDBACK
-------------------------------------------------------------------------------
Patches 1.15.9 and 2.5.6 are still being hotfixed by Blizzard, so if
something breaks after a game update it is most likely a changed code path.
If frames for POPULATED groups are not drawing at all (the Raid roster
panel shows members but the frames are blank): run /srg status - it now
reports render anomalies (opacity/scale/clipping, none of which this addon
sets) and per-group visible member counts. Try /srg unfade, check the
Edit Mode raid frame Opacity setting, test with all OTHER addons disabled
(these patches broke many frame addons), and note that /reload forces
the game to rebuild its frames.

Please report issues on the CurseForge page and include:
  * what moved / flickered and exactly when it happened, and
  * any Lua error text ( /console scriptErrors 1  makes errors visible).

See CHANGELOG.txt for version history.
