-- ─────────────────────────────────────────────────────────────
-- Gang medic client. Finds the nearest crew member, plays the treatment,
-- and lets the server decide whether it counts.
--
-- Health and the downed state are applied here because only the patient's
-- own client can set them, but nothing is applied until the server has
-- said yes.
--
-- The clinic itself is one fixed spot the whole server shares, spawned
-- from Config.Medic.station rather than placed by a crew.
-- ─────────────────────────────────────────────────────────────
Medic = {}

-- ── the shared clinic ───────────────────────────────────────
local stationObj = nil
local stationBlip = nil

local function clearStation()
    if stationObj and DoesEntityExist(stationObj) then DeleteEntity(stationObj) end
    if stationBlip and DoesBlipExist(stationBlip) then RemoveBlip(stationBlip) end
    stationObj, stationBlip = nil, nil
end

local function spawnStation()
    local st = Config.Medic.station
    if not Config.Medic.enabled or not st or not st.coords then return end
    clearStation()

    local c = st.coords

    if st.model and st.model ~= '' then
        if IsModelValid(st.model) then
            lib.requestModel(st.model)
            stationObj = CreateObject(st.model, c.x, c.y, c.z, false, false, false)
            SetEntityHeading(stationObj, st.heading or 0.0)
            FreezeEntityPosition(stationObj, true)
            SetEntityAsMissionEntity(stationObj, true, true)
        else
            print(('^1[XS-CriminalTablet]^0 Config.Medic.station.model "%s" is not a valid model'):format(tostring(st.model)))
        end
    end

    local blip = st.blip or {}
    if blip.enabled ~= false then
        stationBlip = AddBlipForCoord(c.x, c.y, c.z)
        SetBlipSprite(stationBlip, blip.sprite or 61)
        SetBlipColour(stationBlip, blip.color or 2)
        SetBlipScale(stationBlip, (blip.scale or 0.7) + 0.0)
        SetBlipAsShortRange(stationBlip, blip.shortRange ~= false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(st.label or 'Clinic')
        EndTextCommandSetBlipName(stationBlip)
    end

    -- The station is a landmark, not a menu: standing at it is what
    -- unlocks reviving, so there is nothing here to click. The tablet
    -- opens on the Hub the same as anywhere else.
    if stationObj and XSTarget.Ready() then
        exports.ox_target:addLocalEntity(stationObj, {
            {
                name = 'xs_medic_station',
                label = 'Open the tablet',
                icon = 'fas fa-kit-medical',
                distance = 2.5,
                onSelect = function() TriggerEvent('XS-CriminalTablet:client:openMedic') end,
            },
        })
    end
end

-- True when the local player is stood close enough for a revive.
function Medic.AtStation()
    local st = Config.Medic.station
    if not st or not st.coords then return false end
    return #(GetEntityCoords(PlayerPedId()) - st.coords) <= (Config.Medic.stationRadius or 25.0)
end

CreateThread(function()
    Wait(1200)
    spawnStation()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then clearStation() end
end)

local TREAT_DICT = 'amb@medic@standing@kneel@base'
local TREAT_ANIM = 'base'

-- Nearest other player within range, with their server id.
local function nearestPlayer(maxDist)
    local me = PlayerPedId()
    local myPos = GetEntityCoords(me)
    local bestPed, bestId, bestDist = nil, nil, maxDist or 4.0

    for _, playerIdx in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(playerIdx)
        if ped ~= me and DoesEntityExist(ped) then
            local d = #(myPos - GetEntityCoords(ped))
            if d < bestDist then
                bestPed, bestId, bestDist = ped, GetPlayerServerId(playerIdx), d
            end
        end
    end
    return bestPed, bestId
end

local function treat(kind)
    if not Config.Medic.enabled then return end

    local ped, serverId = nearestPlayer(4.0)
    if not serverId then
        lib.notify({ description = 'Nobody close enough.', type = 'error' })
        return
    end

    if kind == 'revive' and not IsEntityDead(ped) then
        lib.notify({ description = 'They are already up.', type = 'error' })
        return
    end
    if kind == 'heal' and IsEntityDead(ped) then
        lib.notify({ description = 'They need a revive, not a patch-up.', type = 'error' })
        return
    end

    local finished = XSAnim.Progress({
        duration = Config.Medic.treatSeconds * 1000,
        label = kind == 'revive' and 'Reviving...' or 'Patching them up...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, combat = true },
        anims = { { dict = TREAT_DICT, clip = TREAT_ANIM } },
    })
    if not finished then return end

    local res = lib.callback.await(
        kind == 'revive' and 'XS-CriminalTablet:medic:revive' or 'XS-CriminalTablet:medic:heal',
        false, serverId)

    lib.notify({
        description = (res and res.ok) and (kind == 'revive' and 'They are back up.' or 'Patched up.')
            or ((res and res.error) or 'That did not work'),
        type = (res and res.ok) and 'success' or 'error',
    })
end

function Medic.Heal() treat('heal') end
function Medic.Revive() treat('revive') end

-- ── applied to the patient ──────────────────────────────────
RegisterNetEvent('XS-CriminalTablet:client:medicHeal', function(amount)
    local ped = PlayerPedId()
    SetEntityHealth(ped, math.min(GetEntityMaxHealth(ped), GetEntityHealth(ped) + (amount or 50)))
end)

RegisterNetEvent('XS-CriminalTablet:client:medicRevive', function(health)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)
    SetEntityHealth(ped, health or 130)
    ClearPedBloodDamage(ped)
    ClearPedTasksImmediately(ped)

    -- Hand the framework's own downed state back too, where one exists —
    -- otherwise the player is standing up but still flagged as dead.
    if GetResourceState('qbx_medical') == 'started' then
        pcall(function() exports.qbx_medical:revive() end)
    elseif GetResourceState('hospital') == 'started' then
        pcall(function() TriggerEvent('hospital:client:Revive') end)
    else
        TriggerEvent('hospital:client:Revive')
    end
end)

RegisterNetEvent('XS-CriminalTablet:client:openMedic', function()
    TriggerEvent('XS-CriminalTablet:client:openDeviceAt', 'hub')
end)
