-- ─────────────────────────────────────────────────────────────
-- Street doc client. One doctor the server shares, spawned here only for
-- players whose crew has bought access, and only while they are near.
-- Also what happens when you talk to him, and what lands on the patient.
-- ─────────────────────────────────────────────────────────────
Medic = {}

local busy = false
local doc = nil        -- where he stands, when our crew has him
local ped = nil
local prompt = false

local function money(n)
    return n > 0 and ('$%d'):format(n) or 'free'
end

local function visit(kind)
    if busy then return end
    busy = true
    local res = lib.callback.await('XS-CriminalTablet:medic:begin', false, kind)
    if not res or not res.ok then
        busy = false
        lib.notify({ description = (res and res.error) or 'He will not see you', type = 'error' })
        return
    end

    local finished = XSAnim.Progress({
        duration = res.time,
        label = kind == 'revive' and ('The doc is working on %s (%s)'):format(res.name or 'them', money(res.price))
            or ('The doc is patching you up (%s)'):format(money(res.price)),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, combat = true },
    })
    if not finished then
        busy = false
        lib.callback('XS-CriminalTablet:medic:cancel', false, function() end)
        return
    end

    local done = lib.callback.await('XS-CriminalTablet:medic:finish', false)
    busy = false
    lib.notify({
        description = (done and done.ok) and (kind == 'revive' and 'They are back up.' or 'Patched up.')
            or ((done and done.error) or 'That did not work'),
        type = (done and done.ok) and 'success' or 'error',
    })
end

function Medic.Heal() visit('heal') end
function Medic.Revive() visit('revive') end

-- Without ox_target: one prompt, and a menu for the two things he does.
function Medic.Menu()
    lib.registerContext({
        id = 'xs_street_doc',
        title = 'Street Doc',
        options = {
            { title = 'Get patched up', description = money(Config.Medic.healPrice or 0), icon = 'kit-medical', onSelect = Medic.Heal },
            { title = 'Bring back a downed member', description = money(Config.Medic.revivePrice or 0) .. ' · they have to be with him', icon = 'heart-pulse', onSelect = Medic.Revive },
        },
    })
    lib.showContext('xs_street_doc')
end

-- ── the doc himself ─────────────────────────────────────────
local function despawn()
    if ped and DoesEntityExist(ped) then
        if XSTarget.Ready() then pcall(function() exports.ox_target:removeLocalEntity(ped) end) end
        DeleteEntity(ped)
    end
    ped = nil
    if prompt then
        lib.hideTextUI()
        prompt = false
    end
end

local function spawn()
    local model = Config.Medic.pedModel or 's_m_m_doctor_01'
    if not IsModelValid(model) or not XSModel.Load(model) then
        print(('^1[XS-CriminalTablet]^0 street doc model "%s" did not load - set another in Settings > Street doc'):format(tostring(model)))
        return
    end
    -- A spot dropped on the builder map has no height, so find the ground.
    local z = doc.z
    local found, gz = GetGroundZFor_3dCoord(doc.x + 0.0, doc.y + 0.0, (z or 1000.0) + 2.0, false)
    if found then z = gz end
    ped = CreatePed(4, model, doc.x + 0.0, doc.y + 0.0, (z or 0.0) + 0.0, (doc.h or 0.0) + 0.0, false, false)
    SetModelAsNoLongerNeeded(model)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedFleeAttributes(ped, 0, false)
    FreezeEntityPosition(ped, true)
    local scenario = Config.Medic.scenario
    if scenario and scenario ~= '' then TaskStartScenarioInPlace(ped, scenario, 0, true) end

    if XSTarget.Ready() then
        exports.ox_target:addLocalEntity(ped, {
            { name = 'xs_doc_heal', label = ('Get Patched Up (%s)'):format(money(Config.Medic.healPrice or 0)), icon = 'fas fa-kit-medical', distance = 2.5, onSelect = Medic.Heal },
            { name = 'xs_doc_revive', label = ('Bring Back A Downed Member (%s)'):format(money(Config.Medic.revivePrice or 0)), icon = 'fas fa-heart-pulse', distance = 2.5, onSelect = Medic.Revive },
        })
    end
end

local function refresh()
    doc = lib.callback.await('XS-CriminalTablet:medic:where', false)
    despawn()
end

CreateThread(function()
    Wait(3000)
    refresh()
    while true do
        local sleep = 1500
        if doc and Config.Medic.enabled then
            local p = GetEntityCoords(PlayerPedId())
            local dx, dy = p.x - doc.x, p.y - doc.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < 90.0 and not ped then spawn()
            elseif d > 110.0 and ped then despawn() end

            -- Without ox_target, an [E] prompt and a menu.
            if ped and not XSTarget.Ready() then
                if d < 2.5 then
                    sleep = 0
                    if not prompt then
                        lib.showTextUI('[E] Talk to the doc')
                        prompt = true
                    end
                    if IsControlJustReleased(0, 38) then Medic.Menu() end
                elseif prompt then
                    lib.hideTextUI()
                    prompt = false
                end
            end
        elseif ped then
            despawn()
        end
        Wait(sleep)
    end
end)

RegisterNetEvent('XS-CriminalTablet:client:docUpdate', refresh)
RegisterNetEvent('XS-CriminalTablet:client:gangIdChanged', refresh)
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function() SetTimeout(2500, refresh) end)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    doc = nil
    despawn()
end)
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then despawn() end
end)

-- ── applied to the patient ──────────────────────────────────
-- The medical resource owns the downed state, so it is told first; the ped
-- itself is put right after, which is the whole job when none is running.
RegisterNetEvent('XS-CriminalTablet:client:docRevive', function()
    if GetResourceState('qbx_medical') == 'started' then
        TriggerEvent('qbx_medical:client:playerRevived')
    elseif GetResourceState('qb-ambulancejob') == 'started' then
        TriggerEvent('hospital:client:Revive')
    elseif GetResourceState('wasabi_ambulance') == 'started' then
        TriggerEvent('wasabi_ambulance:revive')
    end

    local ped = PlayerPedId()
    if IsEntityDead(ped) then
        local c = GetEntityCoords(ped)
        NetworkResurrectLocalPlayer(c.x, c.y, c.z, GetEntityHeading(ped), true, false)
        ped = PlayerPedId()
    end
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    ClearPedBloodDamage(ped)
    ClearPedTasksImmediately(ped)
end)

RegisterNetEvent('XS-CriminalTablet:client:docHeal', function()
    if GetResourceState('qbx_medical') == 'started' then
        TriggerEvent('qbx_medical:client:heal', 'full')
    elseif GetResourceState('qb-ambulancejob') == 'started' then
        TriggerEvent('hospital:client:HealInjuries', 'full')
    end
    local ped = PlayerPedId()
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    ClearPedBloodDamage(ped)
end)
