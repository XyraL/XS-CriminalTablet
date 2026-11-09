-- ─────────────────────────────────────────────────────────────
-- War client: the raid HUD, the war meter, kill reporting, and the
-- stash-raid guidance (blip, compass arrow, live distance to the safe).
--
-- Nothing here decides anything — the server owns every outcome. This is
-- the part that makes a fight legible while it's happening.
-- ─────────────────────────────────────────────────────────────
local warState = nil
local stashWindow = nil
local stashBlip = nil
local testDefenders = {}   -- [scope:key] = { peds }

-- The server stamps every deadline with os.time()*1000, so the client has
-- to read the same wall clock. GetNetworkTime is a session timer with a
-- different epoch and would make every countdown nonsense.
local function nowMs() return GetCloudTimeAsInt() * 1000 end

-- ── kill reporting ──────────────────────────────────────────
-- The victim reports who killed them. The server only counts it if both
-- players really are on opposite sides of a live war, and it rate-limits
-- repeat kills on the same person.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end
    local victim, attacker, isDead = args[1], args[2], args[6]
    -- Game-event args arrive as numbers on most builds and booleans on
    -- some — accept either rather than silently never scoring a kill.
    if not (isDead == 1 or isDead == true) then return end
    if victim ~= PlayerPedId() then return end
    if not attacker or attacker == 0 or attacker == victim then return end
    if not IsPedAPlayer(attacker) then return end

    local killerPlayer = NetworkGetPlayerIndexFromPed(attacker)
    if killerPlayer == -1 then return end
    local killerServerId = GetPlayerServerId(killerPlayer)
    if killerServerId <= 0 then return end

    TriggerServerEvent('XS-CriminalTablet:server:reportWarKill', killerServerId)
    TriggerServerEvent('XS-CriminalTablet:server:reportGangKill', killerServerId)
end)

-- ── state ───────────────────────────────────────────────────
local myGangId = nil
local lastLeader = nil
local objectiveBlips = {}

AddEventHandler('XS-CriminalTablet:client:gangIdChanged', function(gangId) myGangId = gangId end)

local function mySide(state)
    if not state or not myGangId then return nil end
    if state.attackerId == myGangId then return 'attack' end
    if state.defenderId == myGangId then return 'defend' end
    return nil
end

local function hexToRgb(hex)
    if type(hex) ~= 'string' then return 245, 165, 36 end
    hex = hex:gsub('#', '')
    if #hex ~= 6 then return 245, 165, 36 end
    return tonumber(hex:sub(1, 2), 16) or 245, tonumber(hex:sub(3, 4), 16) or 165, tonumber(hex:sub(5, 6), 16) or 36
end

local function clearObjectiveBlips()
    for _, b in pairs(objectiveBlips) do RemoveBlip(b) end
    objectiveBlips = {}
end

-- One lettered blip per objective, coloured by whoever holds it.
local function updateObjectiveBlips(state)
    if not state or state.kind ~= 'war' or not state.objectives or #state.objectives == 0 then clearObjectiveBlips() return end
    local side = mySide(state)
    for _, o in ipairs(state.objectives) do
        local blip = objectiveBlips[o.id]
        if not blip then
            blip = AddBlipForCoord(o.x + 0.0, o.y + 0.0, o.z + 0.0)
            SetBlipSprite(blip, 38)
            SetBlipScale(blip, 0.9)
            SetBlipAsShortRange(blip, false)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(('Objective %s · %s'):format(o.id, o.label))
            EndTextCommandSetBlipName(blip)
            objectiveBlips[o.id] = blip
        end
        SetBlipColour(blip, o.owner == nil and 4 or (o.owner == side and 2 or 1))
        SetBlipFlashes(blip, o.contested or (o.taking ~= nil))
    end
end

-- Taking the lead and losing it both get a sound, so it registers even
-- mid-fight with the HUD out of sight.
local function leadCue(state)
    local lead = (state.scoreAttack or 0) - (state.scoreDefend or 0)
    local leader = lead > 0 and 'attack' or (lead < 0 and 'defend' or nil)
    if state.kind == 'war' and leader and leader ~= lastLeader and lastLeader ~= nil then
        if leader == mySide(state) then PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
        else PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true) end
        SendNUIMessage({ action = 'warLead', data = { side = leader } })
    end
    if leader then lastLeader = leader elseif lastLeader == nil then lastLeader = 'none' end
end

RegisterNetEvent('XS-CriminalTablet:client:sync', function(event, data)
    if event == 'war' then
        warState = data
        if data then leadCue(data) else lastLeader = nil end
        updateObjectiveBlips(data)
        SendNUIMessage({ action = 'warHud', data = data and { state = data, mine = mySide(data) } or nil })
    elseif event == 'warFeed' then
        SendNUIMessage({ action = 'warFeed', data = data })
    elseif event == 'stash' then
        stashWindow = data
        if stashBlip then RemoveBlip(stashBlip) stashBlip = nil end
        if stashWindow and stashWindow.coords then
            stashBlip = AddBlipForCoord(stashWindow.coords.x, stashWindow.coords.y, stashWindow.coords.z)
            SetBlipSprite(stashBlip, 500)
            SetBlipColour(stashBlip, 1)
            SetBlipScale(stashBlip, 1.1)
            SetBlipFlashes(stashBlip, true)
            SetBlipRoute(stashBlip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(('%s — Safe'):format(stashWindow.loserLabel or 'Rival'))
            EndTextCommandSetBlipName(stashBlip)
        end
    end
end)

CreateThread(function()
    Wait(4000)
    local res = lib.callback.await('XS-CriminalTablet:war:getState', false)
    if res then
        TriggerEvent('XS-CriminalTablet:client:sync', 'war', res.war)
        if res.stash then TriggerEvent('XS-CriminalTablet:client:sync', 'stash', res.stash) end
    end
end)

local function text(str, x, y, scale, r, g, b, a, centre)
    SetTextFont(4)
    SetTextScale(0.0, scale)
    SetTextColour(r, g, b, a)
    if centre then SetTextCentre(true) end
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(x, y)
end

-- ── world markers ───────────────────────────────────────────
-- The scoreboard itself is drawn by the page; the game only marks the
-- ground: the HQ ring in a raid, the objectives in a war.
local function drawWarMarkers()
    if warState.kind == 'raid' and warState.target then
        local t = warState.target
        local r, g, b = hexToRgb(warState.attackerColor)
        local size = (warState.radius or 40.0) * 2.0
        DrawMarker(1, t.x + 0.0, t.y + 0.0, t.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, size, size, 1.2, r, g, b, 50, false, false, 2, false, nil, nil, false)
    elseif warState.kind == 'war' then
        local side = mySide(warState)
        local size = (warState.objectiveRadius or 12.0) * 2.0
        for _, o in ipairs(warState.objectives or {}) do
            local r, g, b = 245, 245, 245
            if o.owner then r, g, b = hexToRgb(o.owner == 'attack' and warState.attackerColor or warState.defenderColor) end
            if o.contested then r, g, b = 240, 82, 95 end
            DrawMarker(1, o.x + 0.0, o.y + 0.0, o.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, size, size, 1.6, r, g, b, o.owner == side and 45 or 70, false, false, 2, false, nil, nil, false)
        end
    end
end

-- Compass arrow + live distance to the exposed safe.
local function drawStashGuidance()
    local pos = GetEntityCoords(PlayerPedId())
    local target = vec3(stashWindow.coords.x, stashWindow.coords.y, stashWindow.coords.z)
    local dist = #(pos - target)
    local remaining = math.max(0, math.floor((stashWindow.expiresAt - nowMs()) / 1000))

    DrawRect(0.5, 0.155, 0.24, 0.05, 0, 0, 0, 150)
    text(('%s SAFE EXPOSED'):format(string.upper(stashWindow.loserLabel or 'RIVAL')),
        0.5, 0.138, 0.34, 245, 165, 36, 240, true)
    text(('%.0fm · %02d:%02d left'):format(dist, math.floor(remaining / 60), remaining % 60),
        0.5, 0.160, 0.30, 200, 205, 212, 230, true)

    -- The arrow: rotate a marker above the player toward the safe.
    local heading = math.deg(math.atan(target.y - pos.y, target.x - pos.x)) - 90.0
    DrawMarker(20, pos.x, pos.y, pos.z + 1.35, 0.0, 0.0, 0.0, 0.0, 180.0, heading,
        0.35, 0.35, 0.35, 245, 165, 36, 200, false, false, 2, false, nil, nil, false)

    if dist <= Config.War.stash.lootRadius then
        DrawMarker(1, target.x, target.y, target.z - 0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            1.2, 1.2, 0.5, 245, 165, 36, 120, false, false, 2, false, nil, nil, false)
    end
end

CreateThread(function()
    while true do
        local sleep = 400
        if warState and warState.phase ~= 'finished' then
            sleep = 0
            drawWarMarkers()
        end
        if stashWindow and stashWindow.coords then
            sleep = 0
            drawStashGuidance()
        end
        Wait(sleep)
    end
end)

-- ── looting ─────────────────────────────────────────────────
RegisterNetEvent('XS-CriminalTablet:client:tryLootStash', function(coords)
    if not stashWindow then
        lib.notify({ description = 'Nothing to take here.', type = 'error' })
        return
    end

    local finished = XSAnim.Progress({
        duration = Config.War.stash.lootSeconds * 1000,
        label = 'Breaking into the locker...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, combat = true },
        anims = { { dict = 'anim@heists@ornate_bank@grab_cash', clip = 'grab' } },
    })
    if not finished then return end

    local res = lib.callback.await('XS-CriminalTablet:war:lootStash', false)
    if not res or not res.ok then
        lib.notify({ description = (res and res.error) or 'Could not get in', type = 'error' })
        return
    end

    local loot = res.loot or {}
    lib.notify({
        description = ('You are in — $%d and %d item stack%s.'):format(
            loot.cash or 0, #(loot.items or {}), #(loot.items or {}) == 1 and '' or 's'),
        type = 'success',
    })
end)

-- ── solo test mode defenders ────────────────────────────────
-- Only the client that is closest to the spawn point actually creates the
-- peds, so a five-person crew doesn't spawn five sets.
local function despawnTest(key)
    for _, ped in ipairs(testDefenders[key] or {}) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    testDefenders[key] = nil
end

RegisterNetEvent('XS-CriminalTablet:client:testModeSpawn', function(data)
    local key = data.scope .. ':' .. tostring(data.key)
    despawnTest(key)

    local origin = vec3(data.coords.x, data.coords.y, data.coords.z)
    if #(GetEntityCoords(PlayerPedId()) - origin) > 300.0 then return end
    if not IsModelValid(data.model) or not XSModel.Load(data.model) then return end

    local peds = {}
    for i = 1, data.count do
        local angle = (i / data.count) * math.pi * 2
        local x = origin.x + math.cos(angle) * data.radius
        local y = origin.y + math.sin(angle) * data.radius
        local found, z = GetGroundZFor_3dCoord(x, y, origin.z + 10.0, false)

        local ped = CreatePed(4, data.model, x, y, found and z or origin.z, 0.0, true, false)
        GiveWeaponToPed(ped, joaat(data.weapon), 250, false, true)
        SetPedAccuracy(ped, data.accuracy or 40)
        SetPedCombatAttributes(ped, 46, true)
        SetPedRelationshipGroupHash(ped, joaat('HATES_PLAYER'))
        SetPedAsEnemy(ped, true)
        TaskCombatPed(ped, PlayerPedId(), 0, 16)
        peds[#peds + 1] = ped
    end
    testDefenders[key] = peds

    lib.notify({ description = 'Test mode: NPC defenders are up.', type = 'inform' })

    -- Tell the server once they're all down so the contest can resolve.
    CreateThread(function()
        while testDefenders[key] do
            Wait(2000)
            local alive = 0
            for _, ped in ipairs(testDefenders[key] or {}) do
                if DoesEntityExist(ped) and not IsEntityDead(ped) then alive = alive + 1 end
            end
            if alive == 0 then
                TriggerServerEvent('XS-CriminalTablet:server:testModeCleared', data.scope, data.key)
                break
            end
        end
    end)
end)

RegisterNetEvent('XS-CriminalTablet:client:testModeDespawn', function(data)
    despawnTest(data.scope .. ':' .. tostring(data.key))
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for key in pairs(testDefenders) do despawnTest(key) end
    if stashBlip then RemoveBlip(stashBlip) end
    clearObjectiveBlips()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    warState, stashWindow, lastLeader = nil, nil, nil
    if stashBlip then RemoveBlip(stashBlip) stashBlip = nil end
    clearObjectiveBlips()
    SendNUIMessage({ action = 'warHud', data = nil })
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    local res = lib.callback.await('XS-CriminalTablet:war:getState', false)
    if res then
        TriggerEvent('XS-CriminalTablet:client:sync', 'war', res.war)
        if res.stash then TriggerEvent('XS-CriminalTablet:client:sync', 'stash', res.stash) end
    end
end)
