# Changelog

## [2.0.1] - 2026-09-14

### Fixed

- **The live map was out by up to 300m.** The world rectangle the satellite render was believed to cover was the wrong shape — 9594 x 13208 against a 4096 x 6144 image, so X was stretched 9% against Y. Everything on the map read slightly wrong: near perfect in the middle, worst at the edges. It is now 9000 x 13500, which is exactly 2:3 like the render, refitted against the postal numbers drawn on the render itself. Same fix in XS-MDT, XS-AdminMenu and XS-Trucking, which share the map

### Added

- **`xsmapfix`** — server console command that repairs coordinates saved through the old map. Anything you created by CLICKING the map editor is stored where the click *used* to land, and correcting the map does not move it. Run `xsmapfix` for a report, `xsmapfix apply` to fix crew blips, staff placements and map-drawn zones. Zones walked out with the in-world creator, props the crew placed themselves, graffiti and vehicles all came from real positions and are left alone. Back up first — it is not safe to run twice, and it records that it ran so it will not

## [2.0.0] - 2026-09-14

Big one. The tablet is gang-only now and most of it has been rebuilt.

### Added

- **Hub.** The crew homepage. A clickable card for every app with its own live number on it, who's online right now, and the latest activity. Alerts only show up when something actually needs a call — a rival working your turf, a war starting, perk points sitting unspent
- **Setup wizard.** "New Crew" in the staff console walks the whole thing in six steps — name and colour, boss, size and treasury, draw their first block on the map, drop their property, review. Nothing is written until the last button, so backing out leaves no half-made crew behind
- **Full map editor.** Draw turf as a polygon by clicking the satellite map in the tablet, corner by corner, with undo and a ground-height field. The same map shows every zone, every crew placement and every blip, and clicking a zone selects it
- **Turf influence.** Stand on a block and your crew builds a share of it. Every zone shows the split — "Ballas 68% · Vagos 22%" — on the map, the turf card and an in-world HUD bar
- **Zones are staff-owned.** There is no neutral turf and nothing a player does moves a block between crews. Staff draw a zone FOR a crew and it stays theirs; a rival tops out at 60% and the map just shows they're all over it. A zone with nobody assigned is invisible to players
- **Staff placement.** Drop a crew's HQ, garage point, safe, medic station — anything in the unlock list — straight onto the map. Tier, price and the stand-inside-your-own-turf rule are all skipped, and the crew is granted the unlock so they can move it later
- **Blip creator.** Make map markers for a crew: label, sprite, colour, scale, and whether it is crew-only or on everyone's map. Placed by clicking the map
- **Dealer setup screen.** Stock pool, where he turns up and every timing knob, all editable live from the staff console and stored in the database. config.lua is only the seed now — the panel says when a list is still coming from the file
- **One shared clinic.** The medic station is a fixed spot the whole server uses, set in `Config.Medic.station` — coords, heading, prop and blip. It is no longer something a crew buys and places, so every gang works out of the same clinic
- **Unlocks cost money.** Reaching a tier makes something buyable; the crew bank pays for it, then you can place it
- **Admin pricing screen** — every unlock and every upgrade level priced live from the tablet. config.lua only sets the defaults, and rows you've changed are flagged with a reset
- **42 graffiti fonts**, up from 4 at the start: spray can, wet paint, bubble, marker hatch, burned, glitch, vinyl, distressed, puddles, moonrocks, beastly, maze, pixels, scribble, dirt, iso, storm, old english, neon, horror, gore, bones, metal, wildstyle, slab, hollow, inline, block, stencil, heavy, poster, speed, loud, cartoon, chunky, script, brush, handwriting, thin marker, military, western
- **Text composer does more than colour**: outline thickness, letter spacing, slant, tilt, case, and four glow styles including neon. The studio preview and the wall share one recipe, so what you see is what goes up
- **Edit a zone's shape.** Loads the polygon that is already there so you nudge corners instead of re-walking the whole block
- Slashing a tyre needs a knife (`Config.Radial.slash.item`), puts one in your hand for the animation, and is re-checked server-side
- Visible spray coming out of the can, on top of the animation
- In-world zone creator — walk the corners of a block and save it. No more guessing coordinates in config
- Raids and gang war. Raid a rival HQ for a cut of their treasury, or declare a full war and fight it out on kills
- Stash raid — win a war and their safe is exposed for 15 minutes. Compass arrow, blip, live distance, and you take real cash and real items out of their vault
- Gang graffiti. Staff hand out custom images per crew, members spray them on any wall. Studio has the catalogue, styled text and freehand drawing
- Gang garage — shared vehicles, per-rank permissions, bays that scale with upgrades
- Gang medic — unlock the station and patch up or revive your own crew in the field
- Contracts board — the old task list, now rotating, with categories, difficulty and a cash payout on top of rep
- Treasury upgrades — spend the crew's money on permanent boosts. Separate from perk points, which you still earn by levelling
- Custom ranks. Build your own ladder per gang: name and 26 individual permissions
- Street standing — every crew on the server ranked side by side
- Live command centre — real-time map of where your crew actually is
- F6 field radial (rebindable) — spray, garage, medic, work turf, cuff, bag, trunk, carry, escort, hostage, search and rob, slash a tyre
- Solo test mode — admins spawn NPC defenders so one person can run the whole influence and raid loop
- Far more unlocks to place: HQ, safe, garage point, medic station, contract drop and a pile of decoration
- Crew notice the boss can set, shown to everyone on the tablet
- Real-time sync — roster changes, turf shifts and war scores land without reopening
- Four Discord webhook categories now, war is the new one
- `/xstagdebug` — says which of the six reasons a tag is not on the wall: no tags known, none in range, or no surface finished loading
- `/xsunstick` — clears a stuck busy flag, NUI focus and any hanging progress bar for whoever runs it, so a bar broken by any resource does not mean reconnecting
- `/checkmodels` validates every prop config.lua references in one pass
- `Config.OpenCommandNeedsItem` — make `/gangops` require the tablet item on a live server

### Changed

- No more blue box around the spray preview - the artwork itself shows you where it lands
- **Brighter, sharper UI.** The grain was at 40% opacity and a 2px scanline ran over every surface; between them text never looked crisp. Both are far lighter now, text contrast is up, and the palette is properly saturated instead of tinted grey
- Colour carries meaning: each log category has its own, and the hub cards run through six hues so the grid is something you aim at rather than read
- Spray particles take the crew's colour. GTA ships no paint effect, so it is an approximation — `Config.Graffiti.anim.ptfx.enabled = false` turns it off
- Gang-only. Every app requires membership; no gang gets you a locked screen
- Whole UI redesigned in black and dark blue — glass panels, lit edges, real gloss instead of flat fills. The gang's own colour still rides on top of it
- "Command" is now **Hub**, and it's a homepage instead of a stat dump
- **Turf is tablet-only.** No zone circles or crew markers on the pause map — `Config.Territory.worldBlips` turns them back on if you want them
- **The F6 wheel no longer takes the screen.** You keep the view and can still walk while it is up
- Decoration cut from the unlock list. Everything left does something: laptop HQ, locker vault, garage point, safe, bench, contract drop, roadblock
- The vault's prop grows with the Vault Expansion upgrade — locker, second locker, shipping container
- No stock cars for the garage. It is somewhere the crew parks what they already own; staff can still gift one by typing a model
- **No presets.** `Config.Territories` and the graffiti catalogue ship empty. Nothing exists on a fresh install until staff make it, which is the point — draw your own map rather than deleting somebody else's
- Turf map shows the influence split on the map itself: a standing label per zone, and a hover card with each crew's share
- The spray preview is the actual artwork on the actual wall now, not an outline you had to imagine the tag inside
- Spray animation and the can prop moved into `Config.Graffiti.anim`. A dict that will not stream prints why and skips the animation instead of leaving you stuck
- Sidebar rebuilt. Apps grouped by what they're for (Crew, Streets, Assets, Intel), each one an icon tile instead of a bare glyph, live badges on the ones with something waiting, and the selected row fills in
- Every panel sits on a real surface now — top highlight, hairline, drop shadow and a fine grain over the shell, instead of flat fills
- Hero shows the full tier ladder, so you can see where the crew sits across the whole climb rather than just the current tier name
- Stat cards rebuilt: icon chip, bigger number, a fill bar where the stat is really a ratio, and a subtitle that says something new instead of restating the value
- Turf cards draw each zone's actual footprint, so two blocks never look the same
- War room is the loud screen it should be — each side washed in its own gang colour, big scores, a meter that leans toward whoever is winning
- Contracts look like dossiers: punched tab, job code, payout ruled off from the brief
- Standings have a score bar behind each row, in that crew's colour
- Grids and lists stagger in instead of snapping
- Admin panel rebuilt — create a crew in one form (colour, boss, cap, starting treasury, starting turf, notice), edit ranks live, draw turf, set prices, manage graffiti, stop wars, run test mode
- Creating a zone asks which crew it belongs to
- Territory is polygons now, not circles
- Permissions rewritten from 7 to 26. "Abandon turf" is gone (nothing to abandon — staff own assignment) and "Set the crew notice" takes its slot; "Capture turf" is now "Work rival turf"
- "Notoriety" is just **rep** everywhere — config, UI, exports. `Config.Notoriety` is `Config.Rep`, and the export is `AddRep` (the old `AddNotoriety` still works). The database column keeps its old name; renaming a live column buys nothing

### Removed

- Boosting. It was never a gang system and it doesn't belong on a gang tablet
- Payroll. No wages, no salary per rank, no hourly run. The crew bank is for unlocks and upgrades, and that's it
- Claiming, capturing and abandoning turf — staff own assignment now

Nothing is dropped from your database by upgrading. When you're happy you don't want any of it back, these are the leftovers:

```sql
DROP TABLE IF EXISTS `xs_boost_log`, `xs_boost_perks`, `xs_boost_stats`;
ALTER TABLE `xs_gang_ranks` DROP COLUMN `salary`;
ALTER TABLE `xs_gangs` DROP COLUMN `salary_last`;
ALTER TABLE `xs_territories` DROP COLUMN `flip_cooldown`;
ALTER TABLE `xs_gangs` DROP COLUMN `dues_amount`, DROP COLUMN `dues_last`;
ALTER TABLE `xs_gang_members` DROP COLUMN `dues_paid_at`;
DELETE FROM `xs_gang_placements` WHERE `unlock_id` = 'gang_medic';
DELETE FROM `xs_gang_unlocks` WHERE `unlock_id` = 'gang_medic';
```

### Fixed

- **Tags never painted.** The render message was sent the instant `IsDuiAvailable` returned true - but that reports the surface existing, not the page's script having attached its message listener. The one send landed on nothing, and because it was never repeated the texture stayed blank for good while every other check reported healthy. It is re-sent for two seconds now, and the page re-applies the last payload once the DOM and web fonts settle
- Console output was not ASCII, so every em dash arrived as "?" in the FiveM console
- **Tags never appeared on a wall.** `DrawSpritePoly` takes a UVW triplet per vertex and every W was 0.0 — the u/w divide is degenerate at zero, so all four triangles rendered correctly and sampled nothing. The DUI, the texture and the geometry were all fine the whole time, which is why nothing ever errored
- The tag texture was bound to its DUI handle before the page had loaded, so the binding could resolve to nothing. It waits for the surface now
- **Every ox_target option in the resource could silently not exist.** Whether ox_target was running got asked once while the files were still being parsed and cached — if this resource started first, the answer was "no" forever, and no prop, ped, dealer or van ever offered an option. It is asked when needed now
- **Contract peds floated.** The ground placement ran the instant the ped was created, before the collision under it had streamed, so it quietly did nothing — and the freeze that followed locked the ped mid-air. It waits for the ground to exist first
- Clicking the F6 wheel threw punches, because keeping game input also hands the mouse to the game. Attack and melee are held off for exactly as long as the wheel is up
- **Courier contracts died on an invented native.** `GetOffsetFromCoordInWorldCoords` does not exist — only the entity form does — so the quartermaster never spawned and the job stopped dead. `tools/check-natives.mjs` now flags made-up native names across every Lua file, not just client-only ones on the server
- Placed props had no height control, so nothing could go on a desk or a roof. Arrow keys move it, shift moves it faster, G re-seats it, and the ghost now sits on whatever surface is actually beneath it instead of assuming the floor is level with your feet
- Spray particles ran on their own timer and carried on after the progress bar ended
- **A failed progress bar locked the inventory out.** ox_lib raises `invBusy` for the duration of a bar and lowers it at the end; a bar that throws never reaches the second half, and ox_inventory then refuses to open with "cannot open inventory (is busy)" until the player reconnects. All nine bars in the resource go through one guard now that checks the animation first and always puts the flag back
- **Every server tick that read a ped was dying silently.** `IsEntityDead` is a client native and is simply nil server-side, so the live map, the influence survey and war scoring each threw the moment they ran. `tools/check-natives.mjs` now fails the build on the whole class
- **The contracts board was never read.** `tasks:getAvailable` returns `{ tasks, active }` and the UI unwrapped it as a Lua multi-return, so the list was always empty
- **Tags came out mirrored.** The quad's right vector was built as `normal x up`, which points along the viewer's left when you're stood facing the wall — text read backwards
- **Slashing a tyre did nothing at all.** It asked ox_lib for `melee@holster@streamed_core`, which is not a real dictionary; progressBar threw and the action never reached the server. Animations are picked from a candidate list now and checked with `DoesAnimDictExist` first
- The graffiti render loop could spin forever evicting a surface that was never created, which stopped every tag on the map from drawing
- The radial's Revive entry now says "Not at the clinic" when that is the reason it is greyed out, instead of only ever "Nobody close"
- **A new zone vanished the moment you made it.** The admin zone list filtered out anything without a shape — and a zone has no shape until you give it one, so every zone you created disappeared with no row left to draw it from
- Staff-only zones, including ones with no crew on them, were pushed to every player's map on each turf update. The broadcast now sends the same public list the tablet does
- Spraying could jam permanently: an error anywhere in the aim loop left the "already spraying" lock set, and every later attempt returned silently — no prompt, no preview, no animation. The lock is always released now, dying mid-spray included
- Graffiti surfaces thrashed when several tags were in range at once: the render loop touched them nearest-last, so the next frame evicted whatever you were stood in front of and nothing ever finished loading
- Opening an app on the player tablet cleared the staff console's selected row — both rails use the same class and the selector wasn't scoped
- Spray raycast never found a wall — `GetShapeTestResult` returns a boolean and it was compared against `1`
- Hands-up check for search and rob always read as false, same reason
- `sql/xs_criminaltablet.sql` failed on a server that had ever run 1.x: foreign keys were named, InnoDB keeps those names unique per database, and a leftover name blocked the table. The names are gone — InnoDB picks its own now
- Co-op contracts never paid the crew bonus `Config.TasksCoop.rewardBonusPct` promised; the cash pot is now bonused and split evenly, with rep and XP still paid in full to everyone

## [1.1.0] - 2026-09-11

### Changed

- Rename to XS-CriminalTablet, plus the 1.0.2 work
- 1.0
- Territory map is now the real satellite map
- Make the escaping checker understand where a value is going
- Inline the release announcer instead of calling the private repo
- Announce releases to Discord
- Link the whole Cipher line from the README
- Attach a packaged zip to every release

### Fixed

- Map calibration fix — pins now sit exactly where things are
