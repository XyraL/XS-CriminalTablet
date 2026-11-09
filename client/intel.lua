-- ─────────────────────────────────────────────────────────────
-- Rival intel on the map: a red pulse where it happened, gone after a
-- minute. The alert text itself comes from the server as a notification.
-- ─────────────────────────────────────────────────────────────
local pings = {}

local function clearPings()
    for _, p in ipairs(pings) do
        if DoesBlipExist(p[1]) then RemoveBlip(p[1]) end
        if DoesBlipExist(p[2]) then RemoveBlip(p[2]) end
    end
    pings = {}
end

RegisterNetEvent('XS-CriminalTablet:client:sync', function(event, data)
    if event ~= 'intel' or type(data) ~= 'table' or not data.x or not (Config.Intel and Config.Intel.mapPing) then return end
    local area = AddBlipForRadius(data.x + 0.0, data.y + 0.0, (data.z or 0.0) + 0.0, 45.0)
    SetBlipColour(area, 1)
    SetBlipAlpha(area, 110)
    local pin = AddBlipForCoord(data.x + 0.0, data.y + 0.0, (data.z or 0.0) + 0.0)
    SetBlipSprite(pin, 161)
    SetBlipColour(pin, 1)
    SetBlipScale(pin, 0.9)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(data.message or 'Rival spotted')
    EndTextCommandSetBlipName(pin)
    local entry = { area, pin }
    pings[#pings + 1] = entry
    PlaySoundFrontend(-1, 'CHECKPOINT_MISSED', 'HUD_MINI_GAME_SOUNDSET', true)
    SetTimeout(60000, function()
        if DoesBlipExist(entry[1]) then RemoveBlip(entry[1]) end
        if DoesBlipExist(entry[2]) then RemoveBlip(entry[2]) end
    end)
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', clearPings)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then clearPings() end
end)
