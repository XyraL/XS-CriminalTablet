-- ─────────────────────────────────────────────────────────────
-- Crafting bench client: a dedicated NUI panel instead of a plain list,
-- with a cinematic camera push-in toward the bench while it's open. The
-- camera/animation here only use core scripting natives (CreateCamWithParams,
-- PointCamAtCoord, TaskStartScenarioInPlace with a real GTA scenario) — no
-- guessed asset names, unlike props/peds, so this should always work.
-- ─────────────────────────────────────────────────────────────
local isOpen = false
local craftCam = nil

local function startCraftCam(benchCoords)
    local ped = PlayerPedId()
    local playerCoords = GetEntityCoords(ped)
    local dir = benchCoords - playerCoords
    local len = #dir
    if len < 0.01 then dir = vec3(1.0, 0.0, 0.0) else dir = dir / len end
    local side = vec3(-dir.y, dir.x, 0.0)

    local camPos = playerCoords - (dir * 1.0) + (side * 0.55) + vec3(0.0, 0.0, 1.55)
    craftCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', camPos.x, camPos.y, camPos.z, 0.0, 0.0, 0.0, 40.0)
    PointCamAtCoord(craftCam, benchCoords.x, benchCoords.y, benchCoords.z + 0.25)
    SetCamActive(craftCam, true)
    RenderScriptCams(true, true, 700, true, true)

    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_HAMMERING', 0, true)
end

local function stopCraftCam()
    ClearPedTasks(PlayerPedId())
    if craftCam then
        RenderScriptCams(false, true, 700, true, true)
        DestroyCam(craftCam, false)
        craftCam = nil
    end
end

local function closeCraftBench()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'craftClose' })
    stopCraftCam()
end

RegisterNetEvent('XS-CriminalTablet:client:openCraftBench', function(benchLabel, benchCoords)
    if isOpen then return end
    local recipes = lib.callback.await('XS-CriminalTablet:crafting:getRecipes', false)
    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'craftOpen', label = benchLabel, recipes = recipes or {} })
    startCraftCam(benchCoords)
end)

RegisterNUICallback('craft:close', function(_, cb)
    closeCraftBench()
    cb({})
end)

RegisterNUICallback('craft:make', function(data, cb)
    local res = lib.callback.await('XS-CriminalTablet:crafting:craft', false, data.id)
    cb(res or {})
end)

RegisterNUICallback('craft:escape', function(_, cb)
    closeCraftBench()
    cb({})
end)
