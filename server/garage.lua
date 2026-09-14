-- ─────────────────────────────────────────────────────────────
-- Gang garage. Vehicles belong to the gang, not a person — anyone with
-- the right rank can pull one out, and it goes back to the same shared
-- pool. Capacity scales with the Garage Expansion upgrade.
--
-- Spawning happens client-side (so the vehicle inherits whatever your
-- server's keys/fuel resources expect), but every state change — stored
-- vs out, who owns it, how many bays are free — is decided here.
-- ─────────────────────────────────────────────────────────────
Garage = {}

local function slots(gangId)
    return Config.Garage.baseSlots + Gangs.Modifiers(gangId).garageSlotsBonus
end
Garage.Slots = slots

local function countVehicles(gangId)
    return MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_vehicles WHERE gang_id = ?', { gangId }) or 0
end

-- Short, unique, obviously-gang plate. GTA caps plates at 8 characters.
local function generatePlate(gangId)
    local prefix = (Config.Garage.platePrefix or 'XS'):upper():sub(1, 3)
    for _ = 1, 40 do
        local plate = ('%s%02d%03d'):format(prefix, gangId % 100, math.random(0, 999))
        plate = plate:sub(1, 8)
        local taken = MySQL.scalar.await('SELECT 1 FROM xs_gang_vehicles WHERE plate = ?', { plate })
        if not taken then return plate end
    end
    return nil
end

-- The garage point has to actually exist before anything can use it.
local function garagePoint(gangId)
    return Placeables.CoordsFor(gangId, 'garage')
end
Garage.Point = garagePoint

local function nearGarage(src, gangId)
    local point = garagePoint(gangId)
    if not point then return false, 'your crew has not placed a garage point yet' end
    local pos = GetEntityCoords(GetPlayerPed(src))
    if #(pos - point) > Config.Garage.spawnRadius then return false, 'go to your gang garage first' end
    return true
end

function Garage.List(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return { vehicles = {} } end

    local vehicles = MySQL.query.await(
        'SELECT id, model, label, plate, stored, added_by, created_at FROM xs_gang_vehicles WHERE gang_id = ? ORDER BY id',
        { gang.id }) or {}

    local point = garagePoint(gang.id)
    return {
        vehicles = vehicles,
        slots = slots(gang.id),
        used = #vehicles,
        point = point and { x = point.x, y = point.y, z = point.z } or nil,
        canTake = Gangs.HasPerm(src, 'garage_take'),
        canStore = Gangs.HasPerm(src, 'garage_store'),
        canDelete = Gangs.HasPerm(src, 'garage_delete'),
        spawnRadius = Config.Garage.spawnRadius,
    }
end

-- Add the vehicle the player is sitting in to the gang pool. `props` is
-- ox_lib's vehicle property table, captured client-side.
function Garage.Store(src, model, label, props, plate)
    if not Gangs.HasPerm(src, 'garage_store') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local ok, err = nearGarage(src, gang.id)
    if not ok then return false, err end

    model = tostring(model or ''):lower()
    if model == '' then return false, 'unknown vehicle' end

    -- Already one of ours? Just put it back rather than creating a twin.
    if plate and plate ~= '' then
        local existing = MySQL.single.await('SELECT id, gang_id FROM xs_gang_vehicles WHERE plate = ?', { plate })
        if existing then
            if existing.gang_id ~= gang.id then return false, 'that vehicle belongs to another crew' end
            MySQL.update('UPDATE xs_gang_vehicles SET stored = 1, props = ? WHERE id = ?',
                { props and json.encode(props) or nil, existing.id })
            Gangs.Log(gang.id, ('%s stored %s'):format(Framework.GetName(src) or 'Someone', label or model), 'garage')
            Gangs.Broadcast(gang.id, 'garage', {})
            return true, plate
        end
    end

    if countVehicles(gang.id) >= slots(gang.id) then
        return false, 'the garage is full — buy a Garage Expansion'
    end

    local newPlate = generatePlate(gang.id)
    if not newPlate then return false, 'could not issue a plate' end

    MySQL.insert.await(
        'INSERT INTO xs_gang_vehicles (gang_id, model, label, plate, props, stored, added_by) VALUES (?, ?, ?, ?, ?, 1, ?)',
        { gang.id, model, label or model, newPlate, props and json.encode(props) or nil,
          Framework.GetCitizenId(src) or '' })

    Gangs.Log(gang.id, ('%s added %s (%s) to the garage'):format(
        Framework.GetName(src) or 'Someone', label or model, newPlate), 'garage')
    Gangs.Broadcast(gang.id, 'garage', {})
    return true, newPlate
end

-- Marks a vehicle as out and hands the client everything it needs to
-- spawn it. The client does the spawning; the DB owns the state.
function Garage.Take(src, vehicleId)
    if not Gangs.HasPerm(src, 'garage_take') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local ok, err = nearGarage(src, gang.id)
    if not ok then return false, err end

    local row = MySQL.single.await('SELECT * FROM xs_gang_vehicles WHERE id = ? AND gang_id = ?',
        { tonumber(vehicleId), gang.id })
    if not row then return false, 'not one of yours' end
    if row.stored == 0 then return false, 'that one is already out' end

    MySQL.update('UPDATE xs_gang_vehicles SET stored = 0 WHERE id = ?', { row.id })

    local point = garagePoint(gang.id)
    Gangs.Log(gang.id, ('%s took out %s (%s)'):format(
        Framework.GetName(src) or 'Someone', row.label, row.plate), 'garage')
    Gangs.Broadcast(gang.id, 'garage', {})

    return true, {
        id = row.id,
        model = row.model,
        label = row.label,
        plate = row.plate,
        props = row.props and json.decode(row.props) or nil,
        spawn = { x = point.x, y = point.y, z = point.z },
        giveKeys = Config.Garage.giveKeys,
    }
end

function Garage.Delete(src, vehicleId)
    if not Gangs.HasPerm(src, 'garage_delete') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local row = MySQL.single.await('SELECT * FROM xs_gang_vehicles WHERE id = ? AND gang_id = ?',
        { tonumber(vehicleId), gang.id })
    if not row then return false, 'not one of yours' end

    MySQL.update('DELETE FROM xs_gang_vehicles WHERE id = ?', { row.id })
    Gangs.Log(gang.id, ('%s scrapped %s (%s)'):format(
        Framework.GetName(src) or 'Someone', row.label, row.plate), 'garage')
    Gangs.Broadcast(gang.id, 'garage', {})
    return true
end

-- ── admin ───────────────────────────────────────────────────
function Garage.AdminGrant(gangId, model, label)
    local gang = Gangs.Get(gangId)
    if not gang then return false, 'unknown gang' end
    if countVehicles(gangId) >= slots(gangId) then return false, 'that garage is full' end

    local plate = generatePlate(gangId)
    if not plate then return false, 'could not issue a plate' end

    MySQL.insert.await(
        'INSERT INTO xs_gang_vehicles (gang_id, model, label, plate, stored, added_by) VALUES (?, ?, ?, ?, 1, ?)',
        { gangId, tostring(model):lower(), label or model, plate, 'admin' })
    Gangs.Log(gangId, ('An admin granted %s (%s)'):format(label or model, plate), 'garage')
    Gangs.Broadcast(gangId, 'garage', {})
    return true, plate
end

function Garage.AdminList(gangId)
    return MySQL.query.await(
        'SELECT id, model, label, plate, stored FROM xs_gang_vehicles WHERE gang_id = ? ORDER BY id',
        { tonumber(gangId) }) or {}
end

function Garage.AdminDelete(vehicleId)
    local row = MySQL.single.await('SELECT gang_id, label, plate FROM xs_gang_vehicles WHERE id = ?', { tonumber(vehicleId) })
    if not row then return false, 'unknown vehicle' end
    MySQL.update('DELETE FROM xs_gang_vehicles WHERE id = ?', { tonumber(vehicleId) })
    Gangs.Log(row.gang_id, ('An admin removed %s (%s)'):format(row.label, row.plate), 'garage')
    Gangs.Broadcast(row.gang_id, 'garage', {})
    return true
end

-- ── callbacks ───────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:garage:list', function(src)
    return Garage.List(src)
end)

lib.callback.register('XS-CriminalTablet:garage:store', function(src, model, label, props, plate)
    local ok, res = Garage.Store(src, model, label, props, plate)
    return { ok = ok, error = not ok and res or nil, plate = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:garage:take', function(src, vehicleId)
    local ok, res = Garage.Take(src, vehicleId)
    return { ok = ok, error = not ok and res or nil, vehicle = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:garage:delete', function(src, vehicleId)
    local ok, err = Garage.Delete(src, vehicleId)
    return { ok = ok, error = err }
end)

-- The client reports a vehicle it just put away so the row flips back to
-- stored even when it was parked rather than stored from the tablet.
RegisterNetEvent('XS-CriminalTablet:server:garageReturned', function(plate, props)
    local src = source
    local gang = Gangs.GetBySource(src)
    if not gang or not plate then return end
    local row = MySQL.single.await('SELECT id FROM xs_gang_vehicles WHERE plate = ? AND gang_id = ?', { plate, gang.id })
    if not row then return end
    MySQL.update('UPDATE xs_gang_vehicles SET stored = 1, props = ? WHERE id = ?',
        { props and json.encode(props) or nil, row.id })
    Gangs.Broadcast(gang.id, 'garage', {})
end)
