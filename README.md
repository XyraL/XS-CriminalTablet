<h1 align="center">Cipher</h1>

<p align="center">A modular criminal device for <strong>QBox</strong> and <strong>QBCore</strong> — gang ops, blackmarket and boosting in one encrypted tablet.</p>

<p align="center">
  <a href="https://github.com/XyraL/cipher/releases"><img src="https://img.shields.io/github/v/release/XyraL/cipher?style=flat-square&color=55dcff&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/framework-QBox%20%7C%20QBCore-55dcff?style=flat-square" alt="framework">
  <img src="https://img.shields.io/badge/price-free-30d158?style=flat-square" alt="price">
  <a href="https://xyralscripts.dev/docs-cipher"><img src="https://img.shields.io/badge/docs-xyralscripts.dev-a889ff?style=flat-square" alt="docs"></a>
  <a href="https://discord.gg/XRURAw4TM2"><img src="https://img.shields.io/badge/support-discord-5865F2?style=flat-square" alt="support"></a>
</p>

<p align="center">
  <a href="https://xyralscripts.dev/cipher">Website</a> &nbsp;·&nbsp;
  <a href="https://xyralscripts.dev/docs-cipher">Setup guide</a> &nbsp;·&nbsp;
  <a href="https://github.com/XyraL/cipher/releases">Releases</a> &nbsp;·&nbsp;
  <a href="https://discord.gg/XRURAw4TM2">Discord</a>
</p>

<!-- SCREENSHOTS: drop 2-3 in-game shots here once captured -->

---

## Requirements
- `ox_lib`
- `oxmysql`
- `ox_inventory` (for the vault/armory + the device item)
- `ox_target` (optional) — gives the vault, benches, and the dealer ped a
  proper target interaction. Falls back to an `[E]` proximity prompt if not started.
- Either `qbx_core` **or** `qb-core` — the bridge auto-detects which.

## Install
1. Drop the `cipher` folder into your `resources`.
2. Import `sql/cipher.sql` into your database.
3. Add an item named `cipher_tablet` to your `ox_inventory` items (or change
   `Config.DeviceItem`). Give yourself one, or use the `/gangops` command.
4. Add `ensure cipher` to your `server.cfg` (after ox_lib, oxmysql, your framework,
   and ox_inventory).
5. Tune `config.lua` — ranks, permissions, territory zones, notoriety, perks.

## What's wired
- Framework bridge with one unified API (`bridge/framework.lua`).
- Gangs are admin-defined only — invite/accept, kick, promote/demote happen
  in-game; create/disband/boss changes happen on the admin tablet.
- Rank + permission system (config-driven, per-gang ranks in DB).
- Personal rep per member, feeding a gang-wide notoriety total with tiers.
  No idle decay — the only way rep drops is the friendly-fire penalty
  (`Config.Notoriety.friendlyFirePenalty`, killing your own gang member) or
  an admin adjustment. Exported as
  `exports.cipher:AddNotoriety(gangId, amount, reason)` so other resources
  can feed it.
- Territory: zones are assigned to a gang entirely through the admin tablet —
  there is no in-world capture and **no passive income**, holding a zone is
  prestige/visual only. Admins can create a zone and set its coords to their
  current position, rename it, and assign or clear its holder. The map blip
  radius grows with the holding gang's tier (`Config.ZoneRadiusGrowthPerTier`)
  — purely visual. The Territory tab also renders a stylized SVG map (a
  procedural landmass silhouette, terrain-tinted districts, compass, radar
  sweep) plotting zones by their real world coordinates — not a literal
  GTA map image, just enough to read as one.
- Gang levels: a more granular prestige number + title (`Config.GangLevels`,
  e.g. "Crew" → "Untouchable") layered on the *same* notoriety value the 4
  broad tiers already use — purely additive, doesn't touch tier-gated
  unlocks. Crossing a level threshold awards perk points.
- Gang perk tree (`Config.GangPerks`, Boss-only via `manage_perks`): three
  branches — Vault (slots/weight), Recruitment (max members), Workshop
  (craft time/bonus output/early recipe-tier unlock) — each a chain of
  tiers where tier N requires tier N-1 in that branch already owned. Spent
  from the perk points gang levels award.
- Tier unlocks: once a gang's notoriety reaches a tier, the Boss (or anyone
  with `place_objects`) can place that tier's benches anywhere — open the
  tablet's **Unlocks** tab, hit Place, then use scroll to set distance, Q/E to
  rotate, Enter to confirm. Locked entries show the tier/rep still needed.
- Vault: a physical container, not a remote button. Place it from the same
  Unlocks tab; opens via `ox_target` (or an `[E]` prompt without it) when
  standing near it. Backed by a per-gang `ox_inventory` stash.
- Crafting: targeting a placed bench opens a dedicated themed panel (not a
  plain list) with a cinematic camera push-in and a progress-ring "Craft"
  button. There's one bench, but recipes (`Config.Recipes`) each carry a
  `tier` requirement, so higher gang tiers unlock more recipes at that same
  bench instead of needing a separate "Advanced Workbench". Locked recipes
  show grayed out with their tier requirement. Inputs/outputs are validated
  server-side against the player's actual inventory.
- Dealer: on-demand, not placed. The tablet's **Tasks** tab has a "Call Dealer"
  button — one call at a time server-wide on `Config.Dealer.cooldownHours`
  (a global cooldown, not per-player). The ped spawns at a random
  `Config.Dealer.spawnPoints` entry and despawns after `timeoutMinutes` if
  nobody reaches it. Stock rotates independently on `rotateMinutes` with a
  randomized price per `Config.Dealer.pool` entry. Empty by default; add pool
  entries to enable it.
- Drug selling: target any nearby NPC ped (`ox_target`, or `/selldrug` to grab
  the nearest one without it) — works anywhere, not gated to territory. A 5s
  progress bar plays out the deal, then the server validates the actual item
  count and a per-player cooldown before paying cash (+ rep if the seller's in
  a gang). Defaults to a few common drug item names — rename to match your
  `ox_inventory` items.lua.
- Tasks: solo jobs for personal + gang rep, fully server-validated.
  - `type = 'delivery'` (default): target the pickup item, then target a
    delivery ped at the dropoff to hand it off — each step re-checks the
    player's actual position server-side at that moment. Optional `carryProp`
    attaches a prop to the player between the two stages for flavor.
  - `type = 'kill'`: server picks a random `spawnPoints` entry; client spawns
    an armed hostile NPC there and reports back when it's dead. The server
    only trusts that report after `minKillSeconds` — a real trust concession,
    bounded by that minimum plus the normal cooldown/time-limit system.
- Treasury: **no forced dues** — every member can deposit whenever they want;
  withdrawing stays gated to `manage_bank` so one member can't drain it solo.
  Styled like an actual bank statement, with a dedicated transaction ledger
  (`cipher_gang_bank_log`) separate from the general activity log, plus the
  gang's full notoriety/tier shown alongside the balance.
- Member activity tracking: `last_seen` updates whenever a member opens the
  tablet; the roster flags anyone inactive past `Config.GangInactivityDays`
  and shows a top-contributors mini-leaderboard by personal rep.
- NUI tablet: main overview (gang level/title badge + progress bar toward the
  next tier, animated count-up stats), roster (click a member for
  kick/promote/demote + personal rep + last-seen + online status), territory
  map, tasks, unlocks (shows rep needed for anything still locked), treasury,
  perks, activity log. The activity log covers tasks started/completed, drug
  sales, dealer calls/purchases, crafting, and perk purchases — not just
  membership/bank/placement events.
- Blackmarket app: anonymous world chat + handle-addressed DMs. **Requires
  being in a gang** — the app doesn't even show in the rail otherwise (this
  is enforced server-side too, not just hidden in the UI). Every character
  gets a persistent, custom-editable anonymous handle (e.g. `ShadowFox-A1B2`,
  ✎ to rename) — never tied to gang label, so even affiliation stays hidden.
  A shared world feed (`Config.Chat.worldHistoryLimit` messages kept) plus
  DMs addressed by handle, since that's the only identity anyone has — the
  server is the only thing that ever resolves a handle to a citizenid.
  Live-delivered if you're online, persisted either way.
- Boosting app: car theft, **open to everyone** regardless of gang
  membership — the one app that isn't gated, and fully standalone (no
  gang rep, no gang tie-in of any kind — see `server/boosting.lua`).
  Personal level + XP only this system tracks (`cipher_boost_stats`).
  `Config.Boosting.levels` is a cumulative tier list: at level N you can
  be assigned any vehicle from levels 1..N, each picking a random spot
  from its own `spawns` list. No custom lockpick/hotwire minigame here —
  the vehicle spawns locked with no owner/keys, and qbx_core's own
  vehicle break-in/hotwire system handles the actual theft; we just watch
  for the engine to actually start. Once it does, that fires an optional
  police dispatch hook (`Config.Boosting.dispatch` — disabled by default,
  the event/payload shape is just an example for `cd_dispatch` and needs
  adjusting to whatever dispatch resource you actually run). Bring the
  car to the drop-off, get out, and sell it to the buyer ped — validated
  by the vehicle's actual position, not the player's, so you can't just
  walk up without it. `Config.Boosting.guards` spawns armed hostiles near
  the target vehicle while you steal it — a friend can fight them off
  while you work. `Config.Boosting.wanted` keeps several bonus-paying
  "wanted" vehicles active at once (refreshed on `rotateMinutes`, not a
  rare one-off), available at any level alongside the normal pool. The
  Job tab shows those wanted vehicles, a preview of what you might get at
  your level, and a server-wide recent-sells feed; a Badges tab tracks
  config-defined milestones (`Config.Boosting.achievements`); a
  Leaderboard tab ranks the top 10 by lifetime cars boosted.
  - **Perks**: every level grants perk points (`Config.Boosting.levels[*].perkPoints`),
    spent on permanent, passive upgrades from `Config.Boosting.perks` — cash
    bonus %, fewer guards, a delayed dispatch alert, or a cheaper cooldown.
    No inventory items involved, nothing consumed.
  - **Co-op**: invite a specific nearby player (like a gang invite) to crew up
    on a separate, harder job — a bigger guard count, a shorter clock, and
    dispatch always fires instantly regardless of any Signal Jammer perk.
    Cash gets a bonus (`Config.Boosting.coop.cashBonusPct`) before splitting
    evenly across the crew; XP is **not** split, every member gets the full
    amount. Only the crew leader's client actually spawns the vehicle/guards/
    buyer ped (everyone else just sees it and can help fight) — this matters
    if you ever touch `client/boosting.lua`, since spawning per-member would
    create duplicate entities.

## Admin tablet
Staff manage everything in-game instead of editing config.lua/the DB by hand.
- Grant access in `server.cfg`:
  ```
  add_ace group.admin cipher.admin allow
  add_principal identifier.fivem:1234 group.admin
  ```
  (or add `cipher.admin` to whatever principal/group fits your setup)
- Run `/admintablet` to open the panel — six tabs:
  - **Dashboard**: at-a-glance totals (gang count, zones assigned, total gang
    bank, boosting player/total/active-job counts, chat message/handle
    counts, dealer cooldown status).
  - **Gangs**: create/rename gangs, set boss, disband, kick/promote members,
    adjust a member's personal rep or a gang's notoriety, force-set the bank
    balance.
  - **Zones**: create a zone at your current position, move/rename it,
    assign or clear its holder.
  - **Boosting**: search any player by name or citizenid, directly edit their
    level/XP/total boosted/total cash/perk points, or reset them to scratch
    (also wipes owned perks).
  - **Blackmarket**: view recent world chat with delete buttons, and a
    handle→citizenid resolver for when you need to break the anonymity for
    moderation.
  - **Dealer**: view current rotating stock, force a reroll, or clear the
    global contact cooldown live.
- Everything here writes straight to the database — `Config.Gangs` is only
  used to seed gangs on first boot, not as an ongoing source of truth.
- Every action across every tab re-checks the ACE permission server-side
  (never just hidden client-side) and logs to the Discord admin webhook.

## Discord logging
Optional — set any of `Config.Discord.adminWebhook` / `gangWebhook` / `economyWebhook`
to a Discord webhook URL to get live embeds for:
- **admin**: every action taken through `/admintablet` (the audit trail)
- **gang**: founded / disbanded / boss changed
- **economy**: deposits, withdrawals, dealer purchases

Leave any of them blank to disable that category — nothing is required. Get a
webhook URL from Discord: channel settings → Integrations → Webhooks → New
Webhook → Copy URL.

## Debugging
- `/testmodel <name> [ped]` (admin-only) — checks `IsModelValid` and spawns the
  model in front of you for 6s. Use this before adding any model name to
  `config.lua`; recalled/guessed model names are unreliable and fail silently
  or with confusing errors otherwise.

## Known stubs / next passes
- Money API assumes both frameworks expose `Player.Functions.AddMoney/RemoveMoney`;
  verify against your build and adjust the bridge if needed.
- Placement validates the final spot is within 6m of the placing player (server-side),
  but otherwise trusts the client-reported ghost position — fine for a permissioned
  Boss-only action, not meant to resist a malicious client.

## Architecture note
Nothing in the UI talks to gang logic directly. The NUI calls a single relay
(`call`), which routes to validated `ox_lib` server callbacks. The server is the
sole source of truth for permissions and state.

---

## Documentation

Full setup guide, requirements and troubleshooting:
**[xyralscripts.dev/docs-cipher](https://xyralscripts.dev/docs-cipher)**

## Support

- **Found a bug?** [Open an issue](https://github.com/XyraL/cipher/issues)
- **Need setup help?** [Join the Discord](https://discord.gg/XRURAw4TM2) — check the setup guide first, it usually has the answer

## The rest of the Cipher line

All free, all source-available.

| Script | What it is |
|---|---|
| **[Cipher MDT](https://github.com/XyraL/cipher-mdt)** | multi-department MDT for QBox — police, EMS and fire with live CAD, records, patient care and a live unit map. |
| **[Cipher Admin](https://github.com/XyraL/cipher-admin)** | advanced admin suite for QBox and QBCore — player management, bans, reports, inventory tools and entity inspection. |
| **[Cipher Drone](https://github.com/XyraL/cipher-drone)** | deployable police drone for QBox and QBCore — smooth flight, thermal, spotlight, tracker darts and real counterplay. |
| **[Cipher Trucking](https://github.com/XyraL/cipher-trucking)** | civilian trucking job for QBox and QBCore — live route map, truck ownership, fuel and maintenance, and companies. |
| **[Cipher MultiCharacter](https://github.com/XyraL/cipher-multicharacter)** | cinematic character selection for QBox and QBCore — identity dossiers, saved appearances, spawn cameras and configurable slots. |
| **[Cipher Dispatch](https://github.com/XyraL/cipher-dispatch)** | multi-department live dispatch for QBox and QBCore — responder tracking, priority calls, TAC radio and provider integrations. |

## License

Free to use on any server you own or operate, including commercial ones.
**Do not redistribute or resell** — see [LICENSE](LICENSE) for the full terms.
