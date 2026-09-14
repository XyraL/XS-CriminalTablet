-- ─────────────────────────────────────────────────────────────
-- Staff-made gang blips. The server sends every blip to everyone and
-- each client decides what it may draw, so a crew-only marker never
-- needs its own broadcast.
-- ─────────────────────────────────────────────────────────────
local handles = {}
local lastList = {}
local myGangId = nil

local function clear()
    for _, b in ipairs(handles) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    handles = {}
end

local function draw(list)
    clear()
    for _, b in ipairs(list or {}) do
        local visible = b.visibility == 'all' or (myGangId and b.gangId == myGangId)
        if visible and b.coords then
            local blip = AddBlipForCoord(b.coords.x + 0.0, b.coords.y + 0.0, b.coords.z + 0.0)
            SetBlipSprite(blip, math.floor(b.sprite or 84))
            SetBlipColour(blip, math.floor(b.color or 0))
            SetBlipScale(blip, (b.scale or 0.8) + 0.0)
            SetBlipAsShortRange(blip, b.shortRange ~= false)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(b.label or 'Crew')
            EndTextCommandSetBlipName(blip)
            handles[#handles + 1] = blip
        end
    end
end

RegisterNetEvent('XS-CriminalTablet:client:blipsUpdate', function(list)
    lastList = list or {}
    draw(lastList)
end)

RegisterNetEvent('XS-CriminalTablet:client:gangIdChanged', function(gangId)
    if myGangId == gangId then return end
    myGangId = gangId
    draw(lastList)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then clear() end
end)
