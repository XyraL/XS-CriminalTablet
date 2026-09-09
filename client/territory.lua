-- ─────────────────────────────────────────────────────────────
-- Territory client: draws zone blips for whatever the admin has
-- assigned. There is no in-world capture — zones only change via the
-- admin tablet. Placed bench/ped/vault objects live in client/placeables.lua.
-- ─────────────────────────────────────────────────────────────
local blips = {}
Territories = {} -- shared read-only snapshot for placeables.lua

local lastSignature = nil

local function tierIndex(tierName)
    for i, t in ipairs(Config.Notoriety.tiers) do
        if t.name == tierName then return i end
    end
    return 1
end

-- Bigger tier = bigger zone, purely visual (the radius blip circle) —
-- capped at Config.ZoneRadiusMaxTier so it doesn't keep growing forever.
local maxGrowthIdx = tierIndex(Config.ZoneRadiusMaxTier) - 1
local function zoneRadiusFor(holderTier)
    if not holderTier then return Config.ZoneRadius end
    local steps = math.min(tierIndex(holderTier) - 1, maxGrowthIdx)
    return Config.ZoneRadius + steps * Config.ZoneRadiusGrowthPerTier
end

local function refreshBlips(list)
    list = list or {}
    local sig = {}
    for _, t in ipairs(list) do
        sig[#sig + 1] = ('%s:%s:%s:%.1f:%.1f:%.1f:%s:%s'):format(
            t.zone, t.holderId or '', t.holderTier or '', t.coords.x, t.coords.y, t.coords.z, t.label, t.color or 0)
    end
    sig = table.concat(sig, '|')
    Territories = list
    if sig == lastSignature then return end
    lastSignature = sig

    for _, b in pairs(blips) do RemoveBlip(b) end
    blips = {}
    for _, t in ipairs(list) do
        local blip = AddBlipForRadius(t.coords.x, t.coords.y, t.coords.z, zoneRadiusFor(t.holderTier))
        SetBlipColour(blip, t.color or 0)
        SetBlipAlpha(blip, 110)
        blips[#blips + 1] = blip
    end

    TriggerEvent('XS-CriminalTablet:client:territoriesChanged', list)
end

RegisterNetEvent('XS-CriminalTablet:client:territoryUpdate', refreshBlips)

CreateThread(function()
    Wait(1500)
    local list = lib.callback.await('XS-CriminalTablet:territory:getAll', false)
    refreshBlips(list)
end)
