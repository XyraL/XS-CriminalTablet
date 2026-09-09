-- ─────────────────────────────────────────────────────────────
-- Territory: zones assigned to a gang entirely by admins (no in-world
-- capture, no passive income — holding a zone is purely prestige/visual).
-- Config.Territories is just an optional first-boot seed; admins can also
-- create/move zones live through the admin tablet, which is the source of
-- truth from then on.
-- ─────────────────────────────────────────────────────────────
Territory = {}

local zones = {}  -- [zone] = { label, color, coords, gangId }

local function rowToZone(row)
    local coords = (row.coord_x and row.coord_y and row.coord_z)
        and vec3(row.coord_x, row.coord_y, row.coord_z) or nil
    local seed = Config.Territories[row.zone]
    return {
        label = (row.label ~= '' and row.label) or (seed and seed.label) or row.zone,
        color = row.color ~= 0 and row.color or (seed and seed.color) or 0,
        coords = coords or (seed and seed.coords) or nil,
        gangId = row.gang_id,
    }
end

local function loadZones()
    zones = {}
    -- seed any config zone that doesn't exist in the DB yet
    for zone, def in pairs(Config.Territories) do
        local exists = MySQL.single.await('SELECT zone FROM xs_territories WHERE zone = ?', { zone })
        if not exists then
            MySQL.insert.await(
                'INSERT INTO xs_territories (zone, label, color, coord_x, coord_y, coord_z) VALUES (?, ?, ?, ?, ?, ?)',
                { zone, def.label or zone, def.color or 0, def.coords.x, def.coords.y, def.coords.z })
        end
    end

    for _, row in ipairs(MySQL.query.await('SELECT * FROM xs_territories') or {}) do
        zones[row.zone] = rowToZone(row)
    end
end

-- Zones currently assigned to a gang (for the UI snapshot).
function Territory.HeldBy(gangId)
    local list = {}
    for zone, z in pairs(zones) do
        if z.gangId == gangId then list[#list + 1] = { zone = zone, label = z.label } end
    end
    return list
end

function Territory.GetAll()
    local list = {}
    for zone, z in pairs(zones) do
        if z.coords then
            local gang = z.gangId and Gangs.Get(z.gangId)
            list[#list + 1] = {
                zone = zone,
                label = z.label,
                coords = z.coords,
                color = z.color,
                holder = gang and gang.label or nil,
                holderId = z.gangId,
                holderTier = gang and Notoriety.Tier(gang.notoriety) or nil,
            }
        end
    end
    return list
end

-- Player-facing version: unassigned zones don't exist as far as players
-- are concerned (no blip, no tablet entry). Admins still see everything
-- via Territory.GetAll() — they're the ones who'd assign an empty zone.
function Territory.GetAssigned()
    local list = {}
    for _, t in ipairs(Territory.GetAll()) do
        if t.holderId then list[#list + 1] = t end
    end
    return list
end

function Territory.GetZone(zone)
    return zones[zone]
end

local function tierIndex(tierName)
    for i, t in ipairs(Config.Notoriety.tiers) do
        if t.name == tierName then return i end
    end
    return 1
end

-- Mirrors the client's visual radius growth/cap, but server-side, so
-- placement can be bound-checked against the same effective zone size
-- the player actually sees on the map.
local maxGrowthIdx = tierIndex(Config.ZoneRadiusMaxTier) - 1
function Territory.RadiusFor(zone)
    local z = zones[zone]
    if not z then return Config.ZoneRadius end
    if not z.gangId then return Config.ZoneRadius end
    local gang = Gangs.Get(z.gangId)
    if not gang then return Config.ZoneRadius end
    local steps = math.min(tierIndex(Notoriety.Tier(gang.notoriety)) - 1, maxGrowthIdx)
    return Config.ZoneRadius + steps * Config.ZoneRadiusGrowthPerTier
end

-- True if `coords` falls inside any zone `gangId` currently holds.
function Territory.IsWithinHeldZone(gangId, coords)
    for zone, z in pairs(zones) do
        if z.gangId == gangId and z.coords then
            if #(coords - z.coords) <= Territory.RadiusFor(zone) then return true end
        end
    end
    return false
end

-- ── admin-only mutations ─────────────────────────────────────
-- Bypasses permission/presence checks — callers must have already
-- verified admin access (see server/admin.lua).
function Territory.CreateZone(zone, label, color)
    zone = (zone or ''):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    if #zone < 2 then return false, 'zone key too short' end
    if zones[zone] then return false, 'zone already exists' end

    MySQL.insert.await(
        'INSERT INTO xs_territories (zone, label, color) VALUES (?, ?, ?)',
        { zone, label or zone, color or 0 })
    zones[zone] = { label = label or zone, color = color or 0, coords = nil, gangId = nil }
    return true, zone
end

function Territory.SetZoneCoords(zone, coords)
    if not zones[zone] then return false, 'unknown zone' end
    MySQL.update('UPDATE xs_territories SET coord_x = ?, coord_y = ?, coord_z = ? WHERE zone = ?',
        { coords.x, coords.y, coords.z, zone })
    zones[zone].coords = coords
    return true
end

function Territory.UpdateZone(zone, fields)
    if not zones[zone] then return false, 'unknown zone' end
    if fields.label then
        MySQL.update('UPDATE xs_territories SET label = ? WHERE zone = ?', { fields.label, zone })
        zones[zone].label = fields.label
    end
    if fields.color then
        MySQL.update('UPDATE xs_territories SET color = ? WHERE zone = ?', { fields.color, zone })
        zones[zone].color = fields.color
    end
    return true
end

function Territory.DeleteZone(zone)
    if not zones[zone] then return false, 'unknown zone' end
    MySQL.update('DELETE FROM xs_territories WHERE zone = ?', { zone })
    zones[zone] = nil
    return true
end

-- Returns the PREVIOUS holder as a third value, so callers can clear that
-- gang's now-stranded placements (see server/admin.lua).
function Territory.SetHolder(zone, gangId)
    if not zones[zone] then return false, 'unknown zone' end
    if gangId and not Gangs.Get(gangId) then return false, 'unknown gang' end
    local previousGangId = zones[zone].gangId
    MySQL.update('UPDATE xs_territories SET gang_id = ?, assigned_at = ? WHERE zone = ?',
        { gangId, os.time() * 1000, zone })
    zones[zone].gangId = gangId
    return true, nil, previousGangId
end

-- Called when a gang is disbanded — the DB FK already SETs NULL via
-- cascade, but the in-memory cache won't know until a restart otherwise.
function Territory.ClearHolder(gangId)
    for zone, z in pairs(zones) do
        if z.gangId == gangId then z.gangId = nil end
    end
end

CreateThread(function()
    Wait(2000)
    loadZones()
    TriggerClientEvent('XS-CriminalTablet:client:territoryUpdate', -1, Territory.GetAssigned())
end)

lib.callback.register('XS-CriminalTablet:territory:getAll', function()
    return Territory.GetAssigned()
end)
