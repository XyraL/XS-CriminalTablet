-- ─────────────────────────────────────────────────────────────
-- Field radial. A quick-action wheel for everything the crew does in the
-- world, on a keybind the player can rebind themselves (it registers
-- through FiveM's keymapping, so it also shows up under
-- Settings > Key Bindings > FiveM).
--
-- The wheel itself is drawn by the tablet's own NUI rather than ox_lib's
-- shared radial, so it can carry the gang's colour and only ever show
-- actions that make sense right now.
-- ─────────────────────────────────────────────────────────────
local radialOpen = false
local restraint = { cuffed = false, bagged = false }
local carriedBy = nil
local carryMode = nil

local CARRY_ANIMS = {
    carry   = { dict = 'nm', clip = 'firemans_carry', offset = vec3(0.27, 0.15, 0.63), rot = vec3(0.5, 0.5, 0.0) },
    escort  = { dict = 'amb@code_human_in_car_idles@generic@ps@base', clip = 'base', offset = vec3(0.45, 0.2, 0.0), rot = vec3(0.0, 0.0, 0.0) },
    hostage = { dict = 'anim@gangops@hostage@', clip = 'perp_idle', offset = vec3(0.1, 0.45, 0.0), rot = vec3(0.0, 0.0, 0.0) },
}

-- ── context ─────────────────────────────────────────────────
local function nearestPlayer(maxDist)
    local me = PlayerPedId()
    local myPos = GetEntityCoords(me)
    local bestId, bestDist = nil, maxDist or 3.0
    for _, playerIdx in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(playerIdx)
        if ped ~= me and DoesEntityExist(ped) then
            local d = #(myPos - GetEntityCoords(ped))
            if d < bestDist then bestId, bestDist = GetPlayerServerId(playerIdx), d end
        end
    end
    return bestId
end

local function nearestVehicle(maxDist)
    local pos = GetEntityCoords(PlayerPedId())
    local vehicle = GetClosestVehicle(pos.x, pos.y, pos.z, maxDist or 5.0, 0, 71)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    return vehicle
end

-- Only offer what's actually possible from where the player is standing.
local function buildItems()
    local items = {}
    local cfg = Config.Radial.actions
    local hasTarget = nearestPlayer(3.0) ~= nil
    local hasVehicle = nearestVehicle(5.0) ~= nil
    local inVehicle = GetVehiclePedIsIn(PlayerPedId(), false) ~= 0

    local function add(id, note, disabled)
        local a = cfg[id]
        if not a or not a.enabled then return end
        items[#items + 1] = {
            id = id, label = a.label, icon = a.icon,
            note = note, disabled = disabled or false,
        }
    end

    add('graffiti')
    add('garage', inVehicle and 'Store this one' or 'Pull one out')
    add('capture')
    add('medic', hasTarget and nil or 'Nobody close', not hasTarget)

    -- Reviving needs the patient at the shared clinic, so say which of the
    -- two things is missing rather than greying the entry out unexplained.
    local needsClinic = Config.Medic.reviveNeedsStation
    local atClinic = (not needsClinic) or Medic.AtStation()
    add('revive',
        (not hasTarget) and 'Nobody close' or (atClinic and nil or 'Not at the clinic'),
        not hasTarget or not atClinic)
    add('cuff', hasTarget and nil or 'Nobody close', not hasTarget)
    add('bag', hasTarget and nil or 'Nobody close', not hasTarget)
    add('carry', hasTarget and nil or 'Nobody close', not hasTarget)
    add('escort', hasTarget and nil or 'Nobody close', not hasTarget)
    add('hostage', hasTarget and nil or 'Nobody close', not hasTarget)
    add('trunk', (hasTarget and hasVehicle) and nil or 'Need a person and a vehicle', not (hasTarget and hasVehicle))
    add('searchRob', hasTarget and nil or 'Nobody close', not hasTarget)
    add('slashTyre', hasVehicle and nil or 'No vehicle close', not hasVehicle)
    add('tablet')

    return items
end

-- ── open / close ────────────────────────────────────────────
local function closeRadial()
    if not radialOpen then return end
    radialOpen = false
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'radialClose' })
end

local function openRadial()
    if radialOpen then closeRadial() return end
    if not Config.Radial.enabled then return end
    if carriedBy then
        lib.notify({ description = 'Not right now.', type = 'error' })
        return
    end

    local snapshot = lib.callback.await('XS-CriminalTablet:getSnapshot', false)
    if not snapshot or not snapshot.gang then
        lib.notify({ description = 'You are not in a gang.', type = 'error' })
        return
    end

    radialOpen = true
    -- Cursor on, but the game keeps every other input: you can still see
    -- what is happening and keep walking while the wheel is up.
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(true)

    -- Keeping input means the mouse also reaches the game, so every click
    -- on the wheel used to throw a punch. Movement stays, attacking does
    -- not, for exactly as long as the wheel is open.
    CreateThread(function()
        while radialOpen do
            Wait(0)
            DisableControlAction(0, 24, true)   -- attack
            DisableControlAction(0, 25, true)   -- aim
            DisableControlAction(0, 47, true)   -- weapon
            DisableControlAction(0, 58, true)   -- weapon
            DisableControlAction(0, 140, true)  -- melee light
            DisableControlAction(0, 141, true)  -- melee heavy
            DisableControlAction(0, 142, true)  -- melee alternate
            DisableControlAction(0, 143, true)  -- melee block
            DisableControlAction(0, 257, true)  -- attack 2
            DisableControlAction(0, 263, true)  -- melee 1
            DisableControlAction(0, 264, true)  -- melee 2
            DisableControlAction(0, 331, true)  -- vehicle attack
            DisableControlAction(0, 106, true)  -- vehicle mouse control override
        end
    end)
    SendNUIMessage({
        action = 'radialOpen',
        data = {
            items = buildItems(),
            color = snapshot.gang.color,
            gang = snapshot.gang.label,
            perms = snapshot.gang.perms,
        },
    })
end

RegisterCommand(Config.Radial.command, function() openRadial() end, false)
RegisterKeyMapping(Config.Radial.command, 'Gang field radial', 'keyboard', Config.Radial.key)

RegisterNUICallback('radial:close', function(_, cb)
    closeRadial()
    cb({})
end)

-- ── actions ─────────────────────────────────────────────────
local function notify(res, okMsg)
    lib.notify({
        description = (res and res.ok) and (okMsg or 'Done.') or ((res and res.error) or 'That did not work'),
        type = (res and res.ok) and 'success' or 'error',
    })
end

local function runFieldAction(action, extra)
    local target = nearestPlayer(3.0)
    if not target then
        lib.notify({ description = 'Nobody close enough.', type = 'error' })
        return
    end

    local finished = XSAnim.Progress({
        duration = Config.Radial.actionSeconds * 1000,
        label = 'Working...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, combat = true },
    })
    if not finished then return end

    local res = lib.callback.await('XS-CriminalTablet:field:action', false, action, target, extra)
    if action == 'searchRob' and res and res.ok then
        lib.notify({ description = ('Took %s.'):format(res.detail), type = 'success' })
    else
        notify(res)
    end
end

-- Pick which of the gang's art to put up, then hand off to the sprayer.
local function pickGraffiti()
    local lib_ = lib.callback.await('XS-CriminalTablet:graffiti:getLibrary', false)
    if not lib_ or not lib_.canSpray then
        lib.notify({ description = 'Your rank cannot spray.', type = 'error' })
        return
    end

    local options = {}
    for _, art in ipairs(lib_.library or {}) do
        options[#options + 1] = {
            title = art.label ~= '' and art.label or 'Untitled',
            description = art.source == 'admin' and 'Staff-issued' or 'Crew library',
            icon = 'spray-can',
            onSelect = function()
                TriggerEvent('XS-CriminalTablet:client:startSpray', { kind = 'library', artId = art.id })
            end,
        }
    end

    if #options == 0 then
        lib.notify({ description = 'Your crew has no art yet — ask staff, or make some in the Studio.', type = 'error' })
        return
    end

    lib.registerContext({ id = 'xs_graffiti_pick', title = 'Pick a tag', options = options })
    lib.showContext('xs_graffiti_pick')
end

local function claimTurf()
    local here = lib.callback.await('XS-CriminalTablet:capture:whereAmI', false)
    if not here or not here.inZone then
        lib.notify({ description = 'You are not standing on a zone.', type = 'error' })
        return
    end
    if here.mine then
        lib.notify({ description = ('Your crew already holds %s.'):format(here.label), type = 'inform' })
        return
    end
    if here.blocked then
        lib.notify({ description = here.blocked, type = 'error' })
        return
    end

    local res = lib.callback.await('XS-CriminalTablet:capture:start', false, here.zone)
    notify(res, ('Claiming %s — hold it.'):format(here.label))
end

local function slashTyre()
    local vehicle = nearestVehicle(5.0)
    if not vehicle then
        lib.notify({ description = 'No vehicle close enough.', type = 'error' })
        return
    end

    local cfg = Config.Radial.slash or {}
    if cfg.item and cfg.item ~= '' then
        local has = lib.callback.await('XS-CriminalTablet:field:hasItem', false, cfg.item)
        if not has then
            lib.notify({ description = 'You need something sharp for that.', type = 'error' })
            return
        end
    end

    -- Whichever wheel is nearest is the one that goes.
    local pos = GetEntityCoords(PlayerPedId())
    local best, bestDist = 0, 9999.0
    for _, idx in ipairs({ 0, 1, 4, 5 }) do
        local bone = GetEntityBoneIndexByName(vehicle, ({ [0] = 'wheel_lf', [1] = 'wheel_rf', [4] = 'wheel_lr', [5] = 'wheel_rr' })[idx])
        if bone ~= -1 then
            local d = #(pos - GetWorldPositionOfEntityBone(vehicle, bone))
            if d < bestDist then best, bestDist = idx, d end
        end
    end

    -- Knife in hand so the animation reads as cutting something rather
    -- than crouching next to a car for no reason.
    local knife = nil
    if cfg.prop and cfg.prop ~= '' and IsModelValid(cfg.prop) then
        lib.requestModel(cfg.prop)
        local ped = PlayerPedId()
        local c = GetEntityCoords(ped)
        knife = CreateObject(cfg.prop, c.x, c.y, c.z, true, true, false)
        AttachEntityToEntity(knife, ped, GetPedBoneIndex(ped, 57005),
            0.09, 0.03, -0.02, -78.0, -90.0, 0.0, true, true, false, true, 1, true)
    end

    local finished = XSAnim.Progress({
        duration = (cfg.seconds or 3) * 1000,
        label = 'Slashing...', canCancel = true,
        disable = { move = true, combat = true },
        anims = cfg.anims,
    })

    if knife and DoesEntityExist(knife) then DeleteEntity(knife) end
    ClearPedTasks(PlayerPedId())
    if not finished then return end

    local res = lib.callback.await('XS-CriminalTablet:field:slashTyre', false,
        NetworkGetNetworkIdFromEntity(vehicle), best, cfg.item)
    notify(res, 'Tyre gone.')
end

local function trunkTarget()
    local vehicle = nearestVehicle(5.0)
    local target = nearestPlayer(3.0)
    if not vehicle or not target then
        lib.notify({ description = 'Need a person and a vehicle.', type = 'error' })
        return
    end
    local res = lib.callback.await('XS-CriminalTablet:field:trunk', false, target,
        NetworkGetNetworkIdFromEntity(vehicle))
    notify(res, 'In the trunk.')
end

local HANDLERS = {
    graffiti = pickGraffiti,
    capture = claimTurf,
    slashTyre = slashTyre,
    trunk = trunkTarget,
    medic = function() Medic.Heal() end,
    revive = function() Medic.Revive() end,
    tablet = function() TriggerEvent('XS-CriminalTablet:client:openDeviceFromWorld') end,
    garage = function()
        if GetVehiclePedIsIn(PlayerPedId(), false) ~= 0 then
            GangGarage.StoreCurrent()
        else
            TriggerEvent('XS-CriminalTablet:client:openDeviceAt', 'garage')
        end
    end,
    cuff = function() runFieldAction('cuff') end,
    bag = function() runFieldAction('bag') end,
    carry = function() runFieldAction('carry') end,
    escort = function() runFieldAction('escort') end,
    hostage = function() runFieldAction('hostage') end,
    searchRob = function() runFieldAction('searchRob') end,
}

RegisterNUICallback('radial:select', function(data, cb)
    closeRadial()
    cb({})
    local handler = HANDLERS[data and data.id]
    if handler then CreateThread(handler) end
end)

-- ── restrained / carried states ─────────────────────────────
local CUFF_DICT = 'mp_arresting'
local CUFF_ANIM = 'idle'
local BAG_PROP = 'p_cs_clothes_pile'

local function applyCuffed(on)
    local ped = PlayerPedId()
    if on then
        RequestAnimDict(CUFF_DICT)
        local waited = 0
        while not HasAnimDictLoaded(CUFF_DICT) and waited < 1000 do Wait(50); waited = waited + 50 end
        TaskPlayAnim(ped, CUFF_DICT, CUFF_ANIM, 8.0, -8.0, -1, 49, 0, false, false, false)
        SetEnableHandcuffs(ped, true)
        SetPedCanPlayGestureAnims(ped, false)
    else
        ClearPedSecondaryTask(ped)
        StopAnimTask(ped, CUFF_DICT, CUFF_ANIM, 1.0)
        SetEnableHandcuffs(ped, false)
        SetPedCanPlayGestureAnims(ped, true)
    end
end

RegisterNetEvent('XS-CriminalTablet:client:setRestraint', function(kind, on)
    restraint[kind] = on
    if kind == 'cuffed' then applyCuffed(on) end
    if kind == 'bagged' then
        -- A bagged player simply cannot see; the prop is cosmetic.
        DoScreenFadeOut(300)
        if not on then Wait(350) DoScreenFadeIn(300) end
    end
end)

-- Keep the cuffed animation and control lock alive — a single TaskPlayAnim
-- gets cleared by all sorts of things (ragdoll, vehicle entry, death).
CreateThread(function()
    while true do
        local sleep = 500
        local ped = PlayerPedId()

        if restraint.cuffed then
            sleep = 0
            DisableControlAction(0, 24, true)  -- attack
            DisableControlAction(0, 25, true)  -- aim
            DisableControlAction(0, 47, true)  -- weapon
            DisableControlAction(0, 58, true)
            DisableControlAction(0, 140, true) -- melee
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 257, true)
            DisableControlAction(0, 263, true)
            if not IsEntityPlayingAnim(ped, CUFF_DICT, CUFF_ANIM, 3) and not IsPedInAnyVehicle(ped, false) then
                applyCuffed(true)
            end
        end

        if restraint.bagged then
            sleep = 0
            DrawRect(0.5, 0.5, 2.0, 2.0, 0, 0, 0, 255)
        end

        Wait(sleep)
    end
end)

RegisterNetEvent('XS-CriminalTablet:client:setCarried', function(byServerId, mode)
    local ped = PlayerPedId()

    if not byServerId then
        carriedBy, carryMode = nil, nil
        DetachEntity(ped, true, false)
        ClearPedTasks(ped)
        return
    end

    carriedBy, carryMode = byServerId, mode
    local anim = CARRY_ANIMS[mode] or CARRY_ANIMS.carry
    local carrierPed = GetPlayerPed(GetPlayerFromServerId(byServerId))
    if not carrierPed or carrierPed == 0 then return end

    RequestAnimDict(anim.dict)
    local waited = 0
    while not HasAnimDictLoaded(anim.dict) and waited < 1000 do Wait(50); waited = waited + 50 end

    AttachEntityToEntity(ped, carrierPed, 0, anim.offset.x, anim.offset.y, anim.offset.z,
        anim.rot.x, anim.rot.y, anim.rot.z, false, false, false, false, 2, true)
    TaskPlayAnim(ped, anim.dict, anim.clip, 8.0, -8.0, -1, 49, 0, false, false, false)
end)

RegisterNetEvent('XS-CriminalTablet:client:setTrunk', function(netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 then return end
    local ped = PlayerPedId()

    DetachEntity(ped, true, false)
    AttachEntityToEntity(ped, vehicle, GetEntityBoneIndexByName(vehicle, 'boot'),
        0.0, -0.5, 0.3, 0.0, 0.0, 180.0, false, false, false, false, 2, true)
    RequestAnimDict('nm')
    TaskPlayAnim(ped, 'nm', 'firemans_carry', 8.0, -8.0, -1, 49, 0, false, false, false)
    SetVehicleDoorShut(vehicle, 5, false)
end)

RegisterNetEvent('XS-CriminalTablet:client:popTyre', function(netId, tyreIndex)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end
    SetVehicleTyreBurst(vehicle, tyreIndex or 0, true, 1000.0)
end)

-- The rob check asks the victim's own client whether their hands are up.
-- IsEntityPlayingAnim returns a boolean, so these are truthiness checks —
-- comparing to 1 would report everyone as not surrendering.
lib.callback.register('XS-CriminalTablet:field:handsUp', function()
    local ped = PlayerPedId()
    local CLIPS = {
        { 'random@mugging3', 'handsup_standing_base' },
        { 'missminuteman_1ig_2', 'handsup_base' },
        { 'random@arrests@busted', 'idle_a' },
    }
    for _, clip in ipairs(CLIPS) do
        if IsEntityPlayingAnim(ped, clip[1], clip[2], 3) then return true end
    end
    return false
end)

-- Re-sync after a respawn or a resource restart, so a cuffed player
-- doesn't quietly come back free.
CreateThread(function()
    Wait(5000)
    local state = lib.callback.await('XS-CriminalTablet:field:getRestraint', false)
    if state and state.cuffed then
        restraint.cuffed = true
        applyCuffed(true)
    end
end)
