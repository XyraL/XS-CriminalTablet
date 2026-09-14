-- ─────────────────────────────────────────────────────────────
-- Solo test mode. Admin-toggled: spawns hostile NPC defenders so one
-- person can exercise the whole influence/raid loop without a rival gang
-- online.
--
-- Never on by default, always announced in the UI while it's live, and
-- the NPCs count as real bodies on the defending side — otherwise it
-- wouldn't be testing the same code path players actually hit.
-- ─────────────────────────────────────────────────────────────
TestMode = {}

local zoneTests = {}   -- [zone]  = { count, by }
local warTests = {}    -- [warId] = { count, by }

function TestMode.IsActive(zoneKey) return zoneTests[zoneKey] ~= nil end
function TestMode.DefenderCount(zoneKey)
    local t = zoneTests[zoneKey]
    return t and t.count or 0
end
function TestMode.WarDefenderCount(warId)
    local t = warTests[warId]
    return t and t.count or 0
end

-- Everything currently running, for the admin tablet and the "TEST MODE"
-- banner the tablet shows every player while it's on.
function TestMode.Snapshot()
    local zones, wars = {}, {}
    for zoneKey, t in pairs(zoneTests) do
        local z = Territory.GetZone(zoneKey)
        zones[#zones + 1] = { zone = zoneKey, label = z and z.label or zoneKey, count = t.count, by = t.by }
    end
    for warId, t in pairs(warTests) do
        wars[#wars + 1] = { warId = warId, count = t.count, by = t.by }
    end
    return { zones = zones, wars = wars, enabled = Config.TestMode.enabled }
end

local function broadcast()
    TriggerClientEvent('XS-CriminalTablet:client:testModeUpdate', -1, TestMode.Snapshot())
end

-- ── zones ───────────────────────────────────────────────────
function TestMode.StartZone(src, zoneKey)
    if not Config.TestMode.enabled then return false, 'test mode is disabled in config' end
    local z = Territory.GetZone(zoneKey)
    if not z then return false, 'unknown zone' end
    if zoneTests[zoneKey] then return false, 'already running there' end
    if not z.coords then return false, 'that zone has no position yet' end

    zoneTests[zoneKey] = { count = Config.TestMode.defenderCount, by = Framework.GetName(src) or 'staff' }
    TriggerClientEvent('XS-CriminalTablet:client:testModeSpawn', -1, {
        scope = 'zone',
        key = zoneKey,
        coords = { x = z.coords.x, y = z.coords.y, z = z.coords.z },
        count = Config.TestMode.defenderCount,
        model = Config.TestMode.defenderModel,
        weapon = Config.TestMode.defenderWeapon,
        accuracy = Config.TestMode.defenderAccuracy,
        radius = Config.TestMode.spawnRadius,
    })
    broadcast()
    return true
end

function TestMode.StopZone(zoneKey)
    if not zoneTests[zoneKey] then return false, 'not running' end
    zoneTests[zoneKey] = nil
    TriggerClientEvent('XS-CriminalTablet:client:testModeDespawn', -1, { scope = 'zone', key = zoneKey })
    broadcast()
    return true
end

-- ── raids ───────────────────────────────────────────────────
-- Called by war.lua when a raid goes live, so a solo attacker still meets
-- resistance at the HQ.
function TestMode.StartWar(state)
    if not Config.TestMode.enabled then return end
    if not state.autoTest then return end
    if not state.targetCoords then return end

    warTests[state.id] = { count = Config.TestMode.defenderCount, by = 'auto' }
    TriggerClientEvent('XS-CriminalTablet:client:testModeSpawn', -1, {
        scope = 'war',
        key = state.id,
        coords = { x = state.targetCoords.x, y = state.targetCoords.y, z = state.targetCoords.z },
        count = Config.TestMode.defenderCount,
        model = Config.TestMode.defenderModel,
        weapon = Config.TestMode.defenderWeapon,
        accuracy = Config.TestMode.defenderAccuracy,
        radius = Config.TestMode.spawnRadius,
    })
    broadcast()
end

function TestMode.StopWar(warId)
    if not warTests[warId] then return end
    warTests[warId] = nil
    TriggerClientEvent('XS-CriminalTablet:client:testModeDespawn', -1, { scope = 'war', key = warId })
    broadcast()
end

-- Staff arm the NEXT raid a gang launches to come with NPC defenders.
local armedGangs = {}
function TestMode.ArmGang(gangId, on)
    armedGangs[tonumber(gangId)] = on and true or nil
    return true
end
function TestMode.IsArmed(gangId)
    return armedGangs[gangId] == true
end

function TestMode.StopAll()
    for zoneKey in pairs(zoneTests) do TestMode.StopZone(zoneKey) end
    for warId in pairs(warTests) do TestMode.StopWar(warId) end
    armedGangs = {}
    return true
end

-- A client reporting its test NPCs are dead drops the defender count so
-- the influence bar starts moving again once they've been cleared.
RegisterNetEvent('XS-CriminalTablet:server:testModeCleared', function(scope, key)
    if scope == 'zone' and zoneTests[key] then
        zoneTests[key].count = 0
    elseif scope == 'war' and warTests[tonumber(key)] then
        warTests[tonumber(key)].count = 0
    end
    broadcast()
end)

lib.callback.register('XS-CriminalTablet:testmode:getState', function()
    return TestMode.Snapshot()
end)
