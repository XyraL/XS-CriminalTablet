-- ─────────────────────────────────────────────────────────────
-- Gang medic. A member can patch up their own crew in the field instead
-- of waiting on EMS.
--
-- Healing works anywhere. Reviving is the strong one, so by default the
-- patient has to be at the clinic — one fixed spot every crew shares,
-- set in Config.Medic.station, rather than something a gang places.
-- ─────────────────────────────────────────────────────────────
Medic = {}

local cooldowns = {}   -- [citizenid] = { heal = ms, revive = ms }

local function now() return os.time() * 1000 end

local function cdOf(cid)
    cooldowns[cid] = cooldowns[cid] or { heal = 0, revive = 0 }
    return cooldowns[cid]
end

-- The one clinic, or nil when the server has not set one.
function Medic.StationCoords()
    local st = Config.Medic.station
    if not st or not st.coords then return nil end
    return st.coords
end

function Medic.HasStation()
    return Medic.StationCoords() ~= nil
end

function Medic.Status(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return { unlocked = false } end
    local cid = Framework.GetCitizenId(src)
    local cd = cdOf(cid)
    local station = Medic.StationCoords()
    return {
        enabled = Config.Medic.enabled,
        unlocked = station ~= nil,
        station = station and { x = station.x, y = station.y, z = station.z } or nil,
        healReadyAt = cd.heal,
        reviveReadyAt = cd.revive,
        reviveNeedsStation = Config.Medic.reviveNeedsStation,
        stationRadius = Config.Medic.stationRadius,
        requiredItem = Config.Medic.requiredItem,
        now = now(),
    }
end

-- Shared gating for both actions.
local function validate(src, targetSrc, kind)
    if not Config.Medic.enabled then return false, 'the medic system is off' end

    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    targetSrc = tonumber(targetSrc)
    if not targetSrc then return false, 'no patient' end

    local targetCid = Framework.GetCitizenId(targetSrc)
    if not targetCid then return false, 'patient is offline' end

    local targetGang = Gangs.GetByCitizen(targetCid)
    if not targetGang or targetGang.id ~= gang.id then return false, 'you can only treat your own crew' end

    local medicPed = GetPlayerPed(src)
    local patientPed = GetPlayerPed(targetSrc)
    if #(GetEntityCoords(medicPed) - GetEntityCoords(patientPed)) > 4.0 then
        return false, 'get closer to them'
    end

    local cid = Framework.GetCitizenId(src)
    local cd = cdOf(cid)
    if (cd[kind] or 0) > now() then
        return false, ('give it %ds'):format(math.ceil((cd[kind] - now()) / 1000))
    end

    if Config.Medic.requiredItem and Config.Medic.requiredItem ~= '' then
        local count = exports.ox_inventory:GetItemCount(src, Config.Medic.requiredItem)
        if (count or 0) < 1 then return false, ('you need a %s'):format(Config.Medic.requiredItem) end
    end

    if kind == 'revive' and Config.Medic.reviveNeedsStation then
        local station = Medic.StationCoords()
        if not station then return false, 'this server has no clinic set up' end
        if #(GetEntityCoords(patientPed) - station) > Config.Medic.stationRadius then
            return false, 'get them to the clinic for a revive'
        end
    end

    return true, nil, gang, targetCid
end

local function consume(src)
    if Config.Medic.requiredItem and Config.Medic.requiredItem ~= '' and Config.Medic.consumeItem then
        exports.ox_inventory:RemoveItem(src, Config.Medic.requiredItem, 1)
    end
end

function Medic.Heal(src, targetSrc)
    local ok, err, gang = validate(src, targetSrc, 'heal')
    if not ok then return false, err end

    consume(src)
    cdOf(Framework.GetCitizenId(src)).heal = now() + Config.Medic.healCooldownSeconds * 1000

    TriggerClientEvent('XS-CriminalTablet:client:medicHeal', tonumber(targetSrc), Config.Medic.healAmount)
    Framework.Notify(tonumber(targetSrc), ('%s patched you up.'):format(Framework.GetName(src) or 'A crew medic'), 'success')
    Gangs.Log(gang.id, ('%s treated %s'):format(
        Framework.GetName(src) or 'Someone', Framework.GetName(tonumber(targetSrc)) or 'a member'), 'medic')
    return true
end

function Medic.Revive(src, targetSrc)
    local ok, err, gang = validate(src, targetSrc, 'revive')
    if not ok then return false, err end

    consume(src)
    cdOf(Framework.GetCitizenId(src)).revive = now() + Config.Medic.reviveCooldownSeconds * 1000

    TriggerClientEvent('XS-CriminalTablet:client:medicRevive', tonumber(targetSrc), Config.Medic.reviveHealth)
    Framework.Notify(tonumber(targetSrc), ('%s brought you back.'):format(Framework.GetName(src) or 'A crew medic'), 'success')
    Gangs.Log(gang.id, ('%s revived %s'):format(
        Framework.GetName(src) or 'Someone', Framework.GetName(tonumber(targetSrc)) or 'a member'), 'medic')
    return true
end

lib.callback.register('XS-CriminalTablet:medic:getStatus', function(src)
    return Medic.Status(src)
end)

lib.callback.register('XS-CriminalTablet:medic:heal', function(src, targetSrc)
    local ok, err = Medic.Heal(src, targetSrc)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:medic:revive', function(src, targetSrc)
    local ok, err = Medic.Revive(src, targetSrc)
    return { ok = ok, error = err }
end)
