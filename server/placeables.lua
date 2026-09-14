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

local function loadAll()
    rows = MySQL.query.await('SELECT * FROM xs_gang_placements') or {}
    byGangKind = {}
    for _, r in ipairs(rows) do
        byGangKind[r.gang_id] = byGangKind[r.gang_id] or {}
        byGangKind[r.gang_id][key(r.kind, r.unlock_id)] = r
    end
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
    if not def then return false, 'unknown unlock' end

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
    return true
end

function Placeables.Place(src, unlockId, coords, heading)
    if not Gangs.HasPerm(src, 'place_objects') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    if type(coords) ~= 'vector3' then return false, 'bad coords' end

    local def, requiredTier = findUnlockDef(unlockId)
    if not def then return false, 'unknown unlock' end

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
            local placed = placedFor[key(u.kind, u.id)]
            local price = Prices.UnlockPrice(u.id)
            local owned = Placeables.HasBought(gang.id, u.id)
            list[#list + 1] = {
                id = u.id,
                kind = u.kind,
                label = u.label,
                model = u.model,
                placed = placed ~= nil,
                coords = placed and { x = placed.x, y = placed.y, z = placed.z } or nil,
                locked = i > effectiveTierIdx,
                price = price,
                owned = owned,
                affordable = gang.bank >= price,
                tierName = tier.name,
                tierRep = tier.min,
                tierIndex = i,
            }
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
            list[#list + 1] = {
                id = def.id, kind = def.kind, label = def.label,
                model = def.model, tier = tier,
            }
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
