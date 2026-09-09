-- ─────────────────────────────────────────────────────────────
-- Dealer client: spawns/despawns the on-demand dealer ped wherever the
-- server says it landed, and gives it a talk interaction (ox_target, or
-- an [E] proximity prompt if ox_target isn't installed). The actual
-- stock menu lives in client/main.lua's talkToDealer handler — same one
-- the old placed-ped version used.
-- ─────────────────────────────────────────────────────────────
local hasTarget = GetResourceState('ox_target') == 'started'
local dealerPed = nil
local dealerBlip = nil

local function despawnDealer()
    if dealerPed and DoesEntityExist(dealerPed) then DeleteEntity(dealerPed) end
    dealerPed = nil
    if dealerBlip then RemoveBlip(dealerBlip); dealerBlip = nil end
end

local function spawnDealer(coords, model)
    despawnDealer()
    if not IsModelValid(model) then
        print(('^1[XS-CriminalTablet]^0 dealer model invalid (%s) — fix Config.Dealer.pedModel'):format(model))
        return
    end
    lib.requestModel(model)
    dealerPed = CreatePed(4, model, coords.x, coords.y, coords.z, coords.w or 0.0, false, false)
    SetEntityInvincible(dealerPed, true)
    SetBlockingOfNonTemporaryEvents(dealerPed, true)
    FreezeEntityPosition(dealerPed, true)

    if hasTarget then
        exports.ox_target:addLocalEntity(dealerPed, {
            { name = 'xs_talk_dealer', label = 'Talk to Dealer', icon = 'fas fa-comments',
              onSelect = function() TriggerEvent('XS-CriminalTablet:client:talkToDealer') end },
        })
    end

    dealerBlip = AddBlipForEntity(dealerPed)
    SetBlipSprite(dealerBlip, 280)
    SetBlipColour(dealerBlip, 1)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Dealer')
    EndTextCommandSetBlipName(dealerBlip)
end

RegisterNetEvent('XS-CriminalTablet:client:dealerSpawn', spawnDealer)
RegisterNetEvent('XS-CriminalTablet:client:dealerDespawn', despawnDealer)

-- Pick up an already-active spawn on resource start / late join.
CreateThread(function()
    Wait(2500)
    local status = lib.callback.await('XS-CriminalTablet:dealer:getStatus', false)
    if status and status.spawn then spawnDealer(status.spawn, Config.Dealer.pedModel) end
end)

if not hasTarget then
    CreateThread(function()
        local shown = false
        while true do
            Wait(500)
            local near = dealerPed and DoesEntityExist(dealerPed)
                and #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(dealerPed)) <= 2.5
            if near then
                if not shown then lib.showTextUI('[E] Talk to Dealer'); shown = true end
                if IsControlJustReleased(0, 38) then TriggerEvent('XS-CriminalTablet:client:talkToDealer') end
            elseif shown then
                lib.hideTextUI()
                shown = false
            end
        end
    end)
end
