-- ─────────────────────────────────────────────────────────────
-- Placeables: everything a gang builds in the world — HQ, vault, safe,
-- garage point, medic station, benches, contract drops and decoration.
--
-- One row per (gang, kind, unlock_id); re-placing moves it rather than
-- stacking duplicates. Position is client-reported (it's a placement
-- preview, not the player's own feet), so it gets bound-checked against
-- the player's actual position server-side.
-- ─────────────────────────────────────────────────────────────
Placeables = {}

local rows = {}
local byGangKind = {}

local function key(kind, unlockId) return kind .. ':' .. unlockId end

-- Crew Contracts is bought, never placed, even from an older config.lua.
local function isPlaceable(def)
    return def ~= nil and def.placeable ~= false and def.kind ~= 'task' and def.kind ~= 'medic'
end
Placeables.IsPlaceable = isPlaceable

-- Lockers placed before the crate models keep their upgrade level.
local OLD_VAULT_MODELS = { prop_toolchest_05 = 1, prop_toolchest_01 = 2 }

local function loadAll()
    local all = MySQL.query.await('SELECT * FROM xs_gang_placements') or {}
    rows = {}
    byGangKind = {}
    for _, r in ipairs(all) do
        -- A model changed in config.lua reaches props that are already
        -- placed. The vault's model follows its upgrade level instead.
        local def = Placeables.FindUnlockDef and Placeables.FindUnlockDef(r.unlock_id)
        local model = r.kind ~= 'vault' and def and def.model
        if r.kind == 'vault' and OLD_VAULT_MODELS[r.model] then
            model = (Config.Vault.levelModels or {})[OLD_VAULT_MODELS[r.model]]
        end
        if model and model ~= r.model then
            r.model = model
            MySQL.update('UPDATE xs_gang_placements SET model = ? WHERE id = ?', { model, r.id })
        end
        if r.kind ~= 'safe' and r.kind ~= 'task' and r.kind ~= 'medic' and not (def and not isPlaceable(def)) then
            rows[#rows + 1] = r
            byGangKind[r.gang_id] = byGangKind[r.gang_id] or {}
            byGangKind[r.gang_id][key(r.kind, r.unlock_id)] = r
        end
    end
end

-- The Crew Safe is gone (the Crew Locker does its job) and Crew Contracts
-- is no longer placed. Crews that bought the safe get what they paid back.
local function retireOld()
    for _, r in ipairs(MySQL.query.await("SELECT gang_id, paid FROM xs_gang_unlocks WHERE unlock_id = 'gang_safe'") or {}) do
        local paid = math.floor(tonumber(r.paid) or 0)
        if paid > 0 then
            MySQL.update.await('UPDATE xs_gangs SET bank = bank + ? WHERE id = ?', { paid, r.gang_id })
            MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
                { r.gang_id, '', 'Crew Safe refunded', 'refund', paid })
            local g = Gangs.Get(r.gang_id)
            if g then g.bank = (g.bank or 0) + paid end
        end
        print(('^3[XS-CriminalTablet]^0 Crew Safe retired for gang #%s, $%d refunded'):format(r.gang_id, paid))
    end
    MySQL.update.await("DELETE FROM xs_gang_unlocks WHERE unlock_id = 'gang_safe'")
    MySQL.update.await("DELETE FROM xs_gang_placements WHERE kind = 'safe'")
    MySQL.update.await("DELETE FROM xs_gang_placements WHERE kind = 'task'")
    MySQL.update.await("DELETE FROM xs_gang_placements WHERE kind = 'medic'")
end

function Placeables.GetAll() return rows end

-- First placement of a given kind for a gang (HQ, safe, garage, medic are
-- all one-per-gang in practice).
function Placeables.FindFor(gangId, kind)
    for _, r in ipairs(rows) do
        if r.gang_id == gangId and r.kind == kind then return r end
    end
    return nil
end

function Placeables.CoordsFor(gangId, kind)
    local r = Placeables.FindFor(gangId, kind)
    if not r then return nil end
    return vec3(r.x, r.y, r.z)
end

-- Wipes every placement a gang has. Used when the zone backing them
-- changes hands — placements aren't usable outside a held zone anymore,
-- so the crew re-places rather than having them silently relocate. The HQ
-- survives: it isn't zone-bound, and losing it would strand the gang.
function Placeables.ClearForGang(gangId)
    if not gangId then return end
    MySQL.update("DELETE FROM xs_gang_placements WHERE gang_id = ? AND kind != 'hq'", { gangId })
    loadAll()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
end

local function tierIndex(tierName)
    for i, t in ipairs(Config.Rep.tiers) do
        if t.name == tierName then return i end
    end
    return 1
end

-- Find which tier (if any) grants `unlockId`.
local function findUnlockDef(unlockId)
    for _, tier in ipairs(Config.Rep.tiers) do
        for _, u in ipairs(Config.TierUnlocks[tier.name] or {}) do
            if u.id == unlockId then return u, tier end
        end
    end
    return nil, nil
end
Placeables.FindUnlockDef = findUnlockDef

-- Is this a legal spot for this gang to build on?
local function placementAllowed(gangId, kind, coords)
    if not Config.Placement.requireZoneOrHq then return true end
    if kind == 'hq' then return true end
    if Territory.IsWithinHeldZone(gangId, coords) then return true end
    local hq = Placeables.CoordsFor(gangId, 'hq')
    if hq and #(coords - hq) <= Config.Placement.hqBuildRadius then return true end
    return false
end

-- ── purchasing ──────────────────────────────────────────────
-- Reaching a tier makes an unlock BUYABLE; paying for it out of the crew
-- bank makes it placeable. Prices come from Prices (config default, staff
-- override wins), so a server owner tunes the economy without a restart.
local bought = {}   -- [gangId] = { [unlockId] = true }

local function loadBought()
    bought = {}
    for _, r in ipairs(MySQL.query.await('SELECT gang_id, unlock_id FROM xs_gang_unlocks') or {}) do
        bought[r.gang_id] = bought[r.gang_id] or {}
        bought[r.gang_id][r.unlock_id] = true
    end
end

-- True when the crew has bought (or been given free) an unlock of this kind
-- and its tier is still within reach.
function Placeables.Owns(gangId, kind)
    local gang = Gangs.Get(gangId)
    if not gang then return false end
    local mods = Gangs.Modifiers(gangId) or {}
    local reach = tierIndex(Rep.Tier(gang.notoriety)) + (mods.tierBoost or 0)
    for i, tier in ipairs(Config.Rep.tiers) do
        for _, u in ipairs(Config.TierUnlocks[tier.name] or {}) do
            if u.kind == kind and i <= reach and Placeables.HasBought(gangId, u.id) then return true end
        end
    end
    return false
end

function Placeables.HasBought(gangId, unlockId)
    -- A free unlock never needs buying, so it is always "owned".
    if Prices.UnlockPrice(unlockId) <= 0 then return true end
    return bought[gangId] ~= nil and bought[gangId][unlockId] == true
end

function Placeables.Buy(src, unlockId)
    if not Gangs.HasPerm(src, 'manage_upgrades') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local def, requiredTier = findUnlockDef(unlockId)
    if not def or def.kind == 'safe' then return false, 'unknown unlock' end

    local mods = Gangs.Modifiers(gang.id)
    if tierIndex(Rep.Tier(gang.notoriety)) + (mods.tierBoost or 0) < tierIndex(requiredTier.name) then
        return false, ('your crew has to reach %s first'):format(requiredTier.name)
    end
    if Placeables.HasBought(gang.id, unlockId) then return false, 'already unlocked' end

    local price = Prices.UnlockPrice(unlockId)
    if gang.bank < price then return false, ('costs $%d — the bank is short'):format(price) end

    -- Conditional debit: two members hitting Buy at once can't both win.
    local affected = MySQL.update.await('UPDATE xs_gangs SET bank = bank - ? WHERE id = ? AND bank >= ?',
        { price, gang.id, price })
    if not affected or affected < 1 then return false, 'the bank is short' end
    gang.bank = gang.bank - price

    MySQL.query.await(
        'INSERT INTO xs_gang_unlocks (gang_id, unlock_id, paid) VALUES (?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE paid = ?',
        { gang.id, unlockId, price, price })
    bought[gang.id] = bought[gang.id] or {}
    bought[gang.id][unlockId] = true

    MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
        { gang.id, Framework.GetCitizenId(src) or '', Framework.GetName(src) or 'Someone', 'unlock', price })

    Gangs.Log(gang.id, ('%s unlocked the %s for $%d'):format(
        Framework.GetName(src) or 'Someone', def.label, price), 'economy')
    Discord.Send('economy', 'Unlock bought', ('%s — %s ($%d)'):format(gang.label, def.label, price), Discord.Color.info)
    Gangs.Broadcast(gang.id, 'treasury', {})
    if def.kind == 'medic' and Medic then
        for _, s in ipairs(Gangs.OnlineSources(gang.id)) do Medic.Refresh(s) end
    end
    return true
end

function Placeables.Place(src, unlockId, coords, heading)
    if not Gangs.HasPerm(src, 'place_objects') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    if type(coords) ~= 'vector3' then return false, 'bad coords' end

    local def, requiredTier = findUnlockDef(unlockId)
    if not def then return false, 'unknown unlock' end
    if not isPlaceable(def) then return false, 'that one has nothing to place' end

    local mods = Gangs.Modifiers(gang.id)
    local effectiveTier = tierIndex(Rep.Tier(gang.notoriety)) + (mods.tierBoost or 0)
    if effectiveTier < tierIndex(requiredTier.name) then return false, 'tier too low' end
    if not Placeables.HasBought(gang.id, unlockId) then
        return false, ('your crew has not bought the %s yet'):format(def.label)
    end

    local playerPos = GetEntityCoords(GetPlayerPed(src))
    if #(playerPos - coords) > Config.Placement.maxPlaceDistance then
        return false, 'too far from your position'
    end

    if not placementAllowed(gang.id, def.kind, coords) then
        return false, 'has to be on turf you hold, or near your HQ'
    end

    MySQL.query.await(
        'INSERT INTO xs_gang_placements (gang_id, kind, unlock_id, model, label, x, y, z, heading, placed_by) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model = ?, label = ?, x = ?, y = ?, z = ?, heading = ?, placed_by = ?',
        { gang.id, def.kind, unlockId, def.model, def.label, coords.x, coords.y, coords.z, heading,
          Framework.GetCitizenId(src) or '',
          def.model, def.label, coords.x, coords.y, coords.z, heading, Framework.GetCitizenId(src) or '' })

    loadAll()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
    Gangs.Log(gang.id, ('%s placed the %s'):format(Framework.GetName(src) or 'Someone', def.label), 'property')
    Gangs.Broadcast(gang.id, 'placements', {})

    if def.kind == 'vault' then Vault.Refresh(gang.id) end
    return true
end

function Placeables.Remove(src, unlockId)
    if not Gangs.HasPerm(src, 'remove_objects') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local def = findUnlockDef(unlockId)
    if not def then return false, 'unknown unlock' end

    MySQL.update('DELETE FROM xs_gang_placements WHERE gang_id = ? AND unlock_id = ?', { gang.id, unlockId })
    loadAll()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
    Gangs.Log(gang.id, ('%s picked up the %s'):format(Framework.GetName(src) or 'Someone', def.label), 'property')
    Gangs.Broadcast(gang.id, 'placements', {})
    return true
end

-- Every unlock the gang could ever place, locked ones included — members
-- can see exactly what they're grinding toward.
function Placeables.GetAvailable(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return { unlocks = {} } end

    local mods = Gangs.Modifiers(gang.id)
    local realTierIdx = tierIndex(Rep.Tier(gang.notoriety))
    local effectiveTierIdx = realTierIdx + (mods.tierBoost or 0)
    local placedFor = byGangKind[gang.id] or {}

    local list = {}
    for i, tier in ipairs(Config.Rep.tiers) do
        for _, u in ipairs(Config.TierUnlocks[tier.name] or {}) do
            if u.kind == 'safe' then goto continue end
            local placed = placedFor[key(u.kind, u.id)]
            local price = Prices.UnlockPrice(u.id)
            local owned = Placeables.HasBought(gang.id, u.id)
            list[#list + 1] = {
                id = u.id,
                kind = u.kind,
                label = u.label,
                model = u.model,
                placed = placed ~= nil,
                placeable = isPlaceable(u),
                where = u.kind == 'medic' and owned and Medic and Medic.Location() or nil,
                note = u.kind == 'task' and ('+%d%% cash and rep on every contract'):format(tonumber(Config.Contracts.dropBonusPct) or 0)
                    or (u.kind == 'medic' and ('One doctor every crew shares. Once bought he shows on your Live Map: $%d to patch you up, $%d to bring back the downed.'):format(Config.Medic.healPrice or 0, Config.Medic.revivePrice or 0))
                    or nil,
                coords = placed and { x = placed.x, y = placed.y, z = placed.z } or nil,
                locked = i > effectiveTierIdx,
                price = price,
                owned = owned,
                affordable = gang.bank >= price,
                tierName = tier.name,
                tierRep = tier.min,
                tierIndex = i,
            }
            ::continue::
        end
    end

    return {
        unlocks = list,
        tier = Rep.Tier(gang.notoriety),
        tierIndex = realTierIdx,
        tierBoost = mods.tierBoost or 0,
        rep = gang.notoriety,
        bank = gang.bank,
        canPlace = Gangs.HasPerm(src, 'place_objects'),
        canRemove = Gangs.HasPerm(src, 'remove_objects'),
        canBuy = Gangs.HasPerm(src, 'manage_upgrades'),
        hasHq = Placeables.FindFor(gang.id, 'hq') ~= nil,
        buildRadius = Config.Placement.hqBuildRadius,
    }
end

CreateThread(function()
    Wait(2000)
    local ok, err = pcall(retireOld)
    if not ok then print('^1[XS-CriminalTablet]^0 could not retire the Crew Safe: ' .. tostring(err)) end
    loadAll()
    loadBought()
end)

Placeables._reload = function()
    loadAll()
    loadBought()
end

-- Staff wiping a crew back to zero clears what they'd bought too.
-- Staff placement. Everything a member has to earn — the tier gate, the
-- purchase, standing inside your own turf, being within arm's reach of the
-- ghost prop — is skipped, because staff are setting a crew up rather than
-- playing as one. Still one row per (gang, kind, unlock), so re-placing
-- moves the prop instead of stacking a second one.
function Placeables.AdminPlace(gangId, unlockId, coords, heading)
    gangId = tonumber(gangId)
    if not gangId or not Gangs.Get(gangId) then return false, 'unknown gang' end

    local def = findUnlockDef(unlockId)
    if not def then return false, 'unknown unlock' end
    if not isPlaceable(def) then return false, 'that one has nothing to place' end
    if type(coords) ~= 'table' or not tonumber(coords.x) or not tonumber(coords.y) then
        return false, 'needs a position'
    end

    local x, y = tonumber(coords.x), tonumber(coords.y)
    local z = tonumber(coords.z) or 30.0

    MySQL.query.await(
        'INSERT INTO xs_gang_placements (gang_id, kind, unlock_id, model, label, x, y, z, heading, placed_by) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model = VALUES(model), label = VALUES(label), ' ..
        'x = VALUES(x), y = VALUES(y), z = VALUES(z), heading = VALUES(heading), placed_by = VALUES(placed_by)',
        { gangId, def.kind, def.id, def.model, def.label, x, y, z, tonumber(heading) or 0.0, 'staff' })

    -- Staff placing something the crew never bought counts as granting it,
    -- otherwise the prop exists but the crew cannot move or remove it.
    MySQL.query.await(
        'INSERT IGNORE INTO xs_gang_unlocks (gang_id, unlock_id) VALUES (?, ?)', { gangId, def.id })

    loadAll()
    loadBought()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
    return true, def.label
end

-- Remove one placement outright, whoever put it there.
function Placeables.AdminRemove(gangId, unlockId)
    gangId = tonumber(gangId)
    if not gangId then return false, 'unknown gang' end
    MySQL.update('DELETE FROM xs_gang_placements WHERE gang_id = ? AND unlock_id = ?', { gangId, unlockId })
    loadAll()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
    return true
end

-- Every unlock staff can place, flat, with no tier filtering.
function Placeables.CatalogueAll()
    local list = {}
    for tier, defs in pairs(Config.TierUnlocks) do
        for _, def in ipairs(defs) do
            if isPlaceable(def) and def.kind ~= 'safe' then list[#list + 1] = {
                id = def.id, kind = def.kind, label = def.label,
                model = def.model, tier = tier,
            } end
        end
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end

-- The vault's prop grows with the Vault Expansion upgrade. Re-model
-- whatever the crew already placed rather than making them take it down
-- and put it back for a bigger box.
function Placeables.RefreshVaultModel(gangId, level)
    gangId = tonumber(gangId)
    if not gangId then return end

    local models = Config.Vault.levelModels
    if type(models) ~= 'table' or #models == 0 then return end

    local idx = math.max(1, math.min(#models, (tonumber(level) or 0) + 1))
    local model = models[idx]
    if not model or model == '' then return end

    local changed = MySQL.update.await(
        "UPDATE xs_gang_placements SET model = ? WHERE gang_id = ? AND kind = 'vault' AND model != ?",
        { model, gangId, model })
    if not changed or changed < 1 then return end

    loadAll()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
end

function Placeables.ClearBought(gangId)
    MySQL.update('DELETE FROM xs_gang_unlocks WHERE gang_id = ?', { gangId })
    bought[gangId] = nil
end

lib.callback.register('XS-CriminalTablet:placeables:buy', function(src, unlockId)
    local ok, err = Placeables.Buy(src, unlockId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:placeables:getAll', function()
    return Placeables.GetAll()
end)

lib.callback.register('XS-CriminalTablet:placeables:getAvailable', function(src)
    return Placeables.GetAvailable(src)
end)

lib.callback.register('XS-CriminalTablet:placeables:place', function(src, unlockId, coords, heading)
    local ok, err = Placeables.Place(src, unlockId, coords, tonumber(heading) or 0.0)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:placeables:remove', function(src, unlockId)
    local ok, err = Placeables.Remove(src, unlockId)
    return { ok = ok, error = err }
end)

-- Triggered by the client's vault interaction — already physically at the
-- container, so Vault.Open does the rest of the gating.
RegisterNetEvent('XS-CriminalTablet:server:openVault', function()
    Vault.Open(source)
end)
