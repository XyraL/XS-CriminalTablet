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

local function groundAt(x, y, z)
    for _, lift in ipairs({ 1.5, 4.0, 10.0 }) do
        local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + lift, false)
        if found then return gz end
    end
    return z
end

-- A free patch of ground beside the garage point, never on it: the point
-- is a solid prop, and a car spawned inside one gets thrown onto its roof.
-- Two people pulling cars out at once don't stack them either.
local function findSpawnSpot(base, heading)
    local h = math.rad(heading)
    local fwd = vec3(-math.sin(h), math.cos(h), 0.0)
    local right = vec3(fwd.y, -fwd.x, 0.0)
    local offsets = {
        fwd * 4.5, fwd * 4.5 + right * 3.5, fwd * 4.5 - right * 3.5,
        right * 4.5, right * -4.5, fwd * -4.5, fwd * 9.0,
    }
    for _, off in ipairs(offsets) do
        local spot = base + off
        if not IsPositionOccupied(spot.x, spot.y, spot.z + 0.5, 2.2, false, true, true, false, false, 0, false) then
            return vec3(spot.x, spot.y, groundAt(spot.x, spot.y, spot.z))
        end
    end
    local spot = base + fwd * 4.5
    return vec3(spot.x, spot.y, groundAt(spot.x, spot.y, spot.z))
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
        TriggerServerEvent('XS-CriminalTablet:server:garageReturned', v.plate, v.props)
        return false
    end

    if not XSModel.Load(model) then
        lib.notify({ description = ('%s would not load — try again.'):format(v.label), type = 'error' })
        TriggerServerEvent('XS-CriminalTablet:server:garageReturned', v.plate, v.props)
        return false
    end
    local heading = (tonumber(v.spawn.heading) or GetEntityHeading(PlayerPedId())) + 0.0
    local spot = findSpawnSpot(vec3(v.spawn.x + 0.0, v.spawn.y + 0.0, v.spawn.z + 0.0), heading)

    RequestCollisionAtCoord(spot.x, spot.y, spot.z)
    local vehicle = CreateVehicle(model, spot.x, spot.y, spot.z + 0.5, heading, true, false)
    for _ = 1, 40 do
        if HasCollisionLoadedAroundEntity(vehicle) then break end
        Wait(25)
    end
    SetEntityHeading(vehicle, heading)
    SetVehicleOnGroundProperly(vehicle)
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleHasBeenOwnedByPlayer(vehicle, true)
    SetModelAsNoLongerNeeded(model)

    if v.props then pcall(function() lib.setVehicleProperties(vehicle, v.props) end) end
    -- Properties carry the saved plate too; re-apply ours so the DB row
    -- and the car on the street can never disagree.
    SetVehicleNumberPlateText(vehicle, v.plate)
    SetVehicleDoorsLocked(vehicle, 1)

    if Config.Garage.warpIn ~= false then TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1) end
    if v.giveKeys then
        for _ = 1, 40 do
            if NetworkGetEntityIsNetworked(vehicle) then break end
            Wait(25)
        end
        TriggerServerEvent('XS-CriminalTablet:server:garageKeys', NetworkGetNetworkIdFromEntity(vehicle), v.plate)
    end
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
