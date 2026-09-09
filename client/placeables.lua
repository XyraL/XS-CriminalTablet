-- ─────────────────────────────────────────────────────────────
-- Placeables client: spawns everyone's placed benches/peds/vaults,
-- prompts to open a nearby vault, and runs the Boss-facing placement
-- preview (move a ghost prop, confirm, server validates + persists).
-- ─────────────────────────────────────────────────────────────
Placeables = {}

local spawned = {}      -- [gangId..':'..kind..':'..unlockId] = entity handle
local vaultRows = {}     -- same key space, vault rows only (for the proximity loop)
local pedRows = {}       -- same key space, dealer ped rows only (for the proximity loop)
local benchRows = {}     -- same key space, bench rows only (for the proximity loop)

local function placementKey(p) return p.gang_id .. ':' .. p.kind .. ':' .. p.unlock_id end

local function despawnAll()
    for _, handle in pairs(spawned) do
        if DoesEntityExist(handle) then DeleteEntity(handle) end
    end
    spawned = {}
end

local hasTarget = GetResourceState('ox_target') == 'started'

local function spawnOne(p)
    if not IsModelValid(p.model) then
        print(('^1[XS-CriminalTablet]^0 placement "%s" has an invalid model (%s) — fix the model in config.lua and re-place it'):format(p.label, p.model))
        return
    end
    lib.requestModel(p.model)
    local handle
    if p.kind == 'ped' then
        handle = CreatePed(4, p.model, p.x, p.y, p.z, p.heading, false, false)
        SetEntityInvincible(handle, true)
        SetBlockingOfNonTemporaryEvents(handle, true)
    else
        handle = CreateObject(p.model, p.x, p.y, p.z, false, false, false)
        SetEntityHeading(handle, p.heading)
    end
    FreezeEntityPosition(handle, true)
    spawned[placementKey(p)] = handle

    if p.kind == 'vault' then
        vaultRows[placementKey(p)] = p
        if hasTarget then
            exports.ox_target:addLocalEntity(handle, {
                { name = 'xs_open_vault', label = 'Open Gang Vault', icon = 'fas fa-box',
                  onSelect = function() TriggerServerEvent('XS-CriminalTablet:server:openVault') end },
            })
        end
    elseif p.kind == 'bench' then
        benchRows[placementKey(p)] = p
        if hasTarget then
            exports.ox_target:addLocalEntity(handle, {
                { name = 'xs_use_bench', label = 'Use ' .. (p.label or 'Bench'), icon = 'fas fa-screwdriver-wrench',
                  onSelect = function() TriggerEvent('XS-CriminalTablet:client:openCraftBench', p.label, vec3(p.x, p.y, p.z)) end },
            })
        end
    elseif p.kind == 'ped' then
        pedRows[placementKey(p)] = p
        if hasTarget then
            exports.ox_target:addLocalEntity(handle, {
                { name = 'xs_talk_dealer', label = 'Talk to ' .. (p.label or 'Dealer'), icon = 'fas fa-comments',
                  onSelect = function() TriggerEvent('XS-CriminalTablet:client:talkToDealer') end },
            })
        end
    end
end

local function spawnAll(list)
    despawnAll()
    vaultRows = {}
    pedRows = {}
    benchRows = {}
    for _, p in ipairs(list or {}) do
        -- one bad model (e.g. a typo'd prop name) must not stop the rest
        -- of the gang's placements — especially the vault — from spawning.
        local ok, err = pcall(spawnOne, p)
        if not ok then print(('^1[XS-CriminalTablet]^0 failed to spawn placement "%s": %s'):format(p.label, err)) end
    end
end

RegisterNetEvent('XS-CriminalTablet:client:placeablesUpdate', spawnAll)

CreateThread(function()
    Wait(2500)
    spawnAll(lib.callback.await('XS-CriminalTablet:placeables:getAll', false))
end)

-- ── vault/dealer proximity prompts (fallback when ox_target isn't installed) ──
if not hasTarget then
    local function nearestIn(rows)
        local pos = GetEntityCoords(PlayerPedId())
        local nearest, nearestDist = nil, 2.5
        for _, p in pairs(rows) do
            local d = #(pos - vec3(p.x, p.y, p.z))
            if d <= nearestDist then nearest, nearestDist = p, d end
        end
        return nearest
    end

    CreateThread(function()
        local shown = nil
        while true do
            Wait(500)
            local vault = nearestIn(vaultRows)
            local ped = not vault and nearestIn(pedRows) or nil
            local bench = not vault and not ped and nearestIn(benchRows) or nil

            if vault then
                if shown ~= 'vault' then lib.showTextUI('[E] Open Gang Vault'); shown = 'vault' end
                if IsControlJustReleased(0, 38) then TriggerServerEvent('XS-CriminalTablet:server:openVault') end
            elseif ped then
                if shown ~= 'ped' then lib.showTextUI('[E] Talk to Dealer'); shown = 'ped' end
                if IsControlJustReleased(0, 38) then TriggerEvent('XS-CriminalTablet:client:talkToDealer') end
            elseif bench then
                if shown ~= 'bench' then lib.showTextUI('[E] Use ' .. (bench.label or 'Bench')); shown = 'bench' end
                if IsControlJustReleased(0, 38) then
                    TriggerEvent('XS-CriminalTablet:client:openCraftBench', bench.label, vec3(bench.x, bench.y, bench.z))
                end
            elseif shown then
                lib.hideTextUI()
                shown = nil
            end
        end
    end)
end

-- config.lua is a shared script, so the model for any kind/id is already
-- known client-side — no server round trip needed to start placement.
function Placeables.ResolveModel(kind, unlockId)
    if kind == 'vault' then return Config.Vault.model end
    local cfgKind = kind == 'bench' and 'benches' or 'peds'
    for _, tierDef in pairs(Config.TierUnlocks) do
        for _, u in ipairs(tierDef[cfgKind] or {}) do
            if u.id == unlockId then return u.model end
        end
    end
    return nil
end

-- ── placement preview ──
-- Ghost prop floats in front of the player; scroll adjusts distance,
-- Q/E rotate it, ENTER confirms, BACKSPACE cancels.
function Placeables.StartPlacement(kind, unlockId, model)
    if not IsModelValid(model) then
        lib.notify({ description = ('Bad model for this unlock (%s) — tell an admin to fix config.lua'):format(model), type = 'error' })
        return
    end
    lib.requestModel(model)
    local ped = PlayerPedId()
    local dist = 2.0
    local rot = 0.0
    local ghost = CreateObject(model, 0.0, 0.0, 0.0, false, false, false)
    SetEntityAlpha(ghost, 180, false)
    SetEntityCollision(ghost, false, false)

    lib.showTextUI('[Scroll] Distance  [Q/E] Rotate  [Enter] Place  [Backspace] Cancel')

    local placing = true
    while placing do
        Wait(0)
        DisableControlAction(0, 14, true)  -- scroll up
        DisableControlAction(0, 15, true)  -- scroll down
        DisableControlAction(0, 51, true)  -- E
        DisableControlAction(0, 44, true)  -- Q
        DisableControlAction(0, 18, true)  -- Enter
        DisableControlAction(0, 194, true) -- Backspace

        if IsDisabledControlJustPressed(0, 14) then dist = math.min(5.0, dist + 0.25) end
        if IsDisabledControlJustPressed(0, 15) then dist = math.max(0.5, dist - 0.25) end
        if IsDisabledControlPressed(0, 51) then rot = rot + 2.0 end  -- E: rotate right
        if IsDisabledControlPressed(0, 44) then rot = rot - 2.0 end  -- Q: rotate left

        local pCoords = GetEntityCoords(ped)
        local pHeading = GetEntityHeading(ped)
        local fwd = vec3(-math.sin(math.rad(pHeading)), math.cos(math.rad(pHeading)), 0.0)
        local target = pCoords + fwd * dist
        SetEntityCoords(ghost, target.x, target.y, target.z - 0.95, false, false, false, false)
        SetEntityHeading(ghost, pHeading + rot)

        if IsDisabledControlJustPressed(0, 18) then -- Enter
            placing = false
            local finalCoords = GetEntityCoords(ghost)
            local finalHeading = GetEntityHeading(ghost)
            DeleteEntity(ghost)
            lib.hideTextUI()
            local res = lib.callback.await('XS-CriminalTablet:placeables:place', false, kind, unlockId, finalCoords, finalHeading)
            if res and res.ok then
                lib.notify({ description = 'Placed.', type = 'success' })
            else
                lib.notify({ description = (res and res.error) or 'Failed to place', type = 'error' })
            end
        elseif IsDisabledControlJustPressed(0, 194) then -- Backspace
            placing = false
            DeleteEntity(ghost)
            lib.hideTextUI()
        end
    end
end
