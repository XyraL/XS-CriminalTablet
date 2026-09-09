-- ─────────────────────────────────────────────────────────────
-- Car boosting client. The target vehicle, its guards and the buyer ped
-- are spawned by whichever crew member reaches them first — the server
-- hands out one claim per thing so nothing is spawned twice — and every
-- crew member can hotwire or sell. qbx_core's own vehicle break-in system
-- handles the actual theft; we just watch for the engine to start.
-- ─────────────────────────────────────────────────────────────
local hasTarget = GetResourceState('ox_target') == 'started'
local BUYER_SPAWN_RADIUS = 120.0

local jobToken = 0
local stage = nil
local taskBlip = nil
local dropoffMarkerBlip = nil
local boostVehicleNetId = nil
local buyerNetId = nil
local guardPeds = {}
local sellTargetEntity = nil
local sellRegistered = false
local fallbackPrompt = nil

local function entityFromNetId(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent == 0 or not DoesEntityExist(ent) then return nil end
    return ent
end

local function playerDist(v)
    return #(GetEntityCoords(PlayerPedId()) - vec3(v.x, v.y, v.z))
end

local function deleteNetworked(ent)
    if not ent or not DoesEntityExist(ent) then return end
    if not NetworkHasControlOfEntity(ent) then
        NetworkRequestControlOfEntity(ent)
        local tries = 0
        while not NetworkHasControlOfEntity(ent) and tries < 20 do Wait(50); tries = tries + 1 end
    end
    SetEntityAsMissionEntity(ent, true, true)
    DeleteEntity(ent)
end

local function clearBlips()
    if taskBlip then RemoveBlip(taskBlip); taskBlip = nil end
    if dropoffMarkerBlip then RemoveBlip(dropoffMarkerBlip); dropoffMarkerBlip = nil end
end

local function clearPrompt()
    if fallbackPrompt then lib.hideTextUI(); fallbackPrompt = nil end
end

local function clearGuards()
    for _, ped in ipairs(guardPeds) do deleteNetworked(ped) end
    guardPeds = {}
end

local function clearSell()
    if sellTargetEntity then
        pcall(function() exports.ox_target:removeLocalEntity(sellTargetEntity, 'xs_sell_boost') end)
    end
    sellTargetEntity = nil
    sellRegistered = false
    clearPrompt()
end

local function clearAll()
    jobToken = jobToken + 1
    stage = nil
    clearBlips()
    clearGuards()
    clearSell()
    deleteNetworked(entityFromNetId(buyerNetId))
    buyerNetId = nil
    deleteNetworked(entityFromNetId(boostVehicleNetId))
    boostVehicleNetId = nil
end

-- Armed and hostile to every player — the crew fights them off together.
local function spawnGuards(spawn, def)
    if not def or not IsModelValid(def.model) then return end
    lib.requestModel(def.model)

    AddRelationshipGroup('xs_boostguard')
    local hostileGroup = GetHashKey('xs_boostguard')
    SetRelationshipBetweenGroups(5, hostileGroup, `PLAYER`)
    SetRelationshipBetweenGroups(5, `PLAYER`, hostileGroup)

    local count = def.count or 2
    for i = 1, count do
        local angle = (i / count) * 2 * math.pi
        local offset = (def.radius or 6.0)
        local x = spawn.x + math.cos(angle) * offset
        local y = spawn.y + math.sin(angle) * offset
        local ped = CreatePed(4, def.model, x, y, spawn.z, 0.0, true, true)
        SetPedRelationshipGroupHash(ped, hostileGroup)
        GiveWeaponToPed(ped, GetHashKey(def.weapon or 'WEAPON_PISTOL'), 250, false, true)
        SetPedCombatAttributes(ped, 46, true)
        SetPedCombatAttributes(ped, 5, true)
        SetPedFleeAttributes(ped, 0, false)
        SetPedSeeingRange(ped, 60.0)
        SetPedHearingRange(ped, 60.0)
        TaskCombatPed(ped, PlayerPedId(), 0, 16)
        guardPeds[#guardPeds + 1] = ped
    end
end

-- Proximity+[E] fallback when ox_target isn't handling the sell prompt.
CreateThread(function()
    local shown = false
    while true do
        Wait(300)
        if fallbackPrompt then
            local near = #(GetEntityCoords(PlayerPedId()) - fallbackPrompt.coords) <= 2.0
            if near then
                if not shown then lib.showTextUI('[E] ' .. fallbackPrompt.label); shown = true end
                if IsControlJustReleased(0, 38) then fallbackPrompt.action() end
            elseif shown then
                lib.hideTextUI(); shown = false
            end
        elseif shown then
            lib.hideTextUI(); shown = false
        end
    end
end)

local function fireDispatch(coords)
    local d = Config.Boosting.dispatch
    if not d.enabled then return end
    local ok, payload = pcall(d.buildPayload, coords)
    if ok then TriggerEvent(d.event, payload) end
end

-- Spawns the target locked with no keys and holds it in place until the
-- ground around it has streamed in, so a car spawned at the edge of the
-- zone doesn't drop through the map.
local function spawnTargetVehicle(spawn, model, plate)
    if not IsModelValid(model) then
        lib.notify({ description = ('Bad vehicle model for this job (%s) — tell an admin to fix config.lua'):format(model), type = 'error' })
        return nil
    end
    lib.requestModel(model)
    RequestCollisionAtCoord(spawn.x, spawn.y, spawn.z)
    local veh = CreateVehicle(model, spawn.x, spawn.y, spawn.z, spawn.w, true, true)
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleNumberPlateText(veh, plate or ('BST%04d'):format(math.random(0, 9999)))
    SetVehicleDoorsLocked(veh, 2)
    SetVehicleEngineOn(veh, false, true, true)
    FreezeEntityPosition(veh, true)
    CreateThread(function()
        local waited = 0
        while DoesEntityExist(veh) and not HasCollisionLoadedAroundEntity(veh) and waited < 8000 do
            Wait(100); waited = waited + 100
        end
        if DoesEntityExist(veh) then
            FreezeEntityPosition(veh, false)
            SetVehicleOnGroundProperly(veh)
        end
    end)
    return NetworkGetNetworkIdFromEntity(veh)
end

local function spawnBuyerPed(coords, model)
    if not IsModelValid(model) then
        lib.notify({ description = ('Bad buyer ped model (%s) — tell an admin to fix config.lua'):format(model), type = 'error' })
        return nil
    end
    lib.requestModel(model)
    local ped = CreatePed(4, model, coords.x, coords.y, coords.z, coords.w or 0.0, true, true)
    SetEntityAsMissionEntity(ped, true, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
    return NetworkGetNetworkIdFromEntity(ped)
end

local function doSellVehicle()
    if not boostVehicleNetId then return end
    local res = lib.callback.await('XS-CriminalTablet:boosting:doDropoff', false, boostVehicleNetId)
    if res and not res.ok then
        lib.notify({ description = res.error or 'Failed', type = 'error' })
    end
end

local function registerSell(ped, coords)
    sellRegistered = true
    sellTargetEntity = ped
    local zoneOk = false
    if hasTarget then
        zoneOk = pcall(function()
            exports.ox_target:addLocalEntity(ped, {
                { name = 'xs_sell_boost', label = 'Sell Vehicle', icon = 'fas fa-money-bill-wave',
                  onSelect = doSellVehicle },
            })
        end)
    end
    if not zoneOk then
        fallbackPrompt = { coords = vec3(coords.x, coords.y, coords.z), label = 'Sell Vehicle', action = doSellVehicle }
    end
end

local function theftLoop(token, job)
    CreateThread(function()
        local claiming, guardsDone, hotwireSent = false, false, false
        while jobToken == token and stage == 'theft' do
            Wait(500)
            local d = playerDist(job.spawn)

            if not boostVehicleNetId and not claiming and d <= (job.spawnRadius or 300.0) then
                claiming = true
                local res = lib.callback.await('XS-CriminalTablet:boosting:claimVehicle', false)
                if jobToken ~= token then break end
                if res and res.ok then
                    local netId = spawnTargetVehicle(job.spawn, job.model, job.plate)
                    if netId then
                        boostVehicleNetId = netId
                        lib.callback.await('XS-CriminalTablet:boosting:registerVehicle', false, netId)
                    end
                elseif res and res.netId then
                    boostVehicleNetId = res.netId
                end
                claiming = false
            end

            local veh = entityFromNetId(boostVehicleNetId)
            if veh then
                if job.guards and not guardsDone and d <= (job.guardTriggerRadius or 20.0) then
                    guardsDone = true
                    local res = lib.callback.await('XS-CriminalTablet:boosting:claimGuards', false)
                    if jobToken ~= token then break end
                    if res and res.ok then spawnGuards(job.spawn, job.guards) end
                end
                if not hotwireSent and GetIsVehicleEngineRunning(veh) then
                    hotwireSent = true
                    local res = lib.callback.await('XS-CriminalTablet:boosting:doHotwire', false, boostVehicleNetId)
                    if res and res.ok then
                        local coords = GetEntityCoords(veh)
                        if job.dispatchDelay and job.dispatchDelay > 0 then
                            SetTimeout(job.dispatchDelay * 1000, function() fireDispatch(coords) end)
                        else
                            fireDispatch(coords)
                        end
                        lib.notify({ description = 'Stolen — get it to the buyer.', type = 'success' })
                    else
                        hotwireSent = false
                    end
                end
            end
        end
    end)
end

local function dropoffLoop(token, job)
    CreateThread(function()
        local claiming = false
        while jobToken == token and stage == 'dropoff' do
            Wait(500)
            if not buyerNetId and not claiming and playerDist(job.dropoff) <= BUYER_SPAWN_RADIUS then
                claiming = true
                local res = lib.callback.await('XS-CriminalTablet:boosting:claimBuyer', false)
                if jobToken ~= token then break end
                if res and res.ok then
                    local netId = spawnBuyerPed(job.dropoff, job.buyerPedModel or 'g_m_y_lost_01')
                    if netId then
                        buyerNetId = netId
                        lib.callback.await('XS-CriminalTablet:boosting:registerBuyer', false, netId)
                    end
                elseif res and res.netId then
                    buyerNetId = res.netId
                end
                claiming = false
            end
            if buyerNetId and not sellRegistered then
                local ped = entityFromNetId(buyerNetId)
                if ped then registerSell(ped, job.dropoff) end
            end
        end
    end)
end

RegisterNetEvent('XS-CriminalTablet:client:boostUpdate', function(job)
    if not job then
        clearAll()
        return
    end

    if job.stage == 'theft' then
        clearAll()
        stage = 'theft'
        local token = jobToken
        if job.coop and job.isLeader == false then
            lib.notify({ description = 'Crew job started — find the target and help fight off the guards.', type = 'inform' })
        end
        -- No exact waypoint — just a search-zone circle. The model/plate
        -- BOLO clue shows in the tablet's active-job status instead.
        taskBlip = AddBlipForRadius(job.spawn.x, job.spawn.y, job.spawn.z, job.searchRadius or 250.0)
        SetBlipColour(taskBlip, 5)
        SetBlipAlpha(taskBlip, 130)
        theftLoop(token, job)
    elseif job.stage == 'dropoff' then
        clearBlips()
        clearGuards()
        clearSell()
        stage = 'dropoff'
        jobToken = jobToken + 1
        local token = jobToken
        if job.vehicleNetId then boostVehicleNetId = job.vehicleNetId end

        taskBlip = AddBlipForRadius(job.dropoff.x, job.dropoff.y, job.dropoff.z, job.dropoffRadius or 15.0)
        SetBlipColour(taskBlip, 2)
        SetBlipAlpha(taskBlip, 130)

        dropoffMarkerBlip = AddBlipForCoord(job.dropoff.x, job.dropoff.y, job.dropoff.z)
        SetBlipSprite(dropoffMarkerBlip, 67)
        SetBlipColour(dropoffMarkerBlip, 2)
        SetBlipRoute(dropoffMarkerBlip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString('Sell the Vehicle')
        EndTextCommandSetBlipName(dropoffMarkerBlip)
        dropoffLoop(token, job)
    end
end)

RegisterNetEvent('XS-CriminalTablet:client:boostVehicle', function(data)
    if stage and data and data.netId then boostVehicleNetId = data.netId end
end)

RegisterNetEvent('XS-CriminalTablet:client:boostBuyer', function(data)
    if stage == 'dropoff' and data and data.netId then buyerNetId = data.netId end
end)

RegisterNetEvent('XS-CriminalTablet:client:coopInvite', function(info)
    Device.PromptInvite('boost', 'Co-op Boosting Invite', info.fromName, 'wants you to crew up on a boosting job')
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearAll() end
end)
