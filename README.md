<h1 align="center">XS-CriminalTablet</h1>

<p align="center">A gang-only criminal tablet for <strong>QBox</strong> and <strong>QBCore</strong> — turf war, raids, graffiti, garage and contracts in one encrypted device.</p>

<p align="center">
  <a href="https://github.com/XyraL/XS-CriminalTablet/releases"><img src="https://img.shields.io/github/v/release/XyraL/XS-CriminalTablet?style=flat-square&color=55dcff&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/framework-QBox%20%7C%20QBCore-55dcff?style=flat-square" alt="framework">
  <img src="https://img.shields.io/badge/price-free-30d158?style=flat-square" alt="price">
  <a href="https://xyralscripts.dev/docs-xs-criminaltablet"><img src="https://img.shields.io/badge/docs-xyralscripts.dev-a889ff?style=flat-square" alt="docs"></a>
  <a href="https://discord.gg/XRURAw4TM2"><img src="https://img.shields.io/badge/support-discord-5865F2?style=flat-square" alt="support"></a>
</p>

<p align="center">
  <a href="https://xyralscripts.dev/xs-criminaltablet">Website</a> &nbsp;·&nbsp;
  <a href="https://xyralscripts.dev/docs-xs-criminaltablet">Setup guide</a> &nbsp;·&nbsp;
  <a href="https://github.com/XyraL/XS-CriminalTablet/releases">Releases</a> &nbsp;·&nbsp;
  <a href="https://discord.gg/XRURAw4TM2">Discord</a>
</p>

<!-- SCREENSHOTS: drop 2-3 in-game shots here once captured -->

---

## Requirements

- `ox_lib`
- `oxmysql`
- `ox_inventory` (vault, garage items, the device item)
- `ox_target` (optional) — gives the locker, benches, garage point and street
  doc a proper interaction. Falls back to an `[E]` prompt without it.
- Either `qbx_core` **or** `qb-core` — the bridge auto-detects which.

## Nothing is pre-made

`Config.Territories` is empty, the graffiti catalogue is empty, and there are
no seeded gangs. A fresh install has no turf, no crews and no art — you build
all of it from the staff console. That's deliberate: deleting somebody else's
sample data is worse than starting clean.

## Install

1. Drop the `XS-CriminalTablet` folder into your `resources`.
2. Import `sql/xs_criminaltablet.sql`. Upgrading from 1.x? Just run it again —
   every 2.0 column is added with `IF NOT EXISTS` and nothing is dropped.
3. Add the tablet to your `ox_inventory` items.lua:
   ```lua
   ['xs_tablet'] = {
       label = 'Criminal Tablet',
       weight = 500,
       stack = false,
       client = { export = 'XS-CriminalTablet.useDevice' },
   },
   ```
   `/selldrug` buys three bricks off players. Add these too, or point
   `Config.DrugSelling.items` at names you already have:

   ```lua
   ['weed_brick'] = { label = 'Weed Brick',    weight = 1000, stack = true },
   ['coke_brick'] = { label = 'Cocaine Brick', weight = 1000, stack = true },
   ['meth_brick'] = { label = 'Meth Brick',    weight = 1000, stack = true },
   ```

   The graffiti and radial systems also want `spraycan` and `handcuffs` —
   rename them in config if yours are called something else.

   **Images.** The four items above ship in `inventory_images/`. Copy them into
   your inventory's image folder:

   - ox_inventory → `ox_inventory/web/images/`
   - qb-inventory → `qb-inventory/html/images/`
   - ps-inventory → `ps-inventory/html/images/`
   - qs-inventory → `qs-inventory/html/images/`
   - codem-inventory → `codem-inventory/html/itemimages/`
   - core_inventory → `core_inventory/html/img/`

   If yours is not listed, put them wherever its existing item PNGs already
   live. Restart the inventory resource afterwards. `spraycan` and `handcuffs`
   are your server's own items and keep the images they have.
4. `ensure XS-CriminalTablet` in `server.cfg`, after ox_lib, oxmysql, your
   framework and ox_inventory.
5. Grant yourself staff access:
   ```
   add_ace group.admin xs-criminaltablet.admin allow
   add_principal identifier.fivem:1234 group.admin
   ```
6. `/admintablet` in game — make a crew, then draw it a zone.
7. Run `/checkmodels` once. It validates every prop `config.lua` references and
   prints only the broken ones; several of the stock unlock models are worth
   confirming against your build before players start buying them.

## This tablet is gang-only

Every app on it requires gang membership. A player with no gang opens it and
gets a locked screen with whatever `Config.NoGangMessage` says — no rail, no
apps, nothing to poke at. That's enforced server-side, not hidden in the UI.

Gangs are created by staff. There is no in-game "found a gang" flow by design.

## The apps

**Hub** — the crew's homepage. Level, rep, treasury, turf and war record up
top, then a card for every app with its own live number on it, who's online,
and the latest activity. Alerts only appear when something needs a call: a
rival working your turf, a war starting, perk points sitting unspent. A live
tactical map of where everyone actually is right now sits on its own tab, and
the property tab is where you place everything the crew has unlocked.

**Builder** — `/admintablet` for staff. Everything about the tablet is set up
here in game, not in config.lua: crews, turf, jobs, crafting and perks, the
F6 wheel, prices, the dealer and 173 settings. See [Builder](#builder).

**Roster** — invite, promote, demote, kick, hand over the crew. Top
contributors, inactivity flags, live online status. The Ranks tab is the rank
ladder editor: build your own ladder per gang with a name and any
mix of the 26 permissions.

**Turf** — the real satellite map with every zone drawn as its actual polygon.
Shows what you're standing on, whose block it is, and how the share is split if
a rival is working it.

**War Room** — every rival crew with enough intel to pick a target. Raid one,
ask one for a war, answer crews asking you, and watch the meter. Post-war stash
windows show up here.

**Contracts** — a rotating board of jobs with categories, a difficulty rating
and cash on top of rep. Co-op crews, badges, a crew leaderboard, and the
dealer call button.

Turf is deliberately invisible outside the tablet: no zone circles on the
pause map, no crew markers. `Config.Territory.worldBlips` puts them back.

**Street Doc** — one unlicensed doctor the whole server shares, standing where
staff put him (builder → Street doc). Crews buy access at Feared; only then do
they see him in the world and on their Live Map. He patches you up, or brings
back a downed member someone carries in to him. Prices, who pays (cash, bank or
the treasury) and how long he takes are in Settings → Street doc. He tells
qbx_medical, qb-ambulancejob or wasabi_ambulance, whichever you run.

**Garage** — shared gang vehicles. Take one out at the placed garage point
and it comes out beside it with you at the wheel and the keys in your pocket;
put it back, scrap it. Bays scale with the Garage Expansion upgrade. Keys work
with qbx_vehiclekeys, qb-vehiclekeys, wasabi_carlock, Renewed-Vehiclekeys,
qs-vehiclekeys, mk_vehiclekeys, cd_garage, okokGarage, t1ger_keys and
vehicles_keys (`Config.Garage.keys`).

**Crafting bench** — every recipe with its item pictures, what you are
carrying, how many you can make and which tier unlocks the rest. Build up to
10 at once; the time is kept on the server. Crew perks for faster builds and
double output show at the top.

**Crew Locker** — the crew's shared stash, a crate that grows into a stack of
crates and then a shipping container with the Vault Expansion upgrade. Lose a
war and the winner can break into it during the stash window.

**Crew Contracts** — an unlock with nothing to place. Once bought, the crew
earns `Config.Contracts.dropBonusPct` (15% by default) more cash and rep on
every job.

**Studio** — the graffiti library, plus text and freehand composers.

**Treasury** — deposit, withdraw, the ledger, treasury
upgrades and the perk tree.

**Standing** — every crew on the server ranked side by side.

**Rivals** — every other crew, what they have done to you lately, and a
dossier on each: wars, raids and kills both ways, the faces you have run into,
the blocks they hold and a timeline of everything between you.

**Blackmarket** — anonymous world chat and handle-addressed DMs.

## Turf

**Zones are owned, never neutral.** Staff draw a zone *for* a specific crew and
it stays that crew's block until staff move it. **Nothing a player does takes
turf off anyone** — there is no claiming, no capturing and no abandoning. A
zone with nobody assigned is hidden from players entirely; it only shows in the
admin panel, flagged as unassigned.

What a rival *can* do is build a visible **share** of a block by standing in
it, and those shares are what the map and the tablet show:
`Ballas 68% · Vagos 22%`. That is pressure and a talking point, not a countdown
— a rival tops out at `rivalInfluenceCap` (60% by default) and the block still
belongs to whoever staff gave it to. The turf card says so, and the button
reads *Work it (max 60%)* rather than *Claim it*.

The server decides who is standing where by reading each connected player's
real ped position every tick — it never trusts a client saying "I'm in the
zone". Each crew present gains `1 + (extras × perExtraMember)` scaled by their
capture-speed modifiers; the holding crew defends at `holderWeight` and
subtracts from a rival's gain. A gain comes out of the unclaimed slack first,
then proportionally off whoever else has a stake, so the shares on a zone never
exceed 100. With nobody inside, non-holder shares bleed at
`influenceDecayPerMinute` while the holder's stays put.

There is deliberately **no passive income**. Turf is prestige, rep, and the
right to build on it — never a money printer.

Other knobs in `Config.Territory`: a minimum tier before a crew can push
influence onto rival turf, a warning to the holder when a rival first starts
building share, and optional barrier walls along a held zone's edge.

If you *do* want a won raid to take a block, set
`Config.War.raid.captureZoneOnWin = true` — it's off by default because turf is
staff-assigned.

**Gang-locked zones** (on by default): rivals still see the blip and the
influence split — that visibility is the whole point — but they can't
interact with anything placed inside a block they don't hold.

### Drawing zones

Create the zone in the admin panel — you pick which crew it belongs to as part
of creating it — then either:

- **Square here** — drops a quick box around where you're standing.
- **Walk the corners** — closes the panel and hands you the in-world creator.
  `[E]` drops a corner, `[Backspace]` undoes, `[Enter]` saves, `[X]` cancels.
  The polygon is drawn live in front of you, edges and all, and the panel
  reopens when you're done.

## Raids and war

**Raid** — stage cash from your treasury, the defender gets a prep window
(they are always warned, no blindsides), then your crew has to hold their HQ
uncontested for `holdSeconds`. Win and you take a cut of their treasury —
and one of their zones too, if you switch `captureZoneOnWin` back on.
Contested ground bleeds the hold back down rather than resetting it, so
defenders have to actually push.

**War requests** — a war only starts when the other crew accepts. Pressing War
sends them a request; their boss, or a rank that can declare war, accepts or
turns it down in the War Room. Turning it down or letting it run out means no
war and no cost, and the asking crew has to wait before asking them again.
Nothing is charged until they accept. Raids never ask.

**War** — longer, two-sided, and scored on kills between the two crews. First
to lead by `scoreToWin` wins, or whoever is ahead when the clock runs out.
Killing the same person over and over stops scoring for a couple of minutes.

**Objectives** — every war puts up points on both crews' blocks (their HQ if
they hold none). Stand on one alone to take it; taking it scores and holding
it keeps scoring. Both crews on it freezes it. A war is won on the map as well
as on kills.

**Live scoreboard** — both crews in their colours, the score, the clock, the
objectives and a kill feed with names, on screen for everyone in the fight.
A sound plays when your crew takes the lead or loses it.

**Stash raid** — win a war and the loser's placed Crew Locker can be broken
into for a window. A compass arrow, blip and live distance guide you in. You
take real cash out of their treasury and real item stacks out of the locker.
No locker placed means nothing to lose — and nothing for you to find.

## Graffiti

Four kinds of art, and where each one is allowed to come from is the whole
security model:

| Kind | Who can make it |
|---|---|
| Catalogue presets | Built in, every crew starts with them |
| Styled text | Any member, in the studio |
| Freehand drawing | Any member, in the studio |
| **Custom image (URL)** | **Staff only**, per gang, from the admin panel |

Members can save their own text and drawings into the crew library. They can
never introduce a remote URL themselves — that image loads inside every nearby
player's game, so it stays a staff decision.

Tags render in-world as a flat textured quad on the wall they were sprayed on,
fed by a DUI. Only the nearest few tags hold a DUI surface at a time; the rest
simply aren't drawn until you get closer. Spraying over a rival's tag removes
theirs and pays more rep than a blank wall.

The URL has to be a **direct link to the image file**, not a page that shows
it. A dead link renders a visible `?` rather than a blank plate, so you can
tell what went wrong.

Spraying puts a can in your hand. You walk up to the wall, shake it, and the
tag builds up as you spray, with paint mist and sound that nearby players see
and hear. Game build 3258 or newer uses the LS Tags can and animation; older
builds use Lamar's. Mist, sound, walking up and how high a tag can go are in
`Config.Graffiti.spray` and under Graffiti in the builder's settings.

## Ranks and permissions

26 permissions in six groups (roster, treasury, storage, property, turf & war,
operations) — see `shared/permissions.lua`. Adding one there makes it appear in
both rank editors automatically.

A rank is a **name and a permission set**. There is no payroll — no wages, no
salary per rank, no hourly run. The crew bank exists to pay for unlocks and
upgrades, and nothing in this resource prints money.

Two rules hold the ladder together:

1. The top grade is always the boss seat and always keeps everything. Nothing
   can strip the owner's authority and lock the crew out of its own tablet.
2. Nobody may grant a permission their own rank doesn't have, so a Lieutenant
   with `manage_ranks` can't quietly promote themselves. Staff bypass this.

## Progression

Three separate currencies, on purpose:

- **Rep** — the crew's reputation. Drives tier and level. Tiers gate what is
  buyable and which recipes exist; levels award perk points.
- **Perk points** — from levelling. Spent on the perk tree (vault,
  recruitment, workshop, warfare). Four branches, each a chain where tier N
  needs tier N-1.
- **The crew bank** — from actually banking cash. Pays for **unlocks** (the
  things you place in the world) and **upgrades** (roster, vault, garage, war
  chest, street runners).

A crew that grinds rep and a crew that earns money end up in different places.

### Pricing

Every unlock and every upgrade level has a price, and **staff set it live**
from the admin tablet's Pricing tab. `config.lua` only supplies defaults; a
price typed in the panel wins and takes effect immediately, no restart. Rows
you've changed are flagged and get a reset button back to the default. Set a
price to 0 to make an unlock free the moment its tier lands.

Reaching a tier makes an unlock **buyable**; paying for it out of the bank
makes it **placeable**.

## Building

`Config.TierUnlocks` is everything a crew can place, grouped by tier. Each
entry's `kind` decides what it does: `hq`, `vault`, `garage`, `medic` (access
to the street doc), `bench`, `task` (Crew Contracts) or `prop`. An entry with
`placeable = false` works as soon as it is bought.

The **HQ goes anywhere** — it's the crew's home and a new gang holds no turf
yet. Everything else has to sit either on turf the crew holds or within
`Config.Placement.hqBuildRadius` of their own HQ, so a crew's property is
always somewhere they can defend. Placement is a ghost-prop preview: scroll for
distance, Q/E to rotate, Enter to place.

When staff move a zone, the losing crew's placements there are cleared and
they re-place — except the HQ, which survives, because losing it would strand
them.

Model names in config are plain strings, not backtick hash literals:
placements round-trip through a `VARCHAR` column, and a backtick literal
compiles to a number that gets silently stringified into garbage on the way.
Verify anything you add with `/testmodel` first.

## Field radial

`F6` by default (`Config.Radial.key`), and players can rebind it themselves in
Settings → Key Bindings → FiveM. Actions only appear when they're actually
possible — no target nearby means no cuff option.

Spray, garage, work turf, cuff/uncuff, bag head, put in trunk,
carry, escort, take hostage, search and rob, slash a tyre, open the tablet.

Several of these overlap with what a police or inventory script already does.
Turn off whatever your server already handles on the **Radial** page in the
builder, where you can also rename actions and drag them into order with the
wheel drawn live beside the list.

The restrained state (cuffed, bagged, carried, hostage) lives **server-side**,
so neither the aggressor nor the victim decides on their own whether someone is
cuffed. A restrained player whose captor disconnects is released rather than
stuck in an animation nobody can clear.

## Builder

`/admintablet`, gated by the `xs-criminaltablet.admin` ACE. Every action is
re-checked on the server. `Ctrl+K` searches every page, crew, block and
setting.

- **Overview** — crews, members, turf, money, wars and contests at a glance.
- **Crews** — make a crew, set the boss, add members on a chosen rank, edit
  ranks, the garage, and reset or disband. Every box that takes a person
  searches online players and offline characters by name, server ID or
  citizenid.
- **Turf** and **Blips** — draw blocks on the satellite map or walk them in
  game, and place crew map markers.
- **Jobs** — edit the contract jobs from config.lua or make your own: courier
  runs, hits, escorts and heists. Walk to each spot and press E to place it.
- **Approvals** — crew logos and tag photos waiting on staff.
- **Graffiti**, **Dealer**, **Dealer setup** and **Prices** — as before. Dealer
  setup picks items from a searchable list.
- **Street doc** — where the one street doc stands, and which crews have him.
- **Crafting and perks** — bench recipes, the perk tree and treasury upgrades.
- **Wars**, **Blackmarket** and **Test mode** — the live tools.
- **Radial** — what is on the F6 wheel and in what order.
- **Settings** — 173 settings in sections, searchable. Saving puts them live
  for everyone at once and wins over config.lua; each changed one shows its
  config.lua value with a reset.

## Framework gangs

On a crew's settings in the builder, pick a gang from your framework's own
list (QBCore shared gangs or QBox gangs). Anyone the framework puts in that
gang joins the crew on the rank matching their framework grade, and leaves when
the framework takes them out. Changes made on the tablet go back to the
framework. Crews that are not linked are never touched.

Kicking someone who is offline from a linked crew also takes them out of the
framework gang on QBox. On QBCore the framework can only be changed for players
who are online, so remove them there too.

## Crew uploads

Crews can send their own logo (Roster → Logo) and their own photos to spray as
tags (Studio → Own Photos). Both wait on the Approvals page; nothing shows in
game until staff approve it. A logo replaces the crew's initials on the
tablet, the war scoreboard and to rivals. Links must be direct https links to
a .png, .jpg, .webp or .gif.

## Rival intel

When a rival tags a crew's wall, works their block, hangs round their HQ or
takes one of them out, that crew is told straight away and the spot flashes on
their map. All of it is kept for the Rivals app. Cooldowns, the HQ range and
how long history is kept are in Settings → Rival intel.

## Solo test mode

Off unless an admin turns it on, and every player sees a **TEST MODE** badge on
their tablet while it's live. NPC defenders count as real bodies on the
defending side, so the influence bar behaves exactly the way a real fight would —
otherwise it wouldn't be testing the same code path players actually hit.

## Discord logging

Optional. Set any of `adminWebhook` / `gangWebhook` / `economyWebhook` /
`warWebhook` in `Config.Discord`:

- **admin** — every action taken through `/admintablet`, the audit trail
- **gang** — founded, disbanded, boss changed
- **economy** — deposits, withdrawals, unlock and upgrade purchases
- **war** — captures, raids, wars, stash loots

Leave any blank to disable that category. Nothing is required.

## Exports

```lua
exports['XS-CriminalTablet']:AddRep(gangId, amount, reason)
exports['XS-CriminalTablet']:GetPlayerGang(src)        -- { id, name, label, color } or nil
exports['XS-CriminalTablet']:HasGangPermission(src, perm)
exports['XS-CriminalTablet']:GetGangTerritories(gangId)
```

`Config.SyncFrameworkGang` (off by default) mirrors membership into the
framework's own gang field so jobs, doors and dispatch can see it. Only turn it
on if your framework's gangs aren't already managed elsewhere.

## Debugging

- `/checkmodels` (admin only) — validates every model `config.lua` references
  in one pass and prints only the broken ones to the F8 console. Run this
  before a test; an invalid prop otherwise fails silently at placement time.
- `/testmodel <name> [ped]` (admin only) — checks `IsModelValid` and spawns the
  model in front of you for 6s. Use it before adding any model name to
  `config.lua`; guessed model names fail silently or with confusing errors.
- `Config.Debug = true` prints bridge detection, rep changes and tick errors.

### Upgrading to 3.0

Replace everything except your config.lua. No SQL to run: the new tables and
columns create themselves on start. The Crew Safe is gone: crews that bought
one get what they paid back into their treasury on the first start, and the
stash raid uses the Crew Locker. Take `Config.TierUnlocks`, `Config.Medic`,
`Config.Radial.actions` and `Config.Vault.levelModels` from the new
config.lua. Settings, jobs, crafting and perks you
change in the builder are stored in the database, so config.lua stays as your
defaults.

### Upgrading from 2.0.0

2.0.1 corrected the satellite map, which was out by up to 300m at the edges.
Anything you made by **clicking** the map editor before that — zones drawn on
the map, crew blips, staff-placed property — was saved where the click used to
land, and fixing the map does not move it.

From the server console:

```
xsmapfix          report what would change, writes nothing
xsmapfix apply    fix it
```

Back up the database first. It is not safe to run twice, so it records that it
ran and refuses a second pass. Zones you walked out with the in-world creator,
props your crews placed themselves, graffiti and vehicles all came from real
in-game positions and are left alone. Restart the resource afterwards so the
cached copies reload. If you had not drawn anything yet, there is nothing to do.

## Architecture note

Nothing in the UI talks to gang logic directly. The NUI calls a single relay
(`call`), which routes to validated `ox_lib` server callbacks through an
allowlist. The server is the sole source of truth for permissions and state —
the UI only ever greys things out for tidiness, never for security.

## Known limits

- Money assumes both frameworks expose `Player.Functions.AddMoney/RemoveMoney`.
  Verify against your build and adjust `bridge/framework.lua` if needed.
- Placement bound-checks the final spot against the placing player's real
  position server-side, but otherwise trusts the client-reported ghost
  position. Fine for a permissioned action, not meant to resist a malicious
  client.
- Garage vehicles spawn client-side so they inherit whatever your fuel
  resource expects. The DB owns the state; the spawn itself is trusted. Keys
  are handed over by the server, only for a car the crew really has out.

---

## Documentation

Full setup guide, requirements and troubleshooting:
**[xyralscripts.dev/docs-xs-criminaltablet](https://xyralscripts.dev/docs-xs-criminaltablet)**

## Support

- **Found a bug?** [Open an issue](https://github.com/XyraL/XS-CriminalTablet/issues)
- **Need setup help?** [Join the Discord](https://discord.gg/XRURAw4TM2) — check the setup guide first, it usually has the answer

## My other scripts

All free, all source-available.

| Script | What it is |
|---|---|
| **[XS-MDT](https://github.com/XyraL/XS-MDT)** | multi-department MDT for QBox — police, EMS and fire with live CAD, records, patient care and a live unit map. |
| **[XS-AdminMenu](https://github.com/XyraL/XS-AdminMenu)** | advanced admin suite for QBox and QBCore — player management, bans, reports, inventory tools and entity inspection. |
| **[XS-Drone](https://github.com/XyraL/XS-Drone)** | deployable police drone for QBox and QBCore — smooth flight, thermal, spotlight, tracker darts and real counterplay. |
| **[XS-Trucking](https://github.com/XyraL/XS-Trucking)** | civilian trucking job for QBox and QBCore — live route map, truck ownership, fuel and maintenance, and companies. |
| **[XS-MultiCharacter](https://github.com/XyraL/XS-MultiCharacter)** | cinematic character selection for QBox and QBCore — identity dossiers, saved appearances, spawn cameras and configurable slots. |
| **[XS-Dispatch](https://github.com/XyraL/XS-Dispatch)** | multi-department live dispatch for QBox and QBCore — responder tracking, priority calls, TAC radio and provider integrations. |

## License

Free to use on any server you own or operate, including commercial ones.
**Do not redistribute or resell** — see [LICENSE](LICENSE) for the full terms.
