-- ─────────────────────────────────────────────────────────────
-- Client init + invite handling.
-- ─────────────────────────────────────────────────────────────
CreateThread(function()
    while not LocalPlayer.state.isLoggedIn and not (Framework and Framework.name) do Wait(250) end
    if Config.Debug then print('^2[XS-CriminalTablet]^0 client ready') end
end)

-- ox_inventory client-side usable item: item.client.export = 'XS-CriminalTablet.useDevice'
exports('useDevice', function(data, slot)
    TriggerEvent('XS-CriminalTablet:client:openDevice')
end)

-- ── friendly-fire report ──
-- Self-reports our own death + whoever killed us, so the server can dock
-- the killer's rep if we're both in the same gang. Debounced so it only
-- fires once per actual death, not on every tick while dead.
CreateThread(function()
    local wasDead = false
    while true do
        Wait(500)
        local ped = PlayerPedId()
        local dead = IsEntityDead(ped)
        if dead and not wasDead then
            local killer = GetPedSourceOfDeath(ped)
            if killer and killer ~= 0 and IsPedAPlayer(killer) and killer ~= ped then
                local killerPlayer = NetworkGetPlayerIndexFromPed(killer)
                if killerPlayer and killerPlayer ~= -1 then
                    TriggerServerEvent('XS-CriminalTablet:server:reportGangKill', GetPlayerServerId(killerPlayer))
                end
            end
        end
        wasDead = dead
    end
end)

-- ── task blip / carry prop / kill target / pickup+dropoff / escort / heist ──
-- Server is the sole authority on stage/completion; this just shows
-- where to go, runs the actual target interactions, and handles purely
-- visual flavor (carried prop, spawned NPCs) for whatever the server says
-- the job currently is. For co-op jobs, only the crew leader's client ever
-- spawns an entity (killPed/escortPed/dropoffPed) — every crew member's
-- client independently runs this same handler, so spawning unconditionally
-- would create duplicate networked peds.
local hasTarget = GetResourceState('ox_target') == 'started'
local taskBlip = nil
local carryProp = nil
local killPed = nil
local killThread = false
local pickupZoneId = nil
local dropoffPed = nil
local escortPed = nil
local escortThread = false
local heistZoneId = nil
local courierVan = nil
local courierZoneId = nil
local courierAmbushPeds = {}
local quartermasterPed = nil
local ambushRolled = false
local fallbackPrompt = nil -- { coords, label, action } when ox_target isn't handling the current step

local function clearTaskBlip()
    if taskBlip then RemoveBlip(taskBlip); taskBlip = nil end
end

local function clearCarryProp()
    if carryProp then DeleteEntity(carryProp); carryProp = nil end
end

local function clearKillPed()
    if killPed then DeleteEntity(killPed); killPed = nil end
end

local function clearPickupZone()
    if pickupZoneId then
        pcall(function() exports.ox_target:removeZone(pickupZoneId) end)
        pickupZoneId = nil
    end
end

local function clearDropoffPed()
    if dropoffPed then DeleteEntity(dropoffPed); dropoffPed = nil end
end

local function clearEscortPed()
    if escortPed then DeleteEntity(escortPed); escortPed = nil end
end

local function clearHeistZone()
    if heistZoneId then
        pcall(function() exports.ox_target:removeZone(heistZoneId) end)
        heistZoneId = nil
    end
end

local function clearCourierAmbush()
    for _, p in ipairs(courierAmbushPeds) do
        if DoesEntityExist(p) then DeleteEntity(p) end
    end
    courierAmbushPeds = {}
end

local function clearCourierVan()
    clearCourierAmbush()
    if courierVan then DeleteEntity(courierVan); courierVan = nil end
end

local function clearCourierZone()
    if courierZoneId then
        pcall(function() exports.ox_target:removeZone(courierZoneId) end)
        courierZoneId = nil
    end
end

local function clearQuartermaster()
    if quartermasterPed then DeleteEntity(quartermasterPed); quartermasterPed = nil end
end

local function clearFallbackPrompt()
    if fallbackPrompt then lib.hideTextUI(); fallbackPrompt = nil end
end

local function clearAllTaskVisuals()
    clearCarryProp()
    clearKillPed()
    clearPickupZone()
    clearDropoffPed()
    clearEscortPed()
    clearHeistZone()
    clearCourierVan()
    clearCourierZone()
    clearQuartermaster()
    clearFallbackPrompt()
    ambushRolled = false
end

-- PlaceEntityOnGroundProperly isn't registered as a Lua global on every
-- build — falls back to a manual GetGroundZFor_3dCoord snap so a missing
-- native can't crash the spawn.
local function snapToGround(entity)
    if not entity or entity == 0 then return end
    local ok = pcall(function() PlaceEntityOnGroundProperly(entity, true) end)
    if ok then return end
    local coords = GetEntityCoords(entity)
    local found, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 5.0, false)
    if found then
        SetEntityCoords(entity, coords.x, coords.y, groundZ + 0.02, false, false, false, true)
    end
end

-- Single proximity+[E] loop backing whichever interaction ox_target isn't
-- covering right now (no ox_target installed, or the zone/target call failed).
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

local function attachCarryProp(model)
    clearCarryProp()
    if not model or not IsModelValid(model) then return end
    lib.requestModel(model)
    local ped = PlayerPedId()
    carryProp = CreateObject(model, 0.0, 0.0, 0.0, true, true, false)
    AttachEntityToEntity(carryProp, ped, GetPedBoneIndex(ped, 28422), 0.1, 0.02, 0.0, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
end

local function spawnKillTarget(spawn, model, weapon, isLeader)
    clearKillPed()
    if isLeader == false then
        taskBlip = AddBlipForCoord(spawn.x, spawn.y, spawn.z)
        SetBlipSprite(taskBlip, 84)
        SetBlipColour(taskBlip, 1)
        SetBlipRoute(taskBlip, true)
        return
    end
    if not IsModelValid(model) then
        lib.notify({ description = ('Bad ped model for this task (%s) — tell an admin to fix config.lua'):format(model), type = 'error' })
        return
    end
    lib.requestModel(model)
    killPed = CreatePed(4, model, spawn.x, spawn.y, spawn.z, 0.0, true, true)
    snapToGround(killPed)

    AddRelationshipGroup('xs_hitcontract')
    local hostileGroup = GetHashKey('xs_hitcontract')
    SetRelationshipBetweenGroups(5, hostileGroup, `PLAYER`) -- 5 = hate
    SetRelationshipBetweenGroups(5, `PLAYER`, hostileGroup)
    SetPedRelationshipGroupHash(killPed, hostileGroup)

    GiveWeaponToPed(killPed, GetHashKey(weapon or 'WEAPON_PISTOL'), 250, false, true)
    SetPedCombatAttributes(killPed, 46, true) -- can fight armed peds while unarmed
    SetPedCombatAttributes(killPed, 5, true)  -- always fight
    SetPedFleeAttributes(killPed, 0, false)
    SetPedSeeingRange(killPed, 100.0)
    SetPedHearingRange(killPed, 100.0)
    TaskCombatPed(killPed, PlayerPedId(), 0, 16)

    taskBlip = AddBlipForEntity(killPed)
    SetBlipSprite(taskBlip, 84)
    SetBlipColour(taskBlip, 1)
    SetBlipRoute(taskBlip, true)

    if killThread then return end
    killThread = true
    CreateThread(function()
        while killPed do
            Wait(1000)
            if not killPed then break end
            if not DoesEntityExist(killPed) or IsEntityDead(killPed) then
                local res = lib.callback.await('XS-CriminalTablet:tasks:reportKill', false)
                if res and res.ok then
                    lib.notify({ description = 'Target eliminated.', type = 'success' })
                end
                break
            end
        end
        killThread = false
    end)
end

local function doPickup()
    local res = lib.callback.await('XS-CriminalTablet:tasks:doPickup', false)
    if res and not res.ok then lib.notify({ description = res.error or 'Failed', type = 'error' }) end
end

local function doDropoff()
    local res = lib.callback.await('XS-CriminalTablet:tasks:doDropoff', false)
    if res and not res.ok then lib.notify({ description = res.error or 'Failed', type = 'error' }) end
end

local function setupPickupTarget(coords)
    clearPickupZone()
    clearFallbackPrompt()
    local zoneOk = false
    if hasTarget then
        local ok, id = pcall(function()
            return exports.ox_target:addSphereZone({
                coords = coords, radius = 1.2, debug = false,
                options = {
                    { name = 'xs_pickup_task', label = 'Pick up Package', icon = 'fas fa-box',
                      onSelect = doPickup },
                },
            })
        end)
        if ok and id then pickupZoneId = id; zoneOk = true end
    end
    if not zoneOk then
        fallbackPrompt = { coords = coords, label = 'Pick up Package', action = doPickup }
    end
end

local function spawnEscort(spawn, destination, model, radius, isLeader)
    clearEscortPed()
    if isLeader == false then
        taskBlip = AddBlipForCoord(destination.x, destination.y, destination.z)
        SetBlipSprite(taskBlip, 280)
        SetBlipColour(taskBlip, 5)
        SetBlipRoute(taskBlip, true)
        return
    end
    if not IsModelValid(model) then
        lib.notify({ description = ('Bad escort ped model (%s) — tell an admin to fix config.lua'):format(model), type = 'error' })
        return
    end
    lib.requestModel(model)
    escortPed = CreatePed(4, model, spawn.x, spawn.y, spawn.z, 0.0, true, true)
    snapToGround(escortPed)
    SetBlockingOfNonTemporaryEvents(escortPed, true)
    SetPedCanRagdoll(escortPed, true)

    local ped = PlayerPedId()
    TaskFollowToOffsetOfEntity(escortPed, ped, ped, 0.0, -1.5, 0.0, 1.0, -1, 2.0, true)

    taskBlip = AddBlipForCoord(destination.x, destination.y, destination.z)
    SetBlipSprite(taskBlip, 280)
    SetBlipColour(taskBlip, 5)
    SetBlipRoute(taskBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Escort destination')
    EndTextCommandSetBlipName(taskBlip)

    if escortThread then return end
    escortThread = true
    CreateThread(function()
        while escortPed do
            Wait(1000)
            if not escortPed then break end
            if not DoesEntityExist(escortPed) or IsEntityDead(escortPed) then
                lib.notify({ description = 'The escort was killed — job failed.', type = 'error' })
                lib.callback.await('XS-CriminalTablet:tasks:cancel', false)
                break
            end
            local playerCoords = GetEntityCoords(PlayerPedId())
            if #(playerCoords - destination) <= (radius or 5.0) and #(GetEntityCoords(escortPed) - destination) <= (radius or 5.0) + 3.0 then
                local res = lib.callback.await('XS-CriminalTablet:tasks:doEscortComplete', false)
                if res and res.ok then
                    lib.notify({ description = 'Escort delivered safely.', type = 'success' })
                elseif res and res.error then
                    lib.notify({ description = res.error, type = 'error' })
                end
                break
            end
        end
        escortThread = false
    end)
end

local function setupHeistTarget(coords, label, radius, onArrive)
    clearHeistZone()
    clearFallbackPrompt()
    local zoneOk = false
    if hasTarget then
        local ok, id = pcall(function()
            return exports.ox_target:addSphereZone({
                coords = coords, radius = radius or 2.5, debug = false,
                options = {
                    { name = 'xs_heist_stage', label = label, icon = 'fas fa-user-secret', onSelect = onArrive },
                },
            })
        end)
        if ok and id then heistZoneId = id; zoneOk = true end
    end
    if not zoneOk then
        fallbackPrompt = { coords = coords, label = label, action = onArrive }
    end
end

local function setupCourierTarget(coords, label, radius, onArrive)
    clearCourierZone()
    clearFallbackPrompt()
    local zoneOk = false
    if hasTarget then
        local ok, id = pcall(function()
            return exports.ox_target:addSphereZone({
                coords = coords, radius = radius or 6.0, debug = false,
                options = {
                    { name = 'xs_courier_stage', label = label, icon = 'fas fa-truck', onSelect = onArrive },
                },
            })
        end)
        if ok and id then courierZoneId = id; zoneOk = true end
    end
    if not zoneOk then
        fallbackPrompt = { coords = coords, label = label, action = onArrive }
    end
end

-- The actual "grab from the back of the van" interaction — anchored to
-- the van's boot bone, not a floating zone, so you have to be at the van
-- specifically rather than just standing anywhere near the dropoff coords.
local vanBackFallbackThread = false
local function setupVanBackTarget(van, label, onArrive)
    clearCourierZone()
    clearFallbackPrompt()
    if not van or not DoesEntityExist(van) then return end

    local zoneOk = false
    if hasTarget then
        local ok = pcall(function()
            exports.ox_target:addLocalEntity(van, {
                { name = 'xs_courier_boot', label = label, icon = 'fas fa-box-open',
                  bones = { 'boot' }, distance = 2.5, onSelect = onArrive },
            })
        end)
        zoneOk = ok
    end
    if zoneOk then return end

    -- No ox_target — poll the van's current (moving) rear offset instead of
    -- a fixed point, since the van isn't necessarily parked exactly on the
    -- dropoff coords.
    if vanBackFallbackThread then return end
    vanBackFallbackThread = true
    CreateThread(function()
        local shown = false
        while courierVan == van and DoesEntityExist(van) do
            Wait(300)
            local rear = GetOffsetFromEntityInWorldCoords(van, 0.0, -2.5, 0.0)
            local near = #(GetEntityCoords(PlayerPedId()) - rear) <= 2.0
            if near then
                if not shown then lib.showTextUI('[E] ' .. label); shown = true end
                if IsControlJustReleased(0, 38) then onArrive() end
            elseif shown then
                lib.hideTextUI(); shown = false
            end
        end
        if shown then lib.hideTextUI() end
        vanBackFallbackThread = false
    end)
end

-- Spawns the courier van for the job leader only (or solo). Followers just
-- see it physically — they don't need their own copy of the vehicle.
local function spawnCourierVan(vanSpawn, model, isLeader)
    clearCourierVan()
    if isLeader == false then return end
    if not vanSpawn then
        print('^1[XS-CriminalTablet]^0 spawnCourierVan: no vanSpawn coords in job payload')
        return
    end

    local hash = type(model) == 'string' and GetHashKey(model) or model
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        lib.notify({ description = ('Bad van model for this task (%s) — tell an admin to fix config.lua'):format(model), type = 'error' })
        print(('^1[XS-CriminalTablet]^0 spawnCourierVan: model "%s" (hash %s) is not a valid streamed model'):format(tostring(model), tostring(hash)))
        return
    end

    lib.requestModel(hash)
    courierVan = CreateVehicle(hash, vanSpawn.x, vanSpawn.y, vanSpawn.z, vanSpawn.w or 0.0, true, true)
    if not courierVan or courierVan == 0 then
        lib.notify({ description = 'Failed to spawn the delivery van — check the F8 console.', type = 'error' })
        print('^1[XS-CriminalTablet]^0 spawnCourierVan: CreateVehicle returned 0 — model likely failed to stream in time')
        courierVan = nil
        return
    end

    SetEntityAsMissionEntity(courierVan, true, true)
    SetVehicleOnGroundProperly(courierVan)
    SetVehicleHasBeenOwnedByPlayer(courierVan, true)
    SetVehicleNeedsToBeHotwired(courierVan, false)
    SetVehicleDoorsLocked(courierVan, 1)
    print(('^2[XS-CriminalTablet]^0 spawnCourierVan: spawned van entity %s at %s, %s, %s'):format(courierVan, vanSpawn.x, vanSpawn.y, vanSpawn.z))

    local netId = NetworkGetNetworkIdFromEntity(courierVan)
    lib.callback.await('XS-CriminalTablet:tasks:registerVan', false, netId)
end

-- Quartermaster ped standing at the van — talking to him is what "loads"
-- the package and actually starts the drive. Spawned once at pickup_van
-- and torn down the moment that stage finishes.
local function spawnQuartermaster(coords, model, isLeader, onTalk)
    clearQuartermaster()
    if isLeader == false then return end
    if not IsModelValid(model) then
        lib.notify({ description = ('Bad quartermaster model (%s) — tell an admin to fix config.lua'):format(model), type = 'error' })
        return
    end
    lib.requestModel(model)
    local offset = GetOffsetFromCoordInWorldCoords(coords.x, coords.y, coords.z, coords.w or 0.0, 1.5, 1.5, 0.0)
    quartermasterPed = CreatePed(4, model, offset.x, offset.y, coords.z, 0.0, true, true)
    snapToGround(quartermasterPed)
    SetEntityAsMissionEntity(quartermasterPed, true, true)
    SetEntityInvincible(quartermasterPed, true)
    SetBlockingOfNonTemporaryEvents(quartermasterPed, true)
    FreezeEntityPosition(quartermasterPed, true)
    TaskStartScenarioInPlace(quartermasterPed, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)

    local zoneOk = false
    if hasTarget then
        local ok = pcall(function()
            exports.ox_target:addLocalEntity(quartermasterPed, {
                { name = 'xs_courier_quartermaster', label = 'Get the Package', icon = 'fas fa-comments',
                  onSelect = onTalk },
            })
        end)
        zoneOk = ok
    end
    if not zoneOk then
        fallbackPrompt = { coords = vec3(offset.x, offset.y, coords.z), label = 'Get the Package', action = onTalk }
    end
end

-- Ambush is purely atmospheric flavor — server already rolled the chance
-- into ambushChance being non-zero on this job; surviving or losing the
-- fight doesn't gate completion, same trust level as Boosting's guards.
-- Framed as "they were already waiting near the dropoff" rather than a
-- random highway encounter: it triggers on proximity to the dropoff, with
-- a heads-up warning the moment it fires, never a blind sucker-punch.
local function maybeTriggerCourierAmbush(chance, dropoff)
    if ambushRolled or not chance or chance <= 0 or math.random(100) > chance then return end
    ambushRolled = true
    CreateThread(function()
        while courierVan and DoesEntityExist(courierVan) do
            Wait(1000)
            if not courierVan or not DoesEntityExist(courierVan) then return end
            if #(GetEntityCoords(PlayerPedId()) - dropoff) <= 60.0 then
                lib.notify({ description = "This van's hot — they spotted the package!", type = 'error', duration = 5000 })
                Wait(3500)
                if not courierVan or not DoesEntityExist(courierVan) then return end
                AddRelationshipGroup('xs_hitcontract')
                local hostileGroup = GetHashKey('xs_hitcontract')
                SetRelationshipBetweenGroups(5, hostileGroup, `PLAYER`)
                SetRelationshipBetweenGroups(5, `PLAYER`, hostileGroup)
                for i = 1, 2 do
                    local offset = GetOffsetFromEntityInWorldCoords(courierVan, math.random(-6, 6) + 0.0, math.random(-6, 6) + 0.0, 0.0)
                    local model = `g_m_y_lost_01`
                    lib.requestModel(model)
                    local hPed = CreatePed(4, model, offset.x, offset.y, offset.z, 0.0, true, true)
                    snapToGround(hPed)
                    SetPedRelationshipGroupHash(hPed, hostileGroup)
                    GiveWeaponToPed(hPed, GetHashKey('WEAPON_PISTOL'), 250, false, true)
                    SetPedCombatAttributes(hPed, 46, true)
                    SetPedCombatAttributes(hPed, 5, true)
                    SetPedFleeAttributes(hPed, 0, false)
                    TaskCombatPed(hPed, PlayerPedId(), 0, 16)
                    courierAmbushPeds[#courierAmbushPeds + 1] = hPed
                end
                return
            end
        end
    end)
end

-- Spawns the ped standing there, no interaction attached yet. Used for
-- the courier hand-off ped, spawned the moment the job starts (alongside
-- the van) so it's already waiting when the player arrives instead of
-- popping in on arrival.
local function spawnDropoffPedOnly(coords, model, isLeader)
    clearDropoffPed()
    if isLeader == false then return end
    if not IsModelValid(model) then
        lib.notify({ description = ('Bad dropoff ped model (%s) — tell an admin to fix config.lua'):format(model), type = 'error' })
        return
    end
    lib.requestModel(model)
    dropoffPed = CreatePed(4, model, coords.x, coords.y, coords.z, coords.w or 0.0, true, true)
    snapToGround(dropoffPed)
    -- Without this, OneSync can clean the ped up as "too far from any
    -- player" before whoever's driving the van actually gets there.
    SetEntityAsMissionEntity(dropoffPed, true, true)
    SetEntityInvincible(dropoffPed, true)
    SetBlockingOfNonTemporaryEvents(dropoffPed, true)
    FreezeEntityPosition(dropoffPed, true)
    TaskStartScenarioInPlace(dropoffPed, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
end

local function setupDropoffTarget(coords, model, isLeader, label, action)
    clearFallbackPrompt()
    if isLeader == false then return end
    label = label or 'Make Delivery'
    action = action or doDropoff

    -- The ped may already exist (courier spawns it early) — only spawn a
    -- fresh one if it's missing, so we don't pop a second copy in.
    if not dropoffPed or not DoesEntityExist(dropoffPed) then
        spawnDropoffPedOnly(coords, model, isLeader)
        if not dropoffPed then return end
    end

    local zoneOk = false
    if hasTarget then
        local ok = pcall(function()
            exports.ox_target:addLocalEntity(dropoffPed, {
                { name = 'xs_dropoff_task', label = label, icon = 'fas fa-handshake',
                  onSelect = action },
            })
        end)
        zoneOk = ok
    end
    if not zoneOk then
        fallbackPrompt = { coords = coords, label = label, action = action }
    end
end

-- Car boosting is its own standalone system now — see client/boosting.lua.

local function doHeistStage(callbackName)
    local res = lib.callback.await(callbackName, false)
    if res and not res.ok then lib.notify({ description = res.error or 'Failed', type = 'error' }) end
end

local function doInfiltrate(holdSeconds)
    if lib.progressBar({ duration = (holdSeconds or 6) * 1000, label = 'Working the lock...', useWhileDead = false, canCancel = true }) then
        doHeistStage('XS-CriminalTablet:tasks:doInfiltrate')
    end
end

RegisterNetEvent('XS-CriminalTablet:client:taskUpdate', function(job)
    clearTaskBlip()
    if not job then
        clearAllTaskVisuals()
        return
    end

    if job.type == 'kill' then
        clearCarryProp(); clearPickupZone(); clearDropoffPed(); clearEscortPed(); clearHeistZone(); clearCourierVan(); clearCourierZone(); clearQuartermaster(); clearFallbackPrompt()
        spawnKillTarget(job.spawn, job.pedModel, job.weapon, job.isLeader)
        return
    end

    if job.type == 'escort' then
        clearCarryProp(); clearPickupZone(); clearDropoffPed(); clearKillPed(); clearHeistZone(); clearCourierVan(); clearCourierZone(); clearQuartermaster(); clearFallbackPrompt()
        spawnEscort(job.spawn, job.destination, job.pedModel, job.radius, job.isLeader)
        return
    end

    if job.type == 'courier' then
        clearCarryProp(); clearPickupZone(); clearKillPed(); clearEscortPed(); clearHeistZone()

        if job.stage == 'pickup_van' then
            clearCourierZone(); clearDropoffPed()
            spawnCourierVan(job.vanSpawn, job.vanModel, job.isLeader)
            -- Hand-off ped spawns now too, not at the handoff stage — it
            -- should already be standing there when the van arrives.
            spawnDropoffPedOnly(job.dropoff, job.dropoffPedModel or 'g_m_y_lost_01', job.isLeader)
            spawnQuartermaster(job.vanSpawn, job.quartermasterModel or 'g_m_y_lost_01', job.isLeader, function()
                local res = lib.callback.await('XS-CriminalTablet:tasks:doPickupVan', false)
                if res and not res.ok then lib.notify({ description = res.error or 'Failed', type = 'error' }) end
            end)

            taskBlip = AddBlipForCoord(job.vanSpawn.x, job.vanSpawn.y, job.vanSpawn.z)
            SetBlipSprite(taskBlip, 477)
            SetBlipColour(taskBlip, 5)
            SetBlipRoute(taskBlip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString('Get the van')
            EndTextCommandSetBlipName(taskBlip)
            return
        elseif job.stage == 'enroute' then
            clearQuartermaster(); clearCourierZone()
            maybeTriggerCourierAmbush(job.ambushChance, job.dropoff)
            setupVanBackTarget(courierVan, 'Open the Boot', function()
                if lib.progressBar({ duration = 2200, label = 'Grabbing the package...', useWhileDead = false,
                                      canCancel = true, anim = { dict = 'pickup_object', clip = 'pickup_low' } }) then
                    local res = lib.callback.await('XS-CriminalTablet:tasks:doUnload', false)
                    if res and not res.ok then lib.notify({ description = res.error or 'Failed', type = 'error' }) end
                end
            end)

            taskBlip = AddBlipForCoord(job.dropoff.x, job.dropoff.y, job.dropoff.z)
            SetBlipSprite(taskBlip, 1)
            SetBlipColour(taskBlip, 5)
            SetBlipRoute(taskBlip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString('Drive to drop-off')
            EndTextCommandSetBlipName(taskBlip)
            return
        elseif job.stage == 'handoff' then
            clearCourierZone()
            if job.carryProp then attachCarryProp(job.carryProp) else clearCarryProp() end
            setupDropoffTarget(job.dropoff, job.dropoffPedModel or 'g_m_y_lost_01', job.isLeader, 'Hand Off Package', function()
                if lib.progressBar({ duration = 1800, label = 'Handing off the package...', useWhileDead = false,
                                      canCancel = true, anim = { dict = 'mp_common', clip = 'givetake1_a' } }) then
                    local res = lib.callback.await('XS-CriminalTablet:tasks:doCourierHandoff', false)
                    if res and not res.ok then lib.notify({ description = res.error or 'Failed', type = 'error' }) end
                end
            end)
        else -- return
            clearDropoffPed(); clearCarryProp()
            setupCourierTarget(job.vanSpawn, 'Return Van', job.radius, function()
                local res = lib.callback.await('XS-CriminalTablet:tasks:doReturnVan', false)
                if res and not res.ok then lib.notify({ description = res.error or 'Failed', type = 'error' }) end
            end)
        end

        local coords = job.stage == 'return' and job.vanSpawn or job.dropoff
        taskBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
        SetBlipSprite(taskBlip, job.stage == 'return' and 477 or 358)
        SetBlipColour(taskBlip, job.stage == 'return' and 5 or 2)
        SetBlipRoute(taskBlip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(job.stage == 'return' and 'Return the van' or 'Hand off')
        EndTextCommandSetBlipName(taskBlip)
        return
    end

    if job.type == 'heist' then
        clearCarryProp(); clearPickupZone(); clearDropoffPed(); clearKillPed(); clearEscortPed(); clearCourierVan(); clearCourierZone(); clearQuartermaster()
        local label, action
        if job.stage == 'infiltrate' then
            label, action = 'Infiltrate', function() doInfiltrate(job.holdSeconds) end
        elseif job.stage == 'grab' then
            label, action = 'Grab It', function() doHeistStage('XS-CriminalTablet:tasks:doGrab') end
        else
            label, action = 'Escape', function() doHeistStage('XS-CriminalTablet:tasks:doEscape') end
        end
        setupHeistTarget(job.point, label, job.radius, action)

        taskBlip = AddBlipForCoord(job.point.x, job.point.y, job.point.z)
        SetBlipSprite(taskBlip, 511)
        SetBlipColour(taskBlip, job.stage == 'escape' and 1 or 5)
        SetBlipRoute(taskBlip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(label)
        EndTextCommandSetBlipName(taskBlip)
        return
    end

    -- delivery
    clearKillPed(); clearEscortPed(); clearHeistZone(); clearCourierVan(); clearCourierZone(); clearQuartermaster()

    if job.stage == 'pickup' then
        clearCarryProp()
        clearDropoffPed()
        setupPickupTarget(job.pickup)
    elseif job.stage == 'dropoff' then
        clearPickupZone()
        if job.carryProp then attachCarryProp(job.carryProp) else clearCarryProp() end
        setupDropoffTarget(job.dropoff, job.dropoffPedModel or 'g_m_y_lost_01', job.isLeader)
    end

    local coords = job.stage == 'pickup' and job.pickup or job.dropoff
    taskBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(taskBlip, job.stage == 'pickup' and 1 or 358)
    SetBlipColour(taskBlip, job.stage == 'pickup' and 5 or 2)
    SetBlipRoute(taskBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(job.stage == 'pickup' and 'Pickup' or 'Dropoff')
    EndTextCommandSetBlipName(taskBlip)
end)

-- Incoming task co-op invite -> in-device banner or ox_lib dialog.
RegisterNetEvent('XS-CriminalTablet:client:taskCoopInvite', function(info)
    Device.PromptInvite('task', 'Crew Invite', info.fromName, 'invited you to crew up on a task')
end)

-- Server tells the van's owner to clean it up once the job ends (complete,
-- cancelled, or timed out) — netId-targeted so it works even if a fresh
-- taskUpdate already cleared courierVan locally.
RegisterNetEvent('XS-CriminalTablet:client:taskCleanupVan', function(netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then DeleteEntity(veh) end
    if courierVan == veh then courierVan = nil end
    clearCourierAmbush()
end)

-- ── model test helper ──
-- Lets an admin try candidate prop/ped names live and see if they're
-- actually valid on this build, instead of guessing from config.lua and
-- restarting blind. /testmodel <name> [ped]
RegisterCommand('testmodel', function(_, args)
    if not lib.callback.await('XS-CriminalTablet:admin:checkAccess', false) then return end
    local name = args[1]
    if not name then
        lib.notify({ description = 'Usage: /testmodel <model_name> [ped]', type = 'error' })
        return
    end
    local hash = GetHashKey(name)
    if not IsModelValid(hash) then
        lib.notify({ description = ('Invalid model: %s'):format(name), type = 'error' })
        return
    end
    lib.notify({ description = ('Valid! Spawning %s for 6s in front of you.'):format(name), type = 'success' })
    lib.requestModel(hash)
    local ped = PlayerPedId()
    local fwd = GetEntityForwardVector(ped)
    local pos = GetEntityCoords(ped) + fwd * 2.0
    local isPed = args[2] == 'ped'
    local handle = isPed
        and CreatePed(4, hash, pos.x, pos.y, pos.z, 0.0, false, false)
        or CreateObject(hash, pos.x, pos.y, pos.z, false, false, false)
    SetEntityCoordsNoOffset(handle, pos.x, pos.y, pos.z)
    SetTimeout(6000, function()
        if DoesEntityExist(handle) then DeleteEntity(handle) end
    end)
end, false)

-- Crafting bench interaction now lives in client/crafting.lua as a
-- dedicated NUI panel (RegisterNetEvent('XS-CriminalTablet:client:openCraftBench', ...)).

-- Dealer interaction: rotating stock, server validates funds + gives
-- the item. "This is what I got right now" — stock and prices change
-- on Config.Dealer.rotateMinutes.
RegisterNetEvent('XS-CriminalTablet:client:talkToDealer', function()
    local stock = lib.callback.await('XS-CriminalTablet:dealer:getStock', false)
    if not stock or #stock == 0 then
        lib.notify({ description = "Nothing in stock right now — check back later.", type = 'inform' })
        return
    end

    local options = {}
    for _, s in ipairs(stock) do
        options[#options + 1] = {
            title = s.label,
            description = ('$%d'):format(s.price),
            icon = 'fas fa-bag-shopping',
            onSelect = function()
                local res = lib.callback.await('XS-CriminalTablet:dealer:buy', false, s.item)
                if res and res.ok then
                    lib.notify({ description = ('Bought %s for $%d.'):format(s.label, res.price), type = 'success' })
                else
                    lib.notify({ description = (res and res.error) or 'Failed to buy', type = 'error' })
                end
            end,
        }
    end

    lib.registerContext({ id = 'xs_dealer', title = "What I got right now", options = options })
    lib.showContext('xs_dealer')
end)

-- Incoming gang invite -> in-device banner or ox_lib dialog.
RegisterNetEvent('XS-CriminalTablet:client:gangInvite', function(info)
    Device.PromptInvite('gang', 'Gang Invite', info.from, ('invited you to join %s'):format(info.gang))
end)
