-- ─────────────────────────────────────────────────────────────
-- Gang garage client: pulls a gang vehicle out at the placed garage
-- point, and puts one back.
--
-- The server owns the state (which vehicles exist, who may touch them,
-- how many bays are free). This file only does the spawning, because the
-- vehicle has to inherit whatever your server's keys and fuel resources
-- expect from a normally-spawned car.
-- ─────────────────────────────────────────────────────────────
GangGarage = {}

local outVehicles = {}   -- [plate] = entity, so we know what we put out

-- Hand keys over through whichever key resource is running. Anything
-- unrecognised is a no-op and the vehicle just stays unlocked.
local function giveKeys(vehicle, plate)
    SetVehicleDoorsLocked(vehicle, 1)

    if GetResourceState('qbx_vehiclekeys') == 'started' then
        pcall(function() exports.qbx_vehiclekeys:GiveKeys(vehicle, true) end)
    elseif GetResourceState('qb-vehiclekeys') == 'started' then
        pcall(function() TriggerEvent('qb-vehiclekeys:client:AddKeys', plate) end)
    elseif GetResourceState('wasabi_carlock') == 'started' then
        pcall(function() exports.wasabi_carlock:GiveKey(plate) end)
    end
end

-- A free patch of ground near the garage point, so two people pulling
-- cars out at once don't stack them inside each other.
local function findSpawnSpot(base)
    local offsets = {
        vec3(0.0, 0.0, 0.0), vec3(4.0, 0.0, 0.0), vec3(-4.0, 0.0, 0.0),
        vec3(0.0, 4.0, 0.0), vec3(0.0, -4.0, 0.0), vec3(4.0, 4.0, 0.0), vec3(-4.0, -4.0, 0.0),
    }
    for _, off in ipairs(offsets) do
        local spot = base + off
        if IsPositionOccupied(spot.x, spot.y, spot.z, 2.5, false, true, false, false, false, 0, false) == false then
            return spot
        end
    end
    return base
end

function GangGarage.Take(vehicleId)
    local res = lib.callback.await('XS-CriminalTablet:garage:take', false, vehicleId)
    if not res or not res.ok then
        lib.notify({ description = (res and res.error) or 'Could not take that out', type = 'error' })
        return false
    end

    local v = res.vehicle
    local model = joaat(v.model)
    if not IsModelInCdimage(model) then
        lib.notify({ description = ('That model (%s) is not on this server.'):format(v.model), type = 'error' })
        return false
    end

    lib.requestModel(model)
    local base = vec3(v.spawn.x, v.spawn.y, v.spawn.z)
    local spot = findSpawnSpot(base)

    local vehicle = CreateVehicle(model, spot.x, spot.y, spot.z, GetEntityHeading(PlayerPedId()) + 90.0, true, false)
    SetVehicleNumberPlateText(vehicle, v.plate)
    SetVehicleOnGroundProperly(vehicle)
    SetEntityAsMissionEntity(vehicle, true, true)
    SetModelAsNoLongerNeeded(model)

    if v.props then pcall(function() lib.setVehicleProperties(vehicle, v.props) end) end
    -- Properties carry the saved plate too; re-apply ours so the DB row
    -- and the car on the street can never disagree.
    SetVehicleNumberPlateText(vehicle, v.plate)

    if v.giveKeys then giveKeys(vehicle, v.plate) end
    outVehicles[v.plate] = vehicle

    lib.notify({ description = ('%s is out — plate %s.'):format(v.label, v.plate), type = 'success' })
    return true
end

-- Put back whatever the player is currently sitting in.
function GangGarage.StoreCurrent()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        lib.notify({ description = 'Get in the vehicle first.', type = 'error' })
        return false
    end
    if GetPedInVehicleSeat(vehicle, -1) ~= ped then
        lib.notify({ description = 'You have to be the driver.', type = 'error' })
        return false
    end

    local model = GetEntityModel(vehicle)
    local modelName = string.lower(GetDisplayNameFromVehicleModel(model))
    local label = GetLabelText(GetDisplayNameFromVehicleModel(model))
    if label == 'NULL' or label == '' then label = modelName end
    local plate = (GetVehicleNumberPlateText(vehicle) or ''):gsub('%s+$', '')

    local props
    pcall(function() props = lib.getVehicleProperties(vehicle) end)

    local res = lib.callback.await('XS-CriminalTablet:garage:store', false, modelName, label, props, plate)
    if not res or not res.ok then
        lib.notify({ description = (res and res.error) or 'Could not store that', type = 'error' })
        return false
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    DeleteVehicle(vehicle)
    outVehicles[res.plate or plate] = nil

    lib.notify({ description = ('Stored — plate %s.'):format(res.plate or plate), type = 'success' })
    return true
end

-- Anything we pulled out and then parked back at the point gets flipped
-- to stored automatically, so the bay isn't held open forever.
CreateThread(function()
    while true do
        Wait(15000)
        for plate, vehicle in pairs(outVehicles) do
            if not DoesEntityExist(vehicle) then outVehicles[plate] = nil end
        end
    end
end)

RegisterNetEvent('XS-CriminalTablet:client:openGarage', function()
    TriggerEvent('XS-CriminalTablet:client:openDeviceAt', 'garage')
end)

RegisterNetEvent('XS-CriminalTablet:client:garageTake', function(vehicleId)
    GangGarage.Take(vehicleId)
end)

RegisterNetEvent('XS-CriminalTablet:client:garageStore', function()
    GangGarage.StoreCurrent()
end)
