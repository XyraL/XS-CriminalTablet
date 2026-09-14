-- ─────────────────────────────────────────────────────────────
-- Zone influence.
--
-- A zone is not a flag that flips. Every gang standing in one builds a
-- SHARE of that block, and those shares are what the map and the tablet
-- show: "Ballas 68% · Vagos 22%". A rival pushing into your turf is a
-- visible percentage, not a countdown to losing it.
--
-- There are no neutral zones and nothing here ever moves turf. Staff draw a
-- zone FOR a crew and it stays theirs. A rival standing on it tops out at
-- Config.Territory.rivalInfluenceCap and the map simply shows they are all
-- over that block.
--
-- The server is the only thing that decides who is standing where: every
-- tick it reads each connected player's real ped position rather than
-- trusting a client to say "I'm in the zone".
-- ─────────────────────────────────────────────────────────────
Capture = {}

local influence = {}   -- [zone] = { [gangId] = 0..100 }
local alerted = {}     -- [zone..':'..gangId] = true, so the holder is warned once
local dirty = {}       -- [zone] = true, rows needing a write on the next flush

local function now() return os.time() * 1000 end

local function tierIndex(name)
    for i, t in ipairs(Config.Rep.tiers) do
        if t.name == name then return i end
    end
    return 1
end
local minTierIdx = tierIndex(Config.Territory.minTierToContest)

-- ── persistence ─────────────────────────────────────────────
local function loadInfluence()
    influence = {}
    for _, row in ipairs(MySQL.query.await('SELECT zone, gang_id, influence FROM xs_territory_influence') or {}) do
        influence[row.zone] = influence[row.zone] or {}
        influence[row.zone][row.gang_id] = row.influence or 0
    end
end

local function sharesOf(zoneKey)
    influence[zoneKey] = influence[zoneKey] or {}
    return influence[zoneKey]
end

-- Batched rather than written every tick — influence moves constantly
-- while anyone is standing in a zone, and a write per gang per second
-- would be pointless load.
local function flush()
    for zoneKey in pairs(dirty) do
        local shares = sharesOf(zoneKey)
        for gangId, pct in pairs(shares) do
            if pct <= 0.05 then
                MySQL.update('DELETE FROM xs_territory_influence WHERE zone = ? AND gang_id = ?', { zoneKey, gangId })
                shares[gangId] = nil
            else
                MySQL.query('INSERT INTO xs_territory_influence (zone, gang_id, influence) VALUES (?, ?, ?) ' ..
                    'ON DUPLICATE KEY UPDATE influence = ?', { zoneKey, gangId, pct, pct })
            end
        end
    end
    dirty = {}
end

-- ── reads ───────────────────────────────────────────────────
-- Every gang with a stake in a zone, biggest first, shaped for the UI.
function Capture.StateOf(zoneKey)
    local shares = influence[zoneKey]
    if not shares then return nil end

    local list = {}
    for gangId, pct in pairs(shares) do
        if pct > 0.5 then
            local gang = Gangs.Get(gangId)
            list[#list + 1] = {
                gangId = gangId,
                gangLabel = gang and gang.label or '?',
                gangColor = gang and gang.color or '#6b7280',
                influence = math.floor(pct + 0.5),
            }
        end
    end
    if #list == 0 then return nil end

    table.sort(list, function(a, b) return a.influence > b.influence end)
    return list
end

function Capture.Snapshot()
    local out = {}
    for zoneKey in pairs(influence) do
        local state = Capture.StateOf(zoneKey)
        if state then out[zoneKey] = state end
    end
    return out
end

function Capture.InfluenceFor(zoneKey, gangId)
    local shares = influence[zoneKey]
    return shares and shares[gangId] or 0
end

function Capture.Abort(zoneKey)
    influence[zoneKey] = nil
    MySQL.update('DELETE FROM xs_territory_influence WHERE zone = ?', { zoneKey })
end

-- Wipe a disbanded gang's stake everywhere.
function Capture.ClearGang(gangId)
    for _, shares in pairs(influence) do shares[gangId] = nil end
    MySQL.update('DELETE FROM xs_territory_influence WHERE gang_id = ?', { gangId })
end

-- ── eligibility ─────────────────────────────────────────────
-- Why a gang can't push influence here right now (nil = it can).
function Capture.BlockedReason(gang, zoneKey, z)
    if not z then return 'unknown zone' end
    if not z.gangId then return 'staff have not assigned this block to anyone yet' end
    if not z.capturable then return 'this block is locked by staff' end
    if z.gangId == gang.id then return nil end   -- holders can always shore up their own turf
    if tierIndex(Rep.Tier(gang.notoriety)) < minTierIdx then
        return ('your crew has to reach %s first'):format(Config.Territory.minTierToContest)
    end
    return nil
end

-- ── survey ──────────────────────────────────────────────────
local function surveyZones()
    local occupancy = {}
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 and GetEntityHealth(ped) > 0 then
            local key = Territory.ZoneAt(GetEntityCoords(ped))
            if key then
                local gang = Gangs.GetBySource(src)
                if gang then
                    occupancy[key] = occupancy[key] or {}
                    occupancy[key][gang.id] = (occupancy[key][gang.id] or 0) + 1
                end
            end
        end
    end
    return occupancy
end

local function alertHolder(zoneKey, z, gang)
    if not Config.Territory.alertOnContest or not z.gangId then return end
    local key = zoneKey .. ':' .. gang.id
    if alerted[key] then return end
    alerted[key] = true

    Gangs.NotifyGang(z.gangId, ('%s is working %s — get down there.'):format(gang.label, z.label), 'error')
    Discord.Send('war', 'Turf contested',
        ('%s is building influence on %s (held by %s)'):format(
            gang.label, z.label, Gangs.Get(z.gangId) and Gangs.Get(z.gangId).label or '?'),
        Discord.Color.warn)
end

-- ── tick ────────────────────────────────────────────────────
local tickSeconds = Config.Territory.tickMs / 1000
local baseStep = 100.0 * tickSeconds / Config.Territory.influenceSeconds
local decayStep = (Config.Territory.influenceDecayPerMinute or 0) * (tickSeconds / 60)

-- Gaining share has to come out of somewhere: first the unclaimed slack,
-- then proportionally off whoever else holds a stake. That keeps the
-- total at or under 100 without any one gang's number jumping around.
local function applyGain(shares, gangId, gain, ceiling)
    local current = shares[gangId] or 0
    local target = math.min(ceiling, current + gain)
    local actual = target - current
    if actual <= 0 then return false end

    local others = 0
    for id, pct in pairs(shares) do
        if id ~= gangId then others = others + pct end
    end
    local slack = math.max(0, 100 - current - others)
    local fromOthers = math.max(0, actual - slack)

    if fromOthers > 0 and others > 0 then
        local scale = math.max(0, (others - fromOthers) / others)
        for id, pct in pairs(shares) do
            if id ~= gangId then shares[id] = pct * scale end
        end
    end

    shares[gangId] = target
    return true
end

local function tick()
    local occupancy = surveyZones()
    local changed = false

    for zoneKey, z in pairs(Territory.All()) do
        local counts = occupancy[zoneKey] or {}
        local shares = sharesOf(zoneKey)
        local anyone = next(counts) ~= nil

        -- Test-mode NPCs stand in for a defending crew that isn't online.
        local npcDefenders = 0
        if TestMode and TestMode.IsActive(zoneKey) and Config.TestMode.countAsDefenders then
            npcDefenders = TestMode.DefenderCount(zoneKey)
        end

        if anyone then
            for gangId, bodies in pairs(counts) do
                local gang = Gangs.Get(gangId)
                local blocked = gang and Capture.BlockedReason(gang, zoneKey, z) or 'unknown gang'

                if gang and not blocked and bodies >= Config.Territory.minPresence then
                    local isHolder = z.gangId == gangId
                    local mods = Gangs.Modifiers(gangId)

                    local power = (1 + (bodies - 1) * Config.Territory.perExtraMember)
                        * (1 + mods.captureSpeedPct / 100)
                    if isHolder then
                        power = power * Config.Territory.holderWeight * (1 + mods.defenceWeightPct / 100)
                    end

                    -- Whoever holds the block pushes back: a rival's gain is
                    -- reduced by the bodies (and NPCs) defending it.
                    if not isHolder then
                        local defenders = (z.gangId and counts[z.gangId] or 0) + npcDefenders
                        power = power - defenders * Config.Territory.holderWeight
                    end

                    if power > 0 then
                        -- The holder can always shore its own block back up
                        -- to 100; a rival is hard-capped. Turf never changes
                        -- hands from this — only staff move a zone.
                        local ceiling = isHolder and 100 or Config.Territory.rivalInfluenceCap

                        if applyGain(shares, gangId, baseStep * power, ceiling) then
                            changed = true
                            dirty[zoneKey] = true
                            if not isHolder then alertHolder(zoneKey, z, gang) end
                        end
                    end
                end
            end
        elseif decayStep > 0 then
            -- Nobody in the zone: everyone's stake bleeds, except the
            -- holder's, which is what "holding" means.
            for gangId, pct in pairs(shares) do
                if gangId ~= z.gangId and pct > 0 then
                    shares[gangId] = math.max(0, pct - decayStep)
                    changed = true
                    dirty[zoneKey] = true
                    if shares[gangId] <= 0 then alerted[zoneKey .. ':' .. gangId] = nil end
                end
            end
        end
    end

    if changed then
        TriggerClientEvent('XS-CriminalTablet:client:captureUpdate', -1, Capture.Snapshot())
    end
end

-- ── player-facing actions ───────────────────────────────────
-- The tick does the actual work; this is the eligibility gate plus the
-- "your crew is on it" shout.
function Capture.Start(src, zoneKey)
    if not Gangs.HasPerm(src, 'capture_territory') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local z = Territory.GetZone(zoneKey)
    if not z then return false, 'unknown zone' end

    local blocked = Capture.BlockedReason(gang, zoneKey, z)
    if blocked then return false, blocked end

    if not Territory.ZoneContains(z, GetEntityCoords(GetPlayerPed(src))) then
        return false, 'you have to actually be standing in it'
    end

    if z.gangId ~= gang.id then
        Gangs.Log(gang.id, ('%s started working %s'):format(Framework.GetName(src) or 'Someone', z.label), 'war')
        return true, nil, ('You can push your crew to %d%% here — this block still belongs to %s.')
            :format(Config.Territory.rivalInfluenceCap, Gangs.Get(z.gangId) and Gangs.Get(z.gangId).label or 'them')
    end

    Gangs.Log(gang.id, ('%s is shoring up %s'):format(Framework.GetName(src) or 'Someone', z.label), 'war')
    return true
end

-- ── lifecycle ───────────────────────────────────────────────
CreateThread(function()
    Wait(3500)
    loadInfluence()

    while true do
        Wait(Config.Territory.tickMs)
        local ok, err = pcall(tick)
        if not ok and Config.Debug then
            print(('^1[XS-CriminalTablet]^0 influence tick error: %s'):format(err))
        end
    end
end)

CreateThread(function()
    Wait(8000)
    while true do
        Wait(15000)
        if next(dirty) then pcall(flush) end
    end
end)

Capture._flush = flush

-- ── callbacks ───────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:capture:start', function(src, zoneKey)
    local ok, err, note = Capture.Start(src, zoneKey)
    return { ok = ok, error = err, note = note }
end)

lib.callback.register('XS-CriminalTablet:capture:getState', function()
    return Capture.Snapshot()
end)

-- Which zone the caller is standing in right now, and what their crew can
-- do about it — drives the radial's "Claim Turf" entry and the turf card.
lib.callback.register('XS-CriminalTablet:capture:whereAmI', function(src)
    local key, z = Territory.ZoneAt(GetEntityCoords(GetPlayerPed(src)))
    if not key then return { inZone = false } end

    local gang = Gangs.GetBySource(src)
    local holder = z.gangId and Gangs.Get(z.gangId)
    local mine = gang and z.gangId == gang.id or false

    return {
        inZone = true,
        zone = key,
        label = z.label,
        holder = holder and holder.label or nil,
        mine = mine,
        blocked = gang and Capture.BlockedReason(gang, key, z) or 'you are not in a gang',
        influence = Capture.StateOf(key),
        myInfluence = gang and math.floor(Capture.InfluenceFor(key, gang.id) + 0.5) or 0,
        -- A rival can never take this block by standing on it, so say so
        -- rather than letting someone grind toward a flip that never comes.
        -- Turf never changes hands from standing on it, so the UI shows a
        -- ceiling instead of a claim target.
        cap = mine and 100 or Config.Territory.rivalInfluenceCap,
    }
end)
