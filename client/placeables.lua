-- ─────────────────────────────────────────────────────────────
-- Placeables client: spawns every gang's placed property, wires the
-- interactions each kind needs, and runs the placement preview (move a
-- ghost prop, confirm, server validates + persists).
--
-- Gang-locked zones are enforced server-side on every action; here they
-- only decide whether a rival sees the interaction offered at all.
-- ─────────────────────────────────────────────────────────────
Placeables = {}

local spawned = {}       -- [gang:kind:unlockId] = entity handle
local interactive = {}   -- same key space, rows that need a proximity prompt
local myGangId = nil

local function hasTarget() return XSTarget.Ready() end

local function placementKey(p) return p.gang_id .. ':' .. p.kind .. ':' .. p.unlock_id end

local function despawnAll()
    for _, handle in pairs(spawned) do
        if DoesEntityExist(handle) then
            if hasTarget() then pcall(function() exports.ox_target:removeLocalEntity(handle) end) end
            DeleteEntity(handle)
        end
    end
    spawned = {}
    interactive = {}
end

-- What each kind offers when you walk up to it. `mineOnly` entries are
-- hidden from rivals — the server refuses them anyway, so showing them
-- would just be a broken-looking option.
local INTERACTIONS = {
    vault = {
        label = 'Open Gang Vault', icon = 'fas fa-vault', mineOnly = true,
        run = function() TriggerServerEvent('XS-CriminalTablet:server:openVault') end,
    },
    bench = {
        label = 'Use Workbench', icon = 'fas fa-screwdriver-wrench', mineOnly = true,
        run = function(p) TriggerEvent('XS-CriminalTablet:client:openCraftBench', p.label, vec3(p.x, p.y, p.z)) end,
    },
    garage = {
        label = 'Gang Garage', icon = 'fas fa-warehouse', mineOnly = true,
        run = function() TriggerEvent('XS-CriminalTablet:client:openGarage') end,
    },
    hq = {
        label = 'Crew HQ', icon = 'fas fa-satellite-dish', mineOnly = true,
        run = function() TriggerEvent('XS-CriminalTablet:client:openDeviceFromWorld') end,
    },
    -- The safe is the one thing a RIVAL is meant to walk up to, during a
    -- stash-raid window. Own crew gets nothing from it.
    safe = {
        label = 'Crack The Safe', icon = 'fas fa-sack-dollar', mineOnly = false,
        run = function(p) TriggerEvent('XS-CriminalTablet:client:tryLootStash', vec3(p.x, p.y, p.z)) end,
    },
}

local function isMine(p) return myGangId ~= nil and p.gang_id == myGangId end

-- Top of whatever solid thing is under (x, y), starting the probe above
-- the player's head. Returns nil when the ray finds nothing at all.
local function surfaceBelow(x, y, fromZ)
    local ray = StartShapeTestRay(x, y, fromZ + 1.5, x, y, fromZ - 6.0, 1 | 16 | 256, PlayerPedId(), 4)
    -- GetShapeTestResult's hit is a boolean here, not a number.
    local _, hit, endCoords = GetShapeTestResult(ray)
    if hit and endCoords then return endCoords.z end

    local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, fromZ + 1.5, false)
    if found then return gz end
    return nil
end

local function spawnOne(p)
    if not IsModelValid(p.model) then
        print(('^1[XS-CriminalTablet]^0 placement "%s" has an invalid model (%s) - fix it in config.lua and re-place it'):format(
            p.label, p.model))
        return
    end
    lib.requestModel(p.model)

    local handle = CreateObject(p.model, p.x, p.y, p.z, false, false, false)
    SetEntityHeading(handle, p.heading)
    FreezeEntityPosition(handle, true)
    spawned[placementKey(p)] = handle

    local def = INTERACTIONS[p.kind]
    if not def then return end
    if def.mineOnly and not isMine(p) then return end
    if not def.mineOnly and isMine(p) then return end

    if hasTarget() then
        exports.ox_target:addLocalEntity(handle, {
            {
                name = 'xs_place_' .. p.kind,
                label = def.label,
                icon = def.icon,
                distance = 2.5,
                onSelect = function() def.run(p) end,
            },
        })
    else
        interactive[placementKey(p)] = { row = p, def = def }
    end
end

local function spawnAll(list)
    despawnAll()
    for _, p in ipairs(list or {}) do
        -- One bad model must not stop the rest of a gang's property —
        -- especially the vault — from spawning.
        local ok, err = pcall(spawnOne, p)
        if not ok then print(('^1[XS-CriminalTablet]^0 failed to spawn placement "%s": %s'):format(p.label, err)) end
    end
end

local lastList = {}
RegisterNetEvent('XS-CriminalTablet:client:placeablesUpdate', function(list)
    lastList = list or {}
    spawnAll(lastList)
end)

-- Which gang we're in decides which interactions show, so a membership
-- change has to re-wire every placement.
RegisterNetEvent('XS-CriminalTablet:client:gangIdChanged', function(gangId)
    if myGangId == gangId then return end
    myGangId = gangId
    spawnAll(lastList)
end)

CreateThread(function()
    Wait(2500)
    local me = lib.callback.await('XS-CriminalTablet:getSnapshot', false)
    myGangId = me and me.gang and me.gang.id or nil
    lastList = lib.callback.await('XS-CriminalTablet:placeables:getAll', false) or {}
    spawnAll(lastList)
end)

-- ── proximity prompts (fallback when ox_target isn't installed) ──
-- The thread always runs and asks per tick, because whether ox_target is
-- up is not knowable while this file is still being parsed.
CreateThread(function()
    local shownKey = nil
    while true do
        Wait(500)
        if not hasTarget() then
            local pos = GetEntityCoords(PlayerPedId())
            local nearestKey, nearest, nearestDist = nil, nil, 2.5

            for k, entry in pairs(interactive) do
                local d = #(pos - vec3(entry.row.x, entry.row.y, entry.row.z))
                if d <= nearestDist then nearestKey, nearest, nearestDist = k, entry, d end
            end

            if nearest then
                if shownKey ~= nearestKey then
                    lib.showTextUI('[E] ' .. nearest.def.label)
                    shownKey = nearestKey
                end
                if IsControlJustReleased(0, 38) then nearest.def.run(nearest.row) end
            elseif shownKey then
                lib.hideTextUI()
                shownKey = nil
            end
        end
    end
end)

-- config.lua is a shared script, so the model for any unlock is already
-- known client-side — no server round trip needed to start placement.
function Placeables.ResolveUnlock(unlockId)
    for _, entries in pairs(Config.TierUnlocks) do
        for _, u in ipairs(entries) do
            if u.id == unlockId then return u end
        end
    end
    return nil
end

-- ── placement preview ──
-- Ghost prop floats in front of the player; scroll adjusts distance,
-- Q/E rotate, ENTER confirms, BACKSPACE cancels.
function Placeables.StartPlacement(unlockId)
    local def = Placeables.ResolveUnlock(unlockId)
    if not def then
        lib.notify({ description = 'Unknown unlock.', type = 'error' })
        return
    end
    if not IsModelValid(def.model) then
        lib.notify({ description = ('Bad model for this unlock (%s) — tell staff to fix config.lua'):format(def.model), type = 'error' })
        return
    end

    lib.requestModel(def.model)
    local ped = PlayerPedId()
    local dist, rot, zOff = 2.0, 0.0, 0.0
    local ghost = CreateObject(def.model, 0.0, 0.0, 0.0, false, false, false)
    SetEntityAlpha(ghost, 180, false)
    SetEntityCollision(ghost, false, false)

    lib.showTextUI(
        '[Scroll] Distance   [Q/E] Rotate   [Arrow Up/Down] Height   ' ..
        '[Shift] Faster   [G] Re-seat   [Enter] Place   [Backspace] Cancel')

    local placing = true
    while placing do
        Wait(0)
        DisableControlAction(0, 14, true)  -- scroll up
        DisableControlAction(0, 15, true)  -- scroll down
        DisableControlAction(0, 51, true)  -- E
        DisableControlAction(0, 44, true)  -- Q
        DisableControlAction(0, 18, true)  -- Enter
        DisableControlAction(0, 194, true) -- Backspace
        DisableControlAction(0, 172, true) -- arrow up
        DisableControlAction(0, 173, true) -- arrow down
        DisableControlAction(0, 47, true)  -- G

        if IsDisabledControlJustPressed(0, 14) then dist = math.min(6.0, dist + 0.25) end
        if IsDisabledControlJustPressed(0, 15) then dist = math.max(0.5, dist - 0.25) end
        if IsDisabledControlPressed(0, 51) then rot = rot + 2.0 end
        if IsDisabledControlPressed(0, 44) then rot = rot - 2.0 end

        -- Height. Fine by default so a laptop can sit flush on a desk,
        -- coarse with shift when you are lifting it onto a roof.
        local step = IsControlPressed(0, 21) and 0.10 or 0.01
        if IsDisabledControlPressed(0, 172) then zOff = math.min(5.0, zOff + step) end
        if IsDisabledControlPressed(0, 173) then zOff = math.max(-3.0, zOff - step) end
        if IsDisabledControlJustPressed(0, 47) then zOff = 0.0 end

        local pCoords = GetEntityCoords(ped)
        local pHeading = GetEntityHeading(ped)
        local fwd = vec3(-math.sin(math.rad(pHeading)), math.cos(math.rad(pHeading)), 0.0)
        local target = pCoords + fwd * dist

        -- Sit it on whatever is actually under it — a desk, a crate, a
        -- roof — rather than assuming the floor is at the player's feet.
        local baseZ = surfaceBelow(target.x, target.y, pCoords.z + 1.0) or (target.z - 0.95)
        SetEntityCoords(ghost, target.x, target.y, baseZ + zOff, false, false, false, false)
        SetEntityHeading(ghost, pHeading + rot)

        if IsDisabledControlJustPressed(0, 18) then
            placing = false
            local finalCoords = GetEntityCoords(ghost)
            local finalHeading = GetEntityHeading(ghost)
            DeleteEntity(ghost)
            lib.hideTextUI()
            local res = lib.callback.await('XS-CriminalTablet:placeables:place', false, unlockId, finalCoords, finalHeading)
            lib.notify({
                description = (res and res.ok) and ('%s placed.'):format(def.label) or ((res and res.error) or 'Failed to place'),
                type = (res and res.ok) and 'success' or 'error',
            })
        elseif IsDisabledControlJustPressed(0, 194) then
            placing = false
            DeleteEntity(ghost)
            lib.hideTextUI()
        end
    end
end
