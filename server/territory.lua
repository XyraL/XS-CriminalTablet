-- ─────────────────────────────────────────────────────────────
-- Territory: staff-owned zones.
--
-- A zone is either a polygon (points walked out in the in-world creator)
-- or a plain radius around a centre. There are NO neutral zones: staff
-- draw a zone for a specific crew and it stays theirs until staff move
-- it. Holding one is prestige, rep and the right to build on it — there
-- is deliberately no passive income, and no player action takes turf off
-- anyone. A zone with nobody assigned is hidden from players entirely.
--
-- Config.Territories is a first-boot seed only. Everything after that is
-- owned by the admin creator, which writes straight to the DB.
-- ─────────────────────────────────────────────────────────────
Territory = {}

local zones = {}  -- [zone] = { label, color, points, radius, coords, capturable, gangId }

local function now() return os.time() * 1000 end

local function decodePoints(raw)
    if not raw or raw == '' then return nil end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' or #decoded < 3 then return nil end
    local pts = {}
    for _, p in ipairs(decoded) do
        local x, y = tonumber(p.x), tonumber(p.y)
        if x and y then pts[#pts + 1] = { x = x, y = y } end
    end
    return #pts >= 3 and pts or nil
end

local function rowToZone(row)
    local coords = (row.coord_x and row.coord_y and row.coord_z)
        and vec3(row.coord_x, row.coord_y, row.coord_z) or nil
    local seed = Config.Territories[row.zone]
    return {
        label = (row.label ~= '' and row.label) or (seed and seed.label) or row.zone,
        color = row.color ~= 0 and row.color or (seed and seed.color) or 0,
        points = decodePoints(row.points),
        radius = row.radius and row.radius > 0 and row.radius or Config.Territory.defaultRadius,
        coords = coords or (seed and seed.coords) or nil,
        capturable = row.capturable ~= 0,
        gangId = row.gang_id,
    }
end

local function loadZones()
    zones = {}
    for zone, def in pairs(Config.Territories) do
        local exists = MySQL.single.await('SELECT zone FROM xs_territories WHERE zone = ?', { zone })
        if not exists then
            MySQL.insert.await(
                'INSERT INTO xs_territories (zone, label, color, radius, coord_x, coord_y, coord_z) ' ..
                'VALUES (?, ?, ?, ?, ?, ?, ?)',
                { zone, def.label or zone, def.color or 0, Config.Territory.defaultRadius,
                  def.coords.x, def.coords.y, def.coords.z })
        end
    end

    for _, row in ipairs(MySQL.query.await('SELECT * FROM xs_territories') or {}) do
        zones[row.zone] = rowToZone(row)
    end
end

-- ── geometry ────────────────────────────────────────────────
-- Standard ray-cast point-in-polygon. Zones are 2D footprints; height is
-- ignored on purpose so a rooftop still counts as being on the block.
local function pointInPolygon(pts, x, y)
    local inside = false
    local j = #pts
    for i = 1, #pts do
        local xi, yi = pts[i].x, pts[i].y
        local xj, yj = pts[j].x, pts[j].y
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

local function zoneContains(z, coords)
    if z.points then return pointInPolygon(z.points, coords.x, coords.y) end
    if not z.coords then return false end
    return #(vec2(coords.x, coords.y) - vec2(z.coords.x, z.coords.y)) <= (z.radius or Config.Territory.defaultRadius)
end
Territory.ZoneContains = zoneContains

-- Centroid of a polygon, used as the blip/marker anchor when a zone is
-- drawn rather than dropped as a circle.
local function centroidOf(pts)
    local sx, sy = 0.0, 0.0
    for _, p in ipairs(pts) do sx = sx + p.x; sy = sy + p.y end
    return sx / #pts, sy / #pts
end

-- Which zone a position falls inside, if any.
function Territory.ZoneAt(coords)
    for key, z in pairs(zones) do
        if zoneContains(z, coords) then return key, z end
    end
    return nil, nil
end

-- ── reads ───────────────────────────────────────────────────
function Territory.GetZone(zone) return zones[zone] end
function Territory.All() return zones end

function Territory.HeldBy(gangId)
    local list = {}
    for zone, z in pairs(zones) do
        if z.gangId == gangId then
            list[#list + 1] = { zone = zone, label = z.label }
        end
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end

function Territory.CountHeldBy(gangId)
    local n = 0
    for _, z in pairs(zones) do
        if z.gangId == gangId then n = n + 1 end
    end
    return n
end

-- One zone, shaped for the client/UI.
local function serialize(key, z)
    local gang = z.gangId and Gangs.Get(z.gangId)
    local cx, cy
    if z.points then cx, cy = centroidOf(z.points)
    elseif z.coords then cx, cy = z.coords.x, z.coords.y end

    return {
        zone = key,
        label = z.label,
        coords = z.coords,
        center = cx and { x = cx, y = cy } or nil,
        points = z.points,
        radius = z.radius,
        color = z.color,
        capturable = z.capturable,
        holder = gang and gang.label or nil,
        holderId = z.gangId,
        holderColor = gang and gang.color or nil,
        holderTier = gang and Rep.Tier(gang.notoriety) or nil,
        influence = Capture and Capture.StateOf(key) or nil,
    }
end

-- Staff view: EVERY zone, shape or not. A zone that has just been created
-- has no footprint yet, and filtering those out here is what made a new
-- zone vanish from the admin panel the moment it was made — with no row
-- left to give it a shape from.
function Territory.GetAll()
    local list = {}
    for key, z in pairs(zones) do list[#list + 1] = serialize(key, z) end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end

-- What any player is allowed to see: drawn, and belonging to a crew.
function Territory.PublicList()
    local list = {}
    for key, z in pairs(zones) do
        if (z.coords or z.points) and z.gangId then list[#list + 1] = serialize(key, z) end
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end

-- What a specific player is allowed to see.
--
-- Zones with no crew assigned are invisible to players — there is no such
-- thing as neutral turf in this system, only a zone staff have drawn but
-- not handed to anyone yet. Staff see those in the admin panel.
--
-- Influence stays visible on every zone a player can see: knowing a rival
-- is 40% into your block is the whole signal.
function Territory.GetVisible(src)
    local gang = src and Gangs.GetBySource(src)
    local myId = gang and gang.id or nil
    local list = Territory.PublicList()
    for _, entry in ipairs(list) do
        entry.mine = entry.holderId == myId
        entry.myInfluence = (gang and Capture)
            and math.floor(Capture.InfluenceFor(entry.zone, gang.id) + 0.5) or 0
    end
    return list
end

-- ── placement gating ────────────────────────────────────────
function Territory.IsWithinHeldZone(gangId, coords)
    for _, z in pairs(zones) do
        if z.gangId == gangId and zoneContains(z, coords) then return true end
    end
    return false
end

-- True when this player may interact with something standing at `coords`.
-- Gang-locked zones keep rivals out of a crew's benches and vault; any
-- position not inside a zone at all is fair game.
function Territory.CanInteractAt(src, coords)
    if not Config.Territory.gangLocked then return true end
    local key, z = Territory.ZoneAt(coords)
    if not key or not z.gangId then return true end
    local gang = Gangs.GetBySource(src)
    if gang and gang.id == z.gangId then return true end
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- ── mutations (admin / creator owned) ───────────────────────
-- Everyone gets the public list. Sending GetAll() here put staff-only
-- zones — including ones with no crew on them — onto every player's map.
local function broadcast()
    TriggerClientEvent('XS-CriminalTablet:client:territoryUpdate', -1, Territory.PublicList())
end
Territory.Broadcast = broadcast

function Territory.CreateZone(zone, label, color)
    zone = (zone or ''):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    if #zone < 2 then return false, 'zone key too short' end
    if zones[zone] then return false, 'zone already exists' end

    MySQL.insert.await(
        'INSERT INTO xs_territories (zone, label, color, radius) VALUES (?, ?, ?, ?)',
        { zone, label or zone, color or 0, Config.Territory.defaultRadius })
    zones[zone] = {
        label = label or zone, color = color or 0, points = nil,
        radius = Config.Territory.defaultRadius, coords = nil,
        capturable = true, gangId = nil,
    }
    return true, zone
end

function Territory.SetZoneCoords(zone, coords)
    if not zones[zone] then return false, 'unknown zone' end
    MySQL.update('UPDATE xs_territories SET coord_x = ?, coord_y = ?, coord_z = ? WHERE zone = ?',
        { coords.x, coords.y, coords.z, zone })
    zones[zone].coords = coords
    return true
end

-- Replace a zone's footprint with a polygon. `points` is the list walked
-- out in the creator; the centre is recomputed from it so the blip and
-- marker sit in the middle of whatever shape was drawn.
function Territory.SetPolygon(zone, points, z)
    if not zones[zone] then return false, 'unknown zone' end
    if type(points) ~= 'table' or #points < 3 then return false, 'need at least 3 corners' end

    local clean = {}
    for _, p in ipairs(points) do
        local x, y = tonumber(p.x), tonumber(p.y)
        if x and y then clean[#clean + 1] = { x = x, y = y } end
    end
    if #clean < 3 then return false, 'need at least 3 corners' end

    local cx, cy = centroidOf(clean)
    local cz = tonumber(z) or (zones[zone].coords and zones[zone].coords.z) or 30.0

    MySQL.update('UPDATE xs_territories SET points = ?, coord_x = ?, coord_y = ?, coord_z = ? WHERE zone = ?',
        { json.encode(clean), cx, cy, cz, zone })
    zones[zone].points = clean
    zones[zone].coords = vec3(cx, cy, cz)
    return true
end

-- Quick square centred on a position — the "I just want a zone here"
-- button, so admins aren't forced to walk a polygon for every block.
function Territory.SetSquare(zone, coords, size)
    size = tonumber(size) or Config.Territory.defaultSquareSize
    local h = size / 2
    return Territory.SetPolygon(zone, {
        { x = coords.x - h, y = coords.y - h },
        { x = coords.x + h, y = coords.y - h },
        { x = coords.x + h, y = coords.y + h },
        { x = coords.x - h, y = coords.y + h },
    }, coords.z)
end

function Territory.UpdateZone(zone, fields)
    if not zones[zone] then return false, 'unknown zone' end
    if fields.label then
        MySQL.update('UPDATE xs_territories SET label = ? WHERE zone = ?', { fields.label, zone })
        zones[zone].label = fields.label
    end
    if fields.color then
        MySQL.update('UPDATE xs_territories SET color = ? WHERE zone = ?', { tonumber(fields.color) or 0, zone })
        zones[zone].color = tonumber(fields.color) or 0
    end
    if fields.radius then
        local r = math.max(10.0, math.min(500.0, tonumber(fields.radius) or Config.Territory.defaultRadius))
        MySQL.update('UPDATE xs_territories SET radius = ? WHERE zone = ?', { r, zone })
        zones[zone].radius = r
    end
    if fields.capturable ~= nil then
        local cap = fields.capturable and 1 or 0
        MySQL.update('UPDATE xs_territories SET capturable = ? WHERE zone = ?', { cap, zone })
        zones[zone].capturable = cap == 1
    end
    return true
end

function Territory.DeleteZone(zone)
    if not zones[zone] then return false, 'unknown zone' end
    MySQL.update('DELETE FROM xs_territories WHERE zone = ?', { zone })
    zones[zone] = nil
    if Capture then Capture.Abort(zone) end
    return true
end

-- Returns the PREVIOUS holder as a third value so callers can clean up
-- that gang's now-stranded placements.
-- Moving a zone between crews is a STAFF action — nothing a player does
-- reaches this. `awardRep` is off by default because handing a crew their
-- block shouldn't pay them rep for it; the one caller that does want the
-- reward is a won raid, when captureZoneOnWin is switched on.
function Territory.SetHolder(zone, gangId, reason, awardRep)
    local z = zones[zone]
    if not z then return false, 'unknown zone' end
    if gangId and not Gangs.Get(gangId) then return false, 'unknown gang' end

    local previousGangId = z.gangId
    if previousGangId == gangId then return true, nil, previousGangId end

    MySQL.update('UPDATE xs_territories SET gang_id = ?, assigned_at = ? WHERE zone = ?',
        { gangId, now(), zone })
    z.gangId = gangId

    if gangId then
        if awardRep then Rep.Add(gangId, Config.Rep.rewards.zone_captured, reason or 'turf taken') end
        Gangs.Log(gangId, ('%s is now your crew\'s block'):format(z.label), 'war')
        Gangs.NotifyGang(gangId, ('%s is yours.'):format(z.label), 'success')
    end
    if previousGangId then
        if awardRep then Rep.Add(previousGangId, Config.Rep.rewards.zone_lost, reason or 'turf lost') end
        Gangs.Log(previousGangId, ('Lost %s'):format(z.label), 'war')
        Gangs.NotifyGang(previousGangId, ('You no longer hold %s.'):format(z.label), 'error')
        Placeables.ClearForGang(previousGangId)
    end

    -- A zone with no holder is invisible to players, so its influence
    -- history is meaningless — clear it rather than leaving ghost shares.
    if not gangId and Capture then Capture.Abort(zone) end

    Discord.Send('war', 'Turf reassigned', ('%s → %s'):format(
        z.label, gangId and (Gangs.Get(gangId).label) or 'unassigned'), Discord.Color.warn)

    broadcast()
    return true, nil, previousGangId
end

-- Called when a gang is disbanded — the DB FK SETs NULL via cascade, but
-- the in-memory cache wouldn't know until a restart otherwise.
function Territory.ClearHolder(gangId)
    for _, z in pairs(zones) do
        if z.gangId == gangId then z.gangId = nil end
    end
end

CreateThread(function()
    Wait(2000)
    loadZones()
    broadcast()
end)

Territory._reload = loadZones

lib.callback.register('XS-CriminalTablet:territory:getAll', function(src)
    return Territory.GetVisible(src)
end)
