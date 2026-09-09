-- ─────────────────────────────────────────────────────────────
-- Placeables: boss-placed world objects. Two kinds use this:
--   - Tier-unlock benches/peds (Config.TierUnlocks) — gated by tier.
--   - The gang vault container — gated only by permission, no tier.
-- One row per (gang, kind, unlock_id); re-placing moves it instead of
-- stacking duplicates. Position is client-reported (it's a placement
-- preview, not the player's own feet), so we bound-check it against the
-- player's actual position server-side to stop wildly out-of-range spam.
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

function Placeables.GetAll()
    return rows
end

-- Wipes every placement a gang has — used when the zone backing them
-- moves or changes hands, since placements aren't usable outside a held
-- zone anymore (see Territory.IsWithinHeldZone). The Boss just re-places
-- everything in the new spot rather than them silently relocating.
function Placeables.ClearForGang(gangId)
    if not gangId then return end
    MySQL.update('DELETE FROM xs_gang_placements WHERE gang_id = ?', { gangId })
    loadAll()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
end

local function tierIndex(tierName)
    for i, t in ipairs(Config.Notoriety.tiers) do
        if t.name == tierName then return i end
    end
    return 1
end

-- Find which tier (if any) grants `unlockId` under TierUnlocks[*][cfgKind].
local function findUnlockDef(cfgKind, unlockId)
    for _, tier in ipairs(Config.Notoriety.tiers) do
        local def = Config.TierUnlocks[tier.name]
        if def and def[cfgKind] then
            for _, u in ipairs(def[cfgKind]) do
                if u.id == unlockId then return u, tier end
            end
        end
    end
    return nil, nil
end

function Placeables.Place(src, kind, unlockId, coords, heading)
    if not Gangs.HasPerm(src, 'place_objects') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    if type(coords) ~= 'vector3' then return false, 'bad coords' end

    local model, label
    if kind == 'vault' then
        unlockId = 'vault'
        model, label = Config.Vault.model, Config.Vault.label
    elseif kind == 'bench' or kind == 'ped' then
        local cfgKind = kind == 'bench' and 'benches' or 'peds'
        local def, requiredTier = findUnlockDef(cfgKind, unlockId)
        if not def then return false, 'unknown unlock' end
        if tierIndex(Notoriety.Tier(gang.notoriety)) < tierIndex(requiredTier.name) then
            return false, 'tier too low'
        end
        model, label = def.model, def.label
    else
        return false, 'unknown kind'
    end

    local playerPos = GetEntityCoords(GetPlayerPed(src))
    if #(playerPos - coords) > 6.0 then return false, 'too far from your position' end

    if not Territory.IsWithinHeldZone(gang.id, coords) then
        return false, 'your gang must hold a zone here to place this'
    end

    local cid = Framework.GetCitizenId(src)
    MySQL.insert.await(
        'INSERT INTO xs_gang_placements (gang_id, kind, unlock_id, model, label, x, y, z, heading, placed_by) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE model = ?, label = ?, x = ?, y = ?, z = ?, heading = ?, placed_by = ?',
        { gang.id, kind, unlockId, model, label, coords.x, coords.y, coords.z, heading, cid,
          model, label, coords.x, coords.y, coords.z, heading, cid })

    loadAll()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
    Gangs.Log(gang.id, ('%s placed %s'):format(Framework.GetName(src) or cid, label))
    return true
end

function Placeables.Remove(src, kind, unlockId)
    if not Gangs.HasPerm(src, 'place_objects') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    MySQL.update('DELETE FROM xs_gang_placements WHERE gang_id = ? AND kind = ? AND unlock_id = ?',
        { gang.id, kind, unlockId })
    loadAll()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
    Gangs.Log(gang.id, ('%s removed a placement'):format(Framework.GetName(src) or ''))
    return true
end

-- Every bench/ped/vault, whether unlocked or not — locked entries show the
-- tier/rep needed so members know what to grind toward.
function Placeables.GetAvailable(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return {} end
    local myTierIdx = tierIndex(Notoriety.Tier(gang.notoriety))
    local placedFor = byGangKind[gang.id] or {}

    local list = {
        { kind = 'vault', id = 'vault', label = Config.Vault.label,
          placed = placedFor[key('vault', 'vault')] ~= nil, locked = false },
    }

    for i, tier in ipairs(Config.Notoriety.tiers) do
        local def = Config.TierUnlocks[tier.name]
        if def then
            local locked = i > myTierIdx
            for _, b in ipairs(def.benches or {}) do
                list[#list + 1] = { kind = 'bench', id = b.id, label = b.label,
                    placed = placedFor[key('bench', b.id)] ~= nil, locked = locked,
                    tierName = tier.name, tierRep = tier.min }
            end
            for _, p in ipairs(def.peds or {}) do
                list[#list + 1] = { kind = 'ped', id = p.id, label = p.label,
                    placed = placedFor[key('ped', p.id)] ~= nil, locked = locked,
                    tierName = tier.name, tierRep = tier.min }
            end
        end
    end
    return list
end

CreateThread(function()
    Wait(2000)
    loadAll()
end)

lib.callback.register('XS-CriminalTablet:placeables:getAll', function()
    return Placeables.GetAll()
end)

lib.callback.register('XS-CriminalTablet:placeables:getAvailable', function(src)
    return Placeables.GetAvailable(src)
end)

lib.callback.register('XS-CriminalTablet:placeables:place', function(src, kind, unlockId, coords, heading)
    local ok, err = Placeables.Place(src, kind, unlockId, coords, tonumber(heading) or 0.0)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:placeables:remove', function(src, kind, unlockId)
    local ok, err = Placeables.Remove(src, kind, unlockId)
    return { ok = ok, error = err }
end)

-- Triggered by the client's vault proximity prompt — already physically
-- near the placed container, so no permission re-check needed beyond
-- what Vault.Open already does.
RegisterNetEvent('XS-CriminalTablet:server:openVault', function()
    Vault.Open(source)
end)
