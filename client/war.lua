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
RegisterNetEvent('XS-CriminalTablet:client:sync', function(event, data)
    if event == 'war' then
        warState = data
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
        warState = res.war
        if res.stash then TriggerEvent('XS-CriminalTablet:client:sync', 'stash', res.stash) end
    end
end)

-- ── HUD ─────────────────────────────────────────────────────
local function hexToRgb(hex)
    if type(hex) ~= 'string' then return 245, 165, 36 end
    hex = hex:gsub('#', '')
    if #hex ~= 6 then return 245, 165, 36 end
    return tonumber(hex:sub(1, 2), 16) or 245, tonumber(hex:sub(3, 4), 16) or 165, tonumber(hex:sub(5, 6), 16) or 36
end

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

local function drawRaidHud()
    local x, y = 0.5, 0.06
    local remaining = math.max(0, math.floor(((warState.phase == 'prep' and warState.startsAt or warState.endsAt) - nowMs()) / 1000))

    DrawRect(x, y + 0.012, 0.30, 0.075, 0, 0, 0, 160)

    if warState.phase == 'prep' then
        text(('RAID INCOMING — %s'):format(warState.attackerLabel), x, y - 0.012, 0.42, 229, 72, 77, 240, true)
        text(('Goes live in %ds'):format(remaining), x, y + 0.018, 0.34, 200, 205, 212, 230, true)
        return
    end

    text(('%s  vs  %s'):format(warState.attackerLabel, warState.defenderLabel), x, y - 0.018, 0.40, 235, 237, 240, 240, true)

    -- Hold meter
    local w, h = 0.26, 0.014
    local pct = math.max(0, math.min(1, (warState.holdProgress or 0) / math.max(1, warState.holdTarget or 1)))
    DrawRect(x, y + 0.016, w, h, 40, 44, 52, 220)
    local r, g, b = hexToRgb(warState.attackerColor)
    DrawRect(x - w / 2 + (w * pct) / 2, y + 0.016, w * pct, h, r, g, b, 235)

    text(('%d attacking · %d defending · %ds left'):format(
        warState.scoreAttack or 0, warState.scoreDefend or 0, remaining), x, y + 0.030, 0.30, 150, 156, 166, 220, true)
end

local function drawWarHud()
    local x, y = 0.5, 0.06
    local remaining = math.max(0, math.floor((warState.endsAt - nowMs()) / 1000))
    local mins, secs = math.floor(remaining / 60), remaining % 60

    DrawRect(x, y + 0.012, 0.32, 0.075, 0, 0, 0, 160)
    text(('WAR — %s  %d : %d  %s'):format(
        warState.attackerLabel, warState.scoreAttack or 0, warState.scoreDefend or 0, warState.defenderLabel),
        x, y - 0.018, 0.40, 235, 237, 240, 240, true)

    -- A single bar with the midpoint as parity: it leans toward whoever
    -- is winning, which reads faster than two separate numbers.
    local w, h = 0.28, 0.014
    local lead = (warState.scoreAttack or 0) - (warState.scoreDefend or 0)
    local frac = 0.5 + (lead / math.max(1, warState.scoreToWin or 15)) * 0.5
    frac = math.max(0.02, math.min(0.98, frac))

    DrawRect(x, y + 0.016, w, h, 40, 44, 52, 220)
    local ar, ag, ab = hexToRgb(warState.attackerColor)
    DrawRect(x - w / 2 + (w * frac) / 2, y + 0.016, w * frac, h, ar, ag, ab, 235)
    DrawRect(x, y + 0.016, 0.002, h + 0.006, 255, 255, 255, 200)

    text(('%02d:%02d left · first to %d ahead wins'):format(mins, secs, warState.scoreToWin or 15),
        x, y + 0.030, 0.30, 150, 156, 166, 220, true)
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
            if warState.kind == 'raid' then drawRaidHud() else drawWarHud() end
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
        label = 'Cracking the safe...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, combat = true },
        anims = { { dict = 'anim@heists@ornate_bank@grab_cash', clip = 'grab' } },
    })
    if not finished then return end

    local res = lib.callback.await('XS-CriminalTablet:war:lootStash', false)
    if not res or not res.ok then
        lib.notify({ description = (res and res.error) or 'Could not crack it', type = 'error' })
        return
    end

    local loot = res.loot or {}
    lib.notify({
        description = ('Cracked it — $%d and %d item stack%s.'):format(
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
    if not IsModelValid(data.model) then return end

    lib.requestModel(data.model)
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
end)
