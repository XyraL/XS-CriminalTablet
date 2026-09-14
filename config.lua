Config = {}

-- ─────────────────────────────────────────────────────────────
-- Device
-- This tablet is gang-only. Every app on it requires gang membership —
-- a player without a gang gets a locked terminal screen and nothing else.
-- ─────────────────────────────────────────────────────────────
Config.Debug = false

-- Item that opens the device. Register it in your ox_inventory items.lua
-- with client = { export = 'XS-CriminalTablet.useDevice' }.
Config.DeviceItem = 'xs_tablet'

-- Command to open the device. Handy for testing without the item — set
-- OpenCommandNeedsItem to true on a live server so the command can't be
-- used to skip carrying one.
Config.OpenCommand = 'gangops'
Config.OpenCommandNeedsItem = false

-- Shown on the locked screen when someone with no gang opens the tablet.
-- Point it wherever your server takes gang applications.
Config.NoGangMessage = 'Gangs are formed by staff. Apply on Discord to get one set up for your crew.'

-- ─────────────────────────────────────────────────────────────
-- Blackmarket chat
-- Anonymous codename per character (e.g. "ShadowFox-A1B2"), generated once
-- and persisted — never tied to gang label, so even gang affiliation stays
-- hidden behind the handle.
-- ─────────────────────────────────────────────────────────────
Config.Chat = {
    enabled = true,
    worldHistoryLimit = 100,    -- messages kept/shown in the world feed
    dmHistoryLimit = 100,       -- messages kept/shown per DM thread
    maxMessageLength = 280,
    handleAdjectives = {
        'Shadow', 'Silent', 'Crimson', 'Iron', 'Ghost', 'Night', 'Static',
        'Hollow', 'Rusty', 'Velvet', 'Phantom', 'Cold',
    },
    handleNouns = {
        'Fox', 'Viper', 'Crow', 'Wolf', 'Raven', 'Hound', 'Cobra', 'Hawk',
        'Jackal', 'Lynx', 'Reaper', 'Wraith',
    },
}

-- ─────────────────────────────────────────────────────────────
-- Discord webhooks
-- Leave any blank to disable that category.
--   admin:    every action taken through /admintablet (the audit trail)
--   gang:     structural lifecycle — founded, disbanded, boss changed
--   economy:  deposits, withdrawals, unlock and upgrade purchases
--   war:      captures, raids, wars, stash loots
-- Get a webhook URL from a Discord channel: Edit Channel > Integrations
-- > Webhooks > New Webhook > Copy URL.
-- ─────────────────────────────────────────────────────────────
Config.Discord = {
    adminWebhook = '',
    gangWebhook = '',
    economyWebhook = '',
    warWebhook = '',
    botName = 'XyraL',
}

-- ─────────────────────────────────────────────────────────────
-- Admin tablet
-- Staff-only NUI: gang CRUD, rank editor, turf drawing, graffiti library,
-- war control. No physical item — a command gated by an ACE permission:
--   add_ace group.admin xs-criminaltablet.admin allow
--   add_principal identifier.fivem:1234 group.admin
-- ─────────────────────────────────────────────────────────────
Config.AdminCommand = 'admintablet'
Config.AdminAce = 'xs-criminaltablet.admin'

-- ─────────────────────────────────────────────────────────────
-- Ranks & permissions
-- The permission vocabulary lives in shared/permissions.lua (26 of them,
-- grouped). Bosses build their own ladder per gang in-game; this is only
-- the template applied when a gang is first created.
--
-- Ranks are name + permissions only. There is no payroll: the crew bank
-- pays for unlocks and upgrades, not wages.
-- ─────────────────────────────────────────────────────────────
Config.DefaultRanks = {
    [0] = { name = 'Prospect', permissions = {} },
    [1] = { name = 'Soldier', permissions = {
        'vault_open', 'garage_take', 'garage_store', 'accept_contracts', 'spray_graffiti',
    } },
    [2] = { name = 'Lieutenant', permissions = {
        'invite', 'vault_open', 'garage_take', 'garage_store', 'accept_contracts',
        'spray_graffiti', 'capture_territory', 'view_analytics',
    } },
    [3] = { name = 'Underboss', permissions = {
        'invite', 'kick', 'promote', 'demote', 'bank_withdraw', 'bank_ledger',
        'vault_open', 'garage_take', 'garage_store', 'garage_delete',
        'place_objects', 'remove_objects', 'accept_contracts', 'spray_graffiti',
        'manage_graffiti', 'capture_territory', 'start_raid', 'manage_motd',
        'view_analytics',
    } },
    [4] = { name = 'Boss', permissions = '*' }, -- '*' = every permission
}

-- Base member cap. Upgrades and perks raise it from here.
Config.MaxMembers = 30

-- How many ranks a gang may have on its ladder at once.
Config.MaxRanks = 10

-- ─────────────────────────────────────────────────────────────
-- Gangs
-- Optional first-boot seed only. Everything after that is managed live
-- from the admin tablet — creating, colouring, renaming, boss changes,
-- member caps. Removing an entry here does NOT delete the gang.
-- `color` is a hex string; it drives the tablet accent, map blips,
-- territory shading and the gang's default graffiti tint.
-- ─────────────────────────────────────────────────────────────
Config.Gangs = {
    -- ['ballas'] = {
    --     label = 'Ballas',
    --     color = '#8b5cf6',
    --     boss = 'ABC12345',       -- citizenid
    --     territory = 'grove',     -- optional: starting zone, must exist in Config.Territories
    -- },
}

-- Swatches offered in the admin colour picker. Any hex works — this is
-- just the quick palette.
Config.GangColors = {
    '#e5484d', '#f5a524', '#ffd60a', '#30d158', '#2dd4bf',
    '#38bdf8', '#6366f1', '#8b5cf6', '#ec4899', '#f97316',
    '#a3e635', '#94a3b8',
}

-- Mirror membership into the framework's own gang field so other
-- resources (jobs, doors, dispatch) see it. Off by default — turn it on
-- only if your framework's gangs aren't already managed elsewhere.
Config.SyncFrameworkGang = false

-- ─────────────────────────────────────────────────────────────
-- Rep
-- Gang-wide reputation. No idle decay — it only drops from the
-- friendly-fire penalty, losing turf or a war, or an admin adjustment.
-- Tiers gate unlocks, recipes and which zones a gang may contest.
-- ─────────────────────────────────────────────────────────────
Config.Rep = {
    max = 50000,
    tiers = {
        { name = 'Unknown',     min = 0 },
        { name = 'Local',       min = 1000 },
        { name = 'Feared',      min = 3500 },
        { name = 'Notorious',   min = 7000 },
        { name = 'Untouchable', min = 15000 },
    },
    friendlyFirePenalty = 100,
    -- Other resources can feed this via
    -- exports['XS-CriminalTablet']:AddRep(gangId, amount, reason)
    rewards = {
        member_recruited = 50,
        zone_captured    = 300,
        zone_lost        = -150,
        raid_won         = 500,
        raid_lost        = -200,
        war_won          = 1200,
        war_lost         = -400,
        graffiti_sprayed = 15,
        graffiti_covered = 25,   -- covering a RIVAL's tag pays more than a blank wall
    },
}

-- ─────────────────────────────────────────────────────────────
-- Gang levels
-- A granular prestige number + title layered on the SAME rep value
-- the broad tiers use. Crossing a level awards perk points.
-- ─────────────────────────────────────────────────────────────
Config.GangLevels = {
    { level = 1,  repNeeded = 0,     title = 'Crew',        perkPoints = 0 },
    { level = 2,  repNeeded = 250,   title = 'Outfit',      perkPoints = 1 },
    { level = 3,  repNeeded = 750,   title = 'Syndicate',   perkPoints = 1 },
    { level = 4,  repNeeded = 1500,  title = 'Cartel',      perkPoints = 1 },
    { level = 5,  repNeeded = 3000,  title = 'Family',      perkPoints = 2 },
    { level = 6,  repNeeded = 5000,  title = 'Empire',      perkPoints = 2 },
    { level = 7,  repNeeded = 7500,  title = 'Dynasty',     perkPoints = 2 },
    { level = 8,  repNeeded = 11000, title = 'Untouchable', perkPoints = 3 },
    { level = 9,  repNeeded = 16000, title = 'Kingdom',     perkPoints = 3 },
    { level = 10, repNeeded = 24000, title = 'Legacy',      perkPoints = 4 },
}

-- ─────────────────────────────────────────────────────────────
-- Gang perk tree
-- Permanent, gang-wide modifiers bought with perk_points (earned by
-- levelling). Four branches, each a chain — tier N needs tier N-1 in that
-- same branch. Effects stack as you buy up a branch.
-- ─────────────────────────────────────────────────────────────
Config.GangPerks = {
    vault = {
        label = 'Vault', icon = 'fa-vault', order = 1,
        tiers = {
            { id = 'vault_1', label = 'Reinforced Vault', description = '+25 slots, +25% weight capacity',
              cost = 1, slotsBonus = 25, weightBonusPct = 25 },
            { id = 'vault_2', label = 'Fortified Vault', description = '+50 more slots, +50% more weight capacity',
              cost = 2, slotsBonus = 50, weightBonusPct = 50 },
            { id = 'vault_3', label = 'Underground Vault', description = '+100 more slots, +100% more weight capacity',
              cost = 3, slotsBonus = 100, weightBonusPct = 100 },
        },
    },
    members = {
        label = 'Recruitment', icon = 'fa-users', order = 2,
        tiers = {
            { id = 'members_1', label = 'Open Doors', description = '+10 max members',
              cost = 1, maxMembersBonus = 10 },
            { id = 'members_2', label = 'Word on the Street', description = '+15 more max members',
              cost = 2, maxMembersBonus = 15 },
            { id = 'members_3', label = 'Citywide Reputation', description = '+25 more max members',
              cost = 3, maxMembersBonus = 25 },
        },
    },
    bench = {
        label = 'Workshop', icon = 'fa-screwdriver-wrench', order = 3,
        tiers = {
            { id = 'bench_1', label = 'Quality Tools', description = '-20% crafting time',
              cost = 1, craftTimePct = -20 },
            { id = 'bench_2', label = 'Bulk Production', description = '+25% chance to double craft output',
              cost = 2, bonusOutputChance = 25 },
            { id = 'bench_3', label = 'Master Workshop', description = 'Bench recipes unlock as if one tier higher',
              cost = 3, tierBoost = 1 },
        },
    },
    war = {
        label = 'Warfare', icon = 'fa-crosshairs', order = 4,
        tiers = {
            { id = 'war_1', label = 'Street Discipline', description = '+15% capture speed on rival turf',
              cost = 1, captureSpeedPct = 15 },
            { id = 'war_2', label = 'Entrenched', description = '+25% defence weight when your own turf is contested',
              cost = 2, defenceWeightPct = 25 },
            { id = 'war_3', label = 'Warchest', description = '+20% cash taken from a won raid',
              cost = 3, raidCutPct = 20 },
        },
    },
}

-- ─────────────────────────────────────────────────────────────
-- Treasury upgrades
-- Bought with the gang's MONEY, not perk points — so there are two
-- separate currencies: perk points come from levelling, upgrades come
-- from actually banking cash. Each upgrade is a ladder: buy level 1
-- before level 2, and the cost climbs.
-- Effect keys: maxMembersBonus / vaultSlotsBonus / vaultWeightBonusPct /
-- garageSlotsBonus / raidRewardPct / captureSpeedPct
-- ─────────────────────────────────────────────────────────────
Config.Upgrades = {
    {
        id = 'roster', label = 'Roster Expansion', icon = 'fa-user-plus',
        description = 'Room for more bodies on the books.',
        levels = {
            { cost = 25000,  maxMembersBonus = 5 },
            { cost = 60000,  maxMembersBonus = 10 },
            { cost = 140000, maxMembersBonus = 20 },
        },
    },
    {
        id = 'vault', label = 'Vault Expansion', icon = 'fa-boxes-stacked',
        description = 'More shelves, and heavier ones.',
        levels = {
            { cost = 30000,  vaultSlotsBonus = 25, vaultWeightBonusPct = 20 },
            { cost = 75000,  vaultSlotsBonus = 50, vaultWeightBonusPct = 40 },
            { cost = 165000, vaultSlotsBonus = 75, vaultWeightBonusPct = 60 },
        },
    },
    {
        id = 'garage', label = 'Garage Expansion', icon = 'fa-warehouse',
        description = 'More bays for gang vehicles.',
        levels = {
            { cost = 20000,  garageSlotsBonus = 3 },
            { cost = 55000,  garageSlotsBonus = 6 },
            { cost = 120000, garageSlotsBonus = 12 },
        },
    },
    {
        id = 'warchest', label = 'War Chest', icon = 'fa-sack-dollar',
        description = 'A bigger cut out of every raid you win.',
        levels = {
            { cost = 45000,  raidRewardPct = 15 },
            { cost = 110000, raidRewardPct = 30 },
            { cost = 240000, raidRewardPct = 50 },
        },
    },
    {
        id = 'runners', label = 'Street Runners', icon = 'fa-person-running',
        description = 'Faster captures — your people know the blocks.',
        levels = {
            { cost = 35000, captureSpeedPct = 10 },
            { cost = 90000, captureSpeedPct = 20 },
        },
    },
}

-- ─────────────────────────────────────────────────────────────
-- Territory
-- Zones are OWNED, never neutral. Staff draw a zone for a specific crew and
-- it stays theirs until staff move it. Players cannot take turf off each
-- other — a rival standing on your block builds a visible share of it and
-- nothing more. There is no passive income either: turf is prestige, rep
-- and the right to build on it, never a money printer.
--
-- Zones are polygons drawn live in-game with the admin creator (walk the
-- corners, or drop a quick square). Config.Territories is only a first-boot
-- seed; a seeded zone stays hidden from players until staff assign it to a
-- crew in the admin tablet.
-- ─────────────────────────────────────────────────────────────
Config.Territory = {
    -- Turf on the PAUSE MAP. Off means the only place anyone sees who
    -- holds what is the tablet — no radius circles, no crew markers, no
    -- reading the whole city's politics off the minimap before you have
    -- logged into anything.
    worldBlips = false,

    -- ── Ownership ──
    -- There are no neutral zones. A zone exists because staff drew it FOR a
    -- specific crew, and it stays that crew's block until staff move it.
    -- Nothing a player does takes turf off anyone.
    --
    -- ── Influence ──
    -- What a rival CAN do is build a visible SHARE of a block by standing in
    -- it: "Ballas 68% · Vagos 22%". That split shows on the map, the turf
    -- card and the in-world HUD. It is pressure and a talking point, never a
    -- countdown to losing the zone — a rival tops out at rivalInfluenceCap.
    rivalInfluenceCap = 60,     -- most a rival can reach on someone else's block

    influenceSeconds = 150,     -- seconds for ONE person to move influence 0 -> 100
    influenceDecayPerMinute = 0.5, -- share a gang bleeds per minute with nobody in the zone (0 = never)
    tickMs = 1000,              -- how often the server re-scores every occupied zone
    minPresence = 1,            -- bodies needed inside to shift anything
    perExtraMember = 0.45,      -- each additional body adds this much of a person
    holderWeight = 1.25,        -- the holding crew defends its own block slightly better

    -- A gang must be at least this tier to push influence onto rival turf.
    -- Stops brand-new one-man crews painting the map on day one.
    minTierToContest = 'Local',
    -- Warn the holding crew when a rival first starts building share on
    -- their turf, so they can actually go and stand on it.
    alertOnContest = true,
    -- Gang-locked zones: a zone tied to a gang is private to that gang —
    -- only its members (and admins) see the blip and 3D marker, and only
    -- they can interact with what is placed inside it.
    gangLocked = true,
    -- Optional barrier walls spawned along a held zone's edge. Purely
    -- decorative cover — they do not block anyone from entering.
    walls = {
        enabled = false,
        model = 'prop_barrier_work05',
        spacing = 6.0,     -- metres between wall props along the perimeter
        maxProps = 40,     -- hard cap per zone so a huge polygon can't flood the world
    },
    -- Fallback radius used for zones that have a centre but no polygon yet
    -- (e.g. seeded from Config.Territories below, or created with the
    -- quick "square at my position" button).
    defaultRadius = 60.0,
    defaultSquareSize = 80.0,
}

-- Empty on purpose. Draw every zone on the map in the admin tablet —
-- this list only exists as a first-boot seed for owners who would rather
-- define turf in a file, and anything you add here is created once and
-- then owned by the database.
--
--   grove = { label = 'Grove Street', coords = vec3(-100.0, -1900.0, 25.0), color = 2 },
--
-- `color` is a legacy GTA blip colour, used only when the holder has no
-- hex colour of its own.
Config.Territories = {}

-- ─────────────────────────────────────────────────────────────
-- Tier unlocks
-- Everything a gang can eventually place in the world. Reaching a tier
-- makes that tier's entries placeable by anyone with 'place_objects' —
-- nothing ever spawns on its own. Each entry needs a stable `id`: it's
-- how the gang's chosen position is remembered in the DB.
--
-- `kind` decides what the placed thing DOES:
--   hq      — the crew's home point. Gang blip, radial spawn anchor, and
--             where the airdrop-style countdowns and war staging read from.
--   vault   — the shared ox_inventory stash container.
--   safe    — the raidable cash stash. This is what a rival loots after
--             winning a war, so a gang that places one is opting into risk.
--   garage  — the gang vehicle garage point.
--   medic   — the unlocked gang medic station.
--   bench   — a crafting bench (recipes gate themselves by tier).
--   task    — a contract drop point the contracts board can route to.
--   prop    — pure decoration, no interaction.
--
-- Model names are plain strings, not backtick hash literals: placements
-- round-trip through a VARCHAR column, and a backtick literal compiles to
-- a number that gets silently stringified into garbage on the way.
-- Verify any model you add with /testmodel before relying on it.
-- ─────────────────────────────────────────────────────────────
-- `price` is what the crew pays OUT OF THE GANG BANK to unlock the entry
-- before they can place it. These are only the defaults — staff set the
-- real prices live in the admin tablet's Pricing tab, and those overrides
-- win. Set a price to 0 to make an unlock free the moment its tier lands.
Config.TierUnlocks = {
    Unknown = {
        { id = 'hq_sign',        kind = 'hq',     model = 'prop_laptop_01a',    label = 'Crew Laptop',    price = 0 },
        { id = 'gang_vault',     kind = 'vault',  model = 'prop_toolchest_05',  label = 'Crew Locker',    price = 15000 },
    },
    Local = {
        { id = 'local_crafting_bench', kind = 'bench', model = 'prop_tool_bench02', label = 'Crafting Bench', price = 25000 },
        { id = 'gang_garage',    kind = 'garage', model = 'prop_toolchest_04',  label = 'Garage Point',   price = 40000 },
        { id = 'gang_safe',      kind = 'safe',   model = 'p_v_43_safe_s',      label = 'Crew Safe',      price = 30000 },
    },
    Feared = {
        { id = 'contract_drop',  kind = 'task',   model = 'prop_box_ammo04a',   label = 'Contract Drop',  price = 20000 },
        { id = 'gate_barrier',   kind = 'prop',   model = 'prop_barrier_work05', label = 'Roadblock',     price = 5000 },
    },
    -- Nothing at the top two tiers out of the box. Decoration was cut on
    -- purpose: every unlock left here DOES something. Add your own the
    -- same way — `kind = 'prop'` is pure scenery and always safe.
    Notorious = {},
    Untouchable = {},
}

-- ─────────────────────────────────────────────────────────────
-- Placement rules
-- Where a gang is allowed to build. The HQ can go anywhere — it's the
-- crew's home and a brand-new gang holds no turf yet. Everything else has
-- to sit either inside a zone the gang holds, or close to its own HQ, so
-- a crew's property is always somewhere they can actually defend.
-- ─────────────────────────────────────────────────────────────
Config.Placement = {
    -- Turn this off to let gangs build literally anywhere.
    requireZoneOrHq = true,
    -- How far from the placed HQ still counts as "at base".
    hqBuildRadius = 60.0,
    -- How far the placing player may stand from the ghost prop. This is
    -- the server-side bound check on a client-reported position.
    maxPlaceDistance = 6.0,
}

-- ─────────────────────────────────────────────────────────────
-- Gang garage
-- Vehicles stored against the gang, not a person. Pulled out at the
-- placed Garage Point. Slot count scales with the garage upgrade + perks.
-- ─────────────────────────────────────────────────────────────
Config.Garage = {
    enabled = true,
    baseSlots = 4,
    spawnRadius = 12.0,    -- how far from the garage point a vehicle may be stored/taken
    -- Plate prefix for gang vehicles. Kept short so the generated plate
    -- still fits GTA's 8-character limit.
    platePrefix = 'XS',
    -- Hand the puller keys through whatever your server uses. Both common
    -- QBox/QBCore key resources are tried; anything unknown is a no-op and
    -- the vehicle simply spawns unlocked.
    giveKeys = true,
    -- The garage is somewhere the crew PARKS. There is no stock list of
    -- cars to hand out — members store vehicles they already have and
    -- pull them back out here.
    --
    -- Staff can still gift one from the admin tablet by typing a model
    -- name. Anything listed here just becomes a shortcut in that box:
    --
    --   { model = 'sultan', label = 'Sultan' },
    adminGrantModels = {},
}

-- ─────────────────────────────────────────────────────────────
-- Graffiti
-- Gang tagging. A gang's library is curated by STAFF — admins add art to
-- a gang from the admin tablet (catalogue entries or a custom image URL),
-- and members spray whatever their gang has been given. Members can also
-- compose styled text or draw freehand in the studio, which the server
-- stores as the gang's own art.
--
-- Custom images are loaded by URL inside the NUI and rendered in-world
-- through a DUI texture, so the URL has to be reachable from the client's
-- browser — a direct link to the image file, not a page that shows it.
-- ─────────────────────────────────────────────────────────────
Config.Graffiti = {
    enabled = true,
    -- How far a tag renders. Lower this if you put a lot of them out.
    renderDistance = 45.0,
    -- Max tags one gang may have standing at once. Spraying past the cap
    -- replaces that gang's oldest tag rather than refusing.
    maxPerGang = 25,
    -- Server-wide cap so the world can't fill up.
    maxTotal = 300,
    -- Seconds the spray animation takes.
    sprayDuration = 6,
    -- How far in front of the camera a wall counts as "aimed at".
    aimDistance = 6.0,
    -- The tagging animation. Swap the dict/clip for whatever your server
    -- streams; a dict that won't load just means no animation, never a
    -- stuck spray. Leave dict blank to skip the animation entirely.
    anim = {
        -- Tried in order; the first dictionary that streams is used. Put
        -- your preferred one at the top. If none of them load, spraying
        -- still works, it just has no animation and says so in the console.
        candidates = {
            { dict = 'switch@franklin@lamar_tagging_wall', clip = 'lamar_tagging_loop_lamar' },
            { dict = 'anim@amb@nightclub@peds@',           clip = 'rcmme_amanda1ig_2' },
            { dict = 'missheistfbi3b_ig7',                 clip = 'lift_fibagent_loop' },
            { dict = 'amb@world_human_bum_wash@male@high@base', clip = 'base' },
        },
        flag = 49,
        -- Prop held in the right hand while spraying. Blank for none.
        prop = 'prop_cs_spray_can',
        -- Paint coming out of the can.
        --
        -- GTA has no spray-paint particle, so this is a small puff tinted
        -- to the colour going on the wall. 'ent_sht_steam' reads as water
        -- up close — swap it for anything you like, or set enabled=false
        -- and rely on the animation alone.
        -- Off by default: a non-looped burst plays out its own lifetime,
        -- so the last puff always outlasts the progress bar by a beat,
        -- and nothing in the base game actually looks like paint.
        ptfx = {
            enabled = false,
            asset = 'core',
            name = 'ent_sht_steam',
            scale = 0.25,
            alpha = 0.65,
            intervalMs = 160,
        },
    },
    -- Needs the can item in inventory. Leave blank to require nothing.
    requiredItem = 'spraycan',
    consumeItem = true,
    -- Only allow spraying inside a zone the gang holds. Off by default —
    -- tagging rival turf is half the point.
    heldZonesOnly = false,
    -- Spraying over a rival gang's tag removes theirs. Pays the bigger
    -- Config.Rep.rewards.graffiti_covered reward.
    allowCovering = true,
    coverRadius = 2.5,
    -- Tags older than this are swept automatically (0 = never expire).
    expiryDays = 0,
    -- How far off the wall the tag sits, in metres. Too small and it
    -- z-fights or disappears into the geometry; too large and it floats.
    surfaceOffset = 0.05,
    -- Default plate size in metres, and the range members can scale to.
    defaultWidth = 2.4,
    defaultHeight = 1.6,
    minScale = 0.5,
    maxScale = 2.0,
    -- The stock catalogue every gang starts with. Admins assign extras
    -- per gang from the admin tablet. `art` is either a built-in studio
    -- preset id or a direct image URL.
    -- Empty on purpose. Issue art per crew from the admin tablet instead,
    -- where you can hand a gang its own images. Anything listed here is
    -- offered to every gang on the server:
    --
    --   { id = 'tag_classic', label = 'Classic Tag', art = 'preset:classic' },
    --
    -- `art` is a built-in studio preset (classic, bubble, stencil, drip)
    -- or a direct image URL.
    catalogue = {},
    -- Fonts offered in the studio's text mode.
    -- Every font here needs a matching class in web/tag.html, which is
    -- what actually paints the wall. Adding one means editing both.
    -- Every font here needs a matching class in web/tag.html, which is
    -- what actually paints the wall, and its family in that page's font
    -- link. tools/check-fonts is not a thing; the three are kept in step
    -- by hand, so add to all three or the tag falls back to a plain face.
    fonts = {
        { id = 'marker',    label = 'Marker',        css = "'Permanent Marker', cursive" },
        { id = 'spray',     label = 'Spray Can',     css = "'Rubik Spray Paint', cursive" },
        { id = 'drip',      label = 'Wet Paint',     css = "'Rubik Wet Paint', cursive" },
        { id = 'bubble',    label = 'Bubble',        css = "'Rubik Bubbles', cursive" },
        { id = 'hatch',     label = 'Marker Hatch',  css = "'Rubik Marker Hatch', cursive" },
        { id = 'burn',      label = 'Burned',        css = "'Rubik Burned', cursive" },
        { id = 'glitch',    label = 'Glitch',        css = "'Rubik Glitch', cursive" },
        { id = 'vinyl',     label = 'Vinyl',         css = "'Rubik Vinyl', cursive" },
        { id = 'rough',     label = 'Distressed',    css = "'Rubik Distressed', cursive" },
        { id = 'puddle',    label = 'Puddles',       css = "'Rubik Puddles', cursive" },
        { id = 'moon',      label = 'Moonrocks',     css = "'Rubik Moonrocks', cursive" },
        { id = 'beast',     label = 'Beastly',       css = "'Rubik Beastly', cursive" },
        { id = 'maze',      label = 'Maze',          css = "'Rubik Maze', cursive" },
        { id = 'pixels',    label = 'Pixels',        css = "'Rubik Pixels', cursive" },
        { id = 'scribble',  label = 'Scribble',      css = "'Rubik Scribble', cursive" },
        { id = 'dirt',      label = 'Dirt',          css = "'Rubik Dirt', cursive" },
        { id = 'iso',       label = 'Iso 3D',        css = "'Rubik Iso', cursive" },
        { id = 'storm',     label = 'Storm',         css = "'Rubik Storm', cursive" },
        { id = 'gothic',    label = 'Old English',   css = "'UnifrakturMaguntia', cursive" },
        { id = 'neon',      label = 'Neon Tube',     css = "'Monoton', cursive" },
        { id = 'horror',    label = 'Horror',        css = "'Creepster', cursive" },
        { id = 'gore',      label = 'Gore',          css = "'Nosifer', cursive" },
        { id = 'bones',     label = 'Bones',         css = "'Butcherman', cursive" },
        { id = 'metal',     label = 'Metal',         css = "'Metal Mania', cursive" },
        { id = 'wild',      label = 'Wildstyle',     css = "'Bungee Shade', cursive" },
        { id = 'slab',      label = 'Slab',          css = "'Bungee', cursive" },
        { id = 'hollow',    label = 'Hollow',        css = "'Bungee Outline', cursive" },
        { id = 'inline',    label = 'Inline',        css = "'Bungee Inline', cursive" },
        { id = 'block',     label = 'Block',         css = "'Archivo Black', sans-serif" },
        { id = 'stencil',   label = 'Stencil',       css = "'Oswald', sans-serif" },
        { id = 'heavy',     label = 'Heavy',         css = "'Anton', sans-serif" },
        { id = 'poster',    label = 'Poster',        css = "'Staatliches', cursive" },
        { id = 'fast',      label = 'Speed',         css = "'Faster One', cursive" },
        { id = 'loud',      label = 'Loud',          css = "'Bangers', cursive" },
        { id = 'fun',       label = 'Cartoon',       css = "'Luckiest Guy', cursive" },
        { id = 'chunk',     label = 'Chunky',        css = "'Sigmar One', cursive" },
        { id = 'script',    label = 'Script',        css = "'Lobster', cursive" },
        { id = 'brush',     label = 'Brush',         css = "'Shrikhand', cursive" },
        { id = 'hand',      label = 'Handwriting',   css = "'Caveat', cursive" },
        { id = 'thin',      label = 'Thin Marker',   css = "'Shadows Into Light', cursive" },
        { id = 'army',      label = 'Military',      css = "'Black Ops One', cursive" },
        { id = 'west',      label = 'Western',       css = "'Rye', cursive" },
    },
}

-- ─────────────────────────────────────────────────────────────
-- Raids & gang war
-- Two escalating things:
--   RAID  — a short strike on a rival's HQ. Mobilise, get bodies to their
--           HQ, hold it against them. Winner takes a cut of the loser's
--           treasury; optionally a zone too, if captureZoneOnWin is on.
--   WAR   — a declared, two-sided fight with a shared war meter fed by
--           kills between the two gangs. Winning opens the stash raid.
-- ─────────────────────────────────────────────────────────────
Config.War = {
    enabled = true,

    raid = {
        cost = 10000,               -- staged from the attacker's treasury
        prepSeconds = 120,          -- warning window before the raid goes live
        durationSeconds = 600,      -- how long the attackers have
        holdSeconds = 90,           -- seconds of uncontested presence at the HQ to win
        radius = 40.0,              -- how close to the defender HQ counts as "there"
        minAttackers = 2,
        minDefendersOnline = 1,     -- can't raid a gang with nobody online
        cooldownMinutes = 120,      -- per attacking gang
        immunityMinutes = 90,       -- defender can't be raided again this soon
        cashCutPct = 15,            -- % of the loser's treasury taken (before upgrades)
        cashCutMax = 250000,        -- hard ceiling on a single raid payout
        -- Off by default to match the influence model: turf doesn't move
        -- between crews on its own. Turn it on if you want a won raid to
        -- be the one exception that takes a block off someone.
        captureZoneOnWin = false,
    },

    war = {
        declareCost = 25000,
        durationMinutes = 60,
        scoreToWin = 15,            -- net kill lead needed to win outright
        killScore = 1,
        -- Killing the same person repeatedly stops scoring for this long.
        repeatKillCooldownSeconds = 120,
        cooldownMinutes = 180,
        -- The loser's safe becomes lootable for this long after a war.
        stashWindowMinutes = 15,
    },

    -- Stash raid: after a war win, the loser's placed Crew Safe is
    -- lootable. A compass arrow, blip and live distance guide the winner in.
    stash = {
        enabled = true,
        lootRadius = 3.0,
        lootSeconds = 12,
        -- What comes out. Cash is taken from the loser's treasury; items
        -- are pulled from the loser's actual vault stash, so there is
        -- something real to lose.
        cashPct = 20,
        cashMax = 150000,
        lootItems = true,
        maxItemStacks = 6,
    },
}

-- ─────────────────────────────────────────────────────────────
-- Gang medic
-- Unlocked by placing the Medic Station (Feared tier). Lets a member
-- patch up their own crew in the field instead of waiting on EMS.
-- ─────────────────────────────────────────────────────────────
Config.Medic = {
    enabled = true,
    -- Only members of the same gang can be treated.
    healCooldownSeconds = 180,     -- per medic
    reviveCooldownSeconds = 600,   -- per medic
    healAmount = 50,               -- HP restored
    reviveHealth = 130,            -- HP the revived player comes back on
    treatSeconds = 8,
    requiredItem = 'bandage',      -- leave blank to require nothing
    consumeItem = true,
    -- Reviving is the strong one, so by default the patient has to be at
    -- the station. Healing works anywhere.
    reviveNeedsStation = true,
    stationRadius = 25.0,

    -- ONE clinic the whole server shares, not a per-crew placeable. Every
    -- gang uses the same back alley.
    --
    -- coords = nil switches the station off: the prop and blip never
    -- spawn, and with reviveNeedsStation = true nobody can revive at all.
    station = {
        coords = vec3(2457.74, 4980.51, 45.81),
        heading = 0.0,
        model = 'prop_medstation_02',    -- '' for no prop at all
        label = 'Back-Alley Clinic',
        blip = {
            enabled = true,
            sprite = 61,
            color = 2,
            scale = 0.7,
            shortRange = true,
        },
    },
}

-- ─────────────────────────────────────────────────────────────
-- Field radial
-- A quick-action wheel for everything the crew does in the world. Every
-- entry is individually toggleable — turn off anything your server
-- already handles in a police or inventory script so the two don't fight.
--
-- `key` is the keybind. It registers through FiveM's keymapping, so
-- players can also rebind it themselves in Settings > Keybinds > FiveM.
-- ─────────────────────────────────────────────────────────────
Config.Radial = {
    enabled = true,
    key = 'F6',
    command = 'gangradial',
    -- Radial actions. Set enabled = false on anything that collides with
    -- another resource on your server.
    actions = {
        graffiti     = { enabled = true,  label = 'Spray Tag',     icon = 'fa-spray-can' },
        garage       = { enabled = true,  label = 'Gang Garage',   icon = 'fa-warehouse' },
        medic        = { enabled = true,  label = 'Treat Crew',    icon = 'fa-kit-medical' },
        revive       = { enabled = true,  label = 'Revive Crew',   icon = 'fa-heart-pulse' },
        capture      = { enabled = true,  label = 'Claim Turf',    icon = 'fa-flag' },
        cuff         = { enabled = true,  label = 'Cuff / Uncuff', icon = 'fa-handcuffs' },
        bag          = { enabled = true,  label = 'Bag Head',      icon = 'fa-mask' },
        trunk        = { enabled = true,  label = 'Put In Trunk',  icon = 'fa-car-rear' },
        carry        = { enabled = true,  label = 'Carry',         icon = 'fa-people-carry-box' },
        escort       = { enabled = true,  label = 'Escort',        icon = 'fa-person-walking' },
        hostage      = { enabled = true,  label = 'Take Hostage',  icon = 'fa-user-lock' },
        searchRob    = { enabled = true,  label = 'Search & Rob',  icon = 'fa-hand' },
        slashTyre    = { enabled = true,  label = 'Slash Tyre',    icon = 'fa-screwdriver' },
        tablet       = { enabled = true,  label = 'Open Tablet',   icon = 'fa-tablet-screen-button' },
    },
    -- Robbing: what a search turns up off another player.
    rob = {
        cashOnly = false,          -- true = only ever take cash, never items
        maxItemStacks = 3,
        requireHandsUp = true,     -- target must be cuffed or hands-up
    },
    -- Cuffing. Needs the item unless it is left blank.
    cuffItem = 'handcuffs',
    bagItem = '',
    -- Seconds the cuff/bag/carry animations take.
    actionSeconds = 3,

    -- Slashing a tyre. Blank the item to need nothing.
    slash = {
        item = 'weapon_knife',
        -- true removes one on use; a weapon should almost always be false.
        consume = false,
        seconds = 3,
        -- Knife in hand for the animation. Blank for none.
        prop = 'prop_w_me_knife_01',
        -- First dictionary that exists in your build is the one used.
        anims = {
            { dict = 'anim@gangops@facility@servers@bodysearch@', clip = 'player_search' },
            { dict = 'amb@medic@standing@kneel@base',             clip = 'base' },
            { dict = 'anim@heists@ornate_bank@grab_cash',          clip = 'grab' },
        },
    },
}

-- ─────────────────────────────────────────────────────────────
-- Solo test mode
-- Admin-toggled. Spawns hostile NPC defenders on captures and raids so
-- one person can exercise the whole invasion loop without a rival gang
-- online. Never on by default, and always announced in the UI while live.
-- ─────────────────────────────────────────────────────────────
Config.TestMode = {
    enabled = true,          -- whether admins may turn it on at all
    defenderCount = 3,
    defenderModel = 'g_m_y_lost_01',
    defenderWeapon = 'WEAPON_PISTOL',
    defenderAccuracy = 40,
    spawnRadius = 25.0,
    -- Test-mode defenders count as bodies on the defending side, so the
    -- influence bar behaves the way a real fight would.
    countAsDefenders = true,
}

-- ─────────────────────────────────────────────────────────────
-- Analytics
-- Street standing: every gang on the server ranked side by side.
-- ─────────────────────────────────────────────────────────────
Config.Analytics = {
    enabled = true,
    -- Weights used for the composite "street standing" score. Tune to
    -- whatever your server should actually reward.
    weights = {
        rep       = 1.0,
        territory = 500,     -- per zone held
        members   = 40,      -- per member
        treasury  = 0.01,    -- per dollar banked
        warWins   = 250,     -- per war won
    },
    -- How many gangs the standings table shows.
    limit = 15,
    -- Show rival treasuries to everyone, or only your own gang's.
    publicTreasury = false,
}

-- ─────────────────────────────────────────────────────────────
-- Contracts board
-- Gang-facing jobs. Same engine as the old task list, but presented as a
-- board with categories, a difficulty rating and a cash payout alongside
-- the rep. Every contract still validates server-side at each step.
-- ─────────────────────────────────────────────────────────────
Config.Contracts = {
    enabled = true,
    -- How many contracts sit on the board at once, and how often the
    -- selection rerolls.
    boardSize = 5,
    rotateMinutes = 45,
    -- Categories shown as filters in the UI.
    categories = {
        { id = 'hit',      label = 'Assassination', icon = 'fa-crosshairs' },
        { id = 'narcotic', label = 'Narcotics',     icon = 'fa-pills' },
        { id = 'transport', label = 'Transport',    icon = 'fa-truck' },
        { id = 'disposal', label = 'Disposal',      icon = 'fa-dumpster' },
        { id = 'kidnap',   label = 'Kidnapping',    icon = 'fa-user-lock' },
    },
}

-- ─────────────────────────────────────────────────────────────
-- Task ranks
-- Personal progression, separate from gang rep — independent of which
-- gang you're in, tracked in xs_task_stats. `xp` on a contract feeds this;
-- `reward` is the gang rep it pays, a completely separate number.
-- ─────────────────────────────────────────────────────────────
Config.TaskLevels = {
    { level = 1, xpNeeded = 0,    title = 'Rookie' },
    { level = 2, xpNeeded = 150,  title = 'Operative' },
    { level = 3, xpNeeded = 400,  title = 'Specialist' },
    { level = 4, xpNeeded = 800,  title = 'Enforcer' },
    { level = 5, xpNeeded = 1500, title = 'Veteran' },
}

Config.TaskAchievements = {
    { id = 'first_job', label = 'First Job', description = 'Complete your first contract', type = 'total_completed', value = 1 },
    { id = 'ten_jobs', label = 'Reliable', description = 'Complete 10 contracts', type = 'total_completed', value = 10 },
    { id = 'fifty_jobs', label = 'Workhorse', description = 'Complete 50 contracts', type = 'total_completed', value = 50 },
    { id = 'max_rank', label = 'Top Operative', description = 'Reach the max contract rank', type = 'level', value = 5 },
}

-- Co-op: invite a specific crew member to run a contract together.
-- Contracts flagged coopOnly never show in the solo list. The reward bonus
-- splits across the crew; XP is NOT split, everyone gets the full amount.
Config.TasksCoop = {
    enabled = true,
    maxCrewSize = 3,
    rewardBonusPct = 25,
}

-- ─────────────────────────────────────────────────────────────
-- Contracts
-- `category` maps to Config.Contracts.categories. `difficulty` is 1-5 and
-- is purely presentational. `cash` is paid on completion on top of rep.
--
-- type = 'delivery' (default): target the pickup item, then target a
--   delivery ped at the dropoff. Each step re-checks the player's real
--   position server-side at that moment. carryProp attaches a prop
--   between the two stages for flavour.
-- type = 'kill': server picks a random spawnPoints entry; the client
--   spawns an armed hostile there and reports back when it's dead. The
--   server only trusts that report after minKillSeconds.
-- type = 'escort': a friendly NPC spawns at `spawn` and follows you to
--   `destination` — fails if it dies en route.
-- type = 'heist': three sequential points — infiltrate (hold for
--   holdSeconds), grab (instant), escape (reach it inside the time limit).
-- type = 'courier': the full van loop — collect the van from a
--   quartermaster, drive it to the dropoff, open the boot to unload, hand
--   off to the ped, then bring the van home. `ambushChance` (0-100) rolls
--   once per job; on a hit, hostiles wait near the dropoff and you get a
--   warning the moment you're close enough to trigger them.
-- ─────────────────────────────────────────────────────────────
Config.Tasks = {
    {
        id = 'package_run',
        type = 'courier',
        category = 'transport',
        difficulty = 1,
        label = 'Package Run',
        minLevel = 1,
        vanModel = 'speedo',
        vanSpawns = {
            vec4(-38.8354, -1448.0388, 31.2414, 185.3257),
            vec4(-24.8434, -1225.5367, 29.0739, 91.4652),
            vec4(139.4083, -243.9028, 51.2600, 160.4696),
            vec4(-368.3868, -48.8293, 54.1642, 72.9749),
            vec4(-1139.8976, -353.9975, 37.4110, 354.7283),
        },
        dropoffs = {
            vec4(307.8727, 365.1582, 105.2617, 41.5321),
            vec4(978.0176, 10.3575, 81.0409, 145.9381),
            vec4(1134.0375, -1302.0050, 34.6867, 24.4539),
            vec4(-344.2141, -2438.3101, 5.9979, 309.7777),
            vec4(145.7043, -3185.3767, 5.8554, 159.0886),
        },
        radius = 6.0,
        reward = 35,
        cash = 1200,
        xp = 25,
        cooldownMinutes = 25,
        timeLimitSeconds = 600,
        ambushChance = 25,
        carryProp = 'prop_box_ammo04a',
        dropoffPedModel = 'g_m_y_lost_01',
        quartermasterModel = 'g_m_y_lost_01',
    },
    {
        id = 'briefcase_run',
        type = 'courier',
        category = 'transport',
        difficulty = 2,
        label = 'Briefcase Run',
        minLevel = 1,
        vanModel = 'speedo',
        vanSpawns = {
            vec4(-38.8354, -1448.0388, 31.2414, 185.3257),
            vec4(-24.8434, -1225.5367, 29.0739, 91.4652),
            vec4(139.4083, -243.9028, 51.2600, 160.4696),
            vec4(-368.3868, -48.8293, 54.1642, 72.9749),
            vec4(-1139.8976, -353.9975, 37.4110, 354.7283),
        },
        dropoffs = {
            vec4(307.8727, 365.1582, 105.2617, 41.5321),
            vec4(978.0176, 10.3575, 81.0409, 145.9381),
            vec4(1134.0375, -1302.0050, 34.6867, 24.4539),
            vec4(-344.2141, -2438.3101, 5.9979, 309.7777),
            vec4(145.7043, -3185.3767, 5.8554, 159.0886),
        },
        radius = 6.0,
        reward = 50,
        cash = 1800,
        xp = 35,
        cooldownMinutes = 30,
        timeLimitSeconds = 600,
        ambushChance = 40,
        carryProp = 'prop_attache_case_01',
        dropoffPedModel = 'g_m_y_lost_01',
        quartermasterModel = 'g_m_y_lost_01',
    },
    {
        id = 'hit_contract',
        type = 'kill',
        category = 'hit',
        difficulty = 3,
        label = 'Hit Contract',
        minLevel = 2,
        -- Placeholders — pick your own spots.
        spawnPoints = {
            vec3(425.1, -979.5, 30.7),
            vec3(-1037.2, -2737.8, 20.2),
            vec3(1698.9, 3242.2, 41.2),
        },
        pedModel = 'g_m_y_lost_01',
        weapon = 'WEAPON_PISTOL',
        reward = 40,
        cash = 2000,
        xp = 30,
        cooldownMinutes = 30,
        timeLimitSeconds = 600,
        minKillSeconds = 5,
    },
    {
        id = 'vip_escort',
        type = 'escort',
        category = 'transport',
        difficulty = 3,
        label = 'VIP Escort',
        minLevel = 2,
        -- Placeholders — pick your own spots.
        spawn = vec3(220.0, -800.0, 30.5),
        destination = vec3(-1100.0, -1500.0, 4.0),
        radius = 5.0,
        pedModel = 'g_m_y_lost_01',
        reward = 45,
        cash = 2200,
        xp = 35,
        cooldownMinutes = 30,
        timeLimitSeconds = 600,
    },
    {
        id = 'safehouse_job',
        type = 'heist',
        category = 'narcotic',
        difficulty = 4,
        label = 'Safehouse Job',
        minLevel = 3,
        -- Placeholders — pick your own spots.
        infiltrate = vec3(-200.0, -1300.0, 30.0),
        grab = vec3(-210.0, -1305.0, 30.0),
        escape = vec3(-600.0, -1100.0, 25.0),
        holdSeconds = 6,
        radius = 2.5,
        reward = 60,
        cash = 3500,
        xp = 45,
        cooldownMinutes = 40,
        timeLimitSeconds = 480,
    },
    {
        id = 'body_disposal',
        type = 'courier',
        category = 'disposal',
        difficulty = 3,
        label = 'Body Disposal',
        minLevel = 2,
        vanModel = 'speedo',
        vanSpawns = {
            vec4(-24.8434, -1225.5367, 29.0739, 91.4652),
            vec4(-1139.8976, -353.9975, 37.4110, 354.7283),
        },
        dropoffs = {
            vec4(-344.2141, -2438.3101, 5.9979, 309.7777),
            vec4(145.7043, -3185.3767, 5.8554, 159.0886),
        },
        radius = 6.0,
        reward = 55,
        cash = 2600,
        xp = 40,
        cooldownMinutes = 35,
        timeLimitSeconds = 600,
        ambushChance = 20,
        carryProp = 'prop_big_bag_01',
        dropoffPedModel = 'g_m_y_lost_01',
        quartermasterModel = 'g_m_y_lost_01',
    },
    {
        id = 'snatch_job',
        type = 'escort',
        category = 'kidnap',
        difficulty = 4,
        label = 'Snatch Job',
        minLevel = 3,
        -- Placeholders — pick your own spots.
        spawn = vec3(-1300.0, -1100.0, 5.0),
        destination = vec3(700.0, -1000.0, 22.0),
        radius = 5.0,
        pedModel = 'a_m_m_soucent_01',
        reward = 65,
        cash = 3000,
        xp = 45,
        cooldownMinutes = 40,
        timeLimitSeconds = 600,
    },
    {
        id = 'crew_hit',
        type = 'kill',
        category = 'hit',
        difficulty = 5,
        label = 'Crew Hit',
        minLevel = 1,
        coopOnly = true, -- never shows in the solo list
        spawnPoints = {
            vec3(-1037.2, -2737.8, 20.2),
        },
        pedModel = 'g_m_y_lost_01',
        weapon = 'WEAPON_PISTOL',
        reward = 70,
        cash = 4000,
        xp = 50,
        cooldownMinutes = 25,
        timeLimitSeconds = 600,
        minKillSeconds = 5,
    },
}

-- ─────────────────────────────────────────────────────────────
-- Treasury
-- No forced dues — every member can deposit whenever they want.
-- Withdrawing is gated by 'bank_withdraw' so one member can't drain it.
-- ─────────────────────────────────────────────────────────────
Config.Bank = {
    account = 'bank', -- which money account deposits/withdrawals use
    ledgerLimit = 25,  -- recent transactions kept on the Treasury tab
}

-- ─────────────────────────────────────────────────────────────
-- Vault / armory
-- Backed by an ox_inventory stash, namespaced per gang. It's a physical
-- container placed in the world — there is no remote "open from tablet".
-- The container's own model and label come from the `gang_vault` entry in
-- Config.TierUnlocks above; these are just the stash's base size, which
-- vault perks and the Vault Expansion upgrade grow from.
-- ─────────────────────────────────────────────────────────────
Config.Vault = {
    slots = 50,
    maxWeight = 100000,             -- grams

    -- The vault's prop grows with the Vault Expansion upgrade: a locker,
    -- a second locker, then a shipping container. Index 1 is the placed
    -- vault before any upgrade; after that it follows the upgrade level.
    -- Buying a level re-models whatever the crew already placed.
    --
    -- A model your server does not have prints a line naming it on spawn
    -- and the prop is skipped, so swapping one is a single edit here.
    levelModels = {
        'prop_toolchest_05',     -- level 0-1: a tall locker
        'prop_toolchest_01',     -- level 2: a bigger one
        'prop_container_01a',    -- level 3: a shipping container
    },
}

-- ─────────────────────────────────────────────────────────────
-- Crafting
-- Available at any placed bench. Higher gang tiers unlock more recipes at
-- that same bench. `tier` is which Config.Rep tier the gang needs.
-- Item names must match your ox_inventory items.lua exactly.
-- ─────────────────────────────────────────────────────────────
Config.Recipes = {
    {
        id = 'lockpick',
        label = 'Lockpick',
        tier = 'Local',
        inputs = { { item = 'metalscrap', count = 5 }, { item = 'plastic', count = 2 } },
        output = { item = 'lockpick', count = 1 },
        time = 5000,
    },
    {
        id = 'rope',
        label = 'Rope',
        tier = 'Local',
        inputs = { { item = 'plastic', count = 4 } },
        output = { item = 'rope', count = 1 },
        time = 4000,
    },
    {
        id = 'spraycan',
        label = 'Spray Can',
        tier = 'Local',
        inputs = { { item = 'plastic', count = 2 }, { item = 'metalscrap', count = 2 } },
        output = { item = 'spraycan', count = 2 },
        time = 4000,
    },
    {
        id = 'advanced_lockpick',
        label = 'Advanced Lockpick',
        tier = 'Notorious',
        inputs = { { item = 'metalscrap', count = 8 }, { item = 'plastic', count = 4 } },
        output = { item = 'lockpick', count = 3 },
        time = 7000,
    },
}

-- ─────────────────────────────────────────────────────────────
-- Drug selling
-- /selldrug — works anywhere, not just gang territory. The client checks
-- for a nearby NPC; the server validates the item count and cooldown and
-- pays out. Names just need to match your items.lua.
-- ─────────────────────────────────────────────────────────────
Config.DrugSelling = {
    enabled = true,
    command = 'selldrug',
    sellRadius = 4.0,         -- need an NPC ped within this many metres
    cooldownSeconds = 30,     -- per player
    account = 'cash',
    items = {
        { item = 'weed_brick', label = 'Weed Brick', price = 150, rep = 8 },
        { item = 'coke_brick', label = 'Cocaine Brick', price = 280, rep = 12 },
        { item = 'meth_brick', label = 'Meth Brick', price = 220, rep = 10 },
    },
}

-- ─────────────────────────────────────────────────────────────
-- Dealer
-- On-demand, not placed: any member hits "Call Dealer" on the tablet.
-- One call at a time server-wide. The ped spawns at a random spawnPoints
-- entry and despawns after timeoutMinutes if nobody reaches it. Stock
-- rotates on rotateMinutes with a randomised price per pool entry.
-- Empty by default — add pool entries to enable it.
-- ─────────────────────────────────────────────────────────────
Config.Dealer = {
    cooldownHours = 6,
    timeoutMinutes = 10,
    rotateMinutes = 60,
    stockSize = 4,
    account = 'cash',
    pedModel = 'g_m_y_lost_01',
    spawnPoints = {
        vec4(328.1793, -1582.1826, 32.7972, 139.3918),
        vec4(-174.5912, -726.4565, 30.4540, 343.6068),
        vec4(-1686.6917, -266.8215, 51.8833, 2.8311),
        vec4(-1312.9951, 326.1961, 65.4932, 297.0952),
        vec4(314.5848, 2859.3018, 43.5845, 309.9282),
    },
    pool = {
        -- { item = 'weapon_pistol', label = 'Pistol', priceMin = 2000, priceMax = 3500 },
        -- { item = 'weed_brick', label = 'Weed Brick', priceMin = 200, priceMax = 400 },
    },
}

-- How long since a member's last tablet open before the roster flags them
-- as inactive (purely visual — doesn't kick or affect anything mechanical).
Config.GangInactivityDays = 7
