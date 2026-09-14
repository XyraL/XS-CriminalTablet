-- ─────────────────────────────────────────────────────────────
-- Field actions: the player-on-player half of the radial (cuff, bag,
-- trunk, carry, escort, hostage, search & rob).
--
-- These are the actions most likely to collide with a police or
-- inventory script, so every one of them is individually switchable in
-- Config.Radial.actions — and the restrained state lives HERE rather
-- than on either client, so neither the aggressor nor the victim can
-- decide on their own whether someone is cuffed.
-- ─────────────────────────────────────────────────────────────
Field = {}

local restrained = {}   -- [citizenid] = { cuffed, bagged, carriedBy, hostageOf }

local function stateOf(cid)
    restrained[cid] = restrained[cid] or { cuffed = false, bagged = false, carriedBy = nil, hostageOf = nil }
    return restrained[cid]
end
Field.StateOf = stateOf

local function enabled(action)
    local a = Config.Radial.actions[action]
    return Config.Radial.enabled and a and a.enabled
end

-- Shared gate: the action has to be on, both players real, and close
-- enough that the animation isn't happening across the street.
local function pair(src, targetSrc, action)
    if not enabled(action) then return nil, nil, 'that action is disabled here' end

    targetSrc = tonumber(targetSrc)
    if not targetSrc or targetSrc == src then return nil, nil, 'no target' end

    local srcPed, targetPed = GetPlayerPed(src), GetPlayerPed(targetSrc)
    if not targetPed or targetPed == 0 then return nil, nil, 'they are gone' end
    if #(GetEntityCoords(srcPed) - GetEntityCoords(targetPed)) > 3.0 then return nil, nil, 'get closer' end

    local targetCid = Framework.GetCitizenId(targetSrc)
    if not targetCid then return nil, nil, 'no character' end
    return targetSrc, targetCid, nil
end

local function needsItem(src, item)
    if not item or item == '' then return true end
    local count = exports.ox_inventory:GetItemCount(src, item)
    return (count or 0) >= 1
end

-- ── cuffing ─────────────────────────────────────────────────
function Field.Cuff(src, targetSrc)
    local t, cid, err = pair(src, targetSrc, 'cuff')
    if not t then return false, err end

    local state = stateOf(cid)
    -- Uncuffing never needs the item — only putting them on does.
    if not state.cuffed and not needsItem(src, Config.Radial.cuffItem) then
        return false, ('you need %s'):format(Config.Radial.cuffItem)
    end

    state.cuffed = not state.cuffed
    TriggerClientEvent('XS-CriminalTablet:client:setRestraint', t, 'cuffed', state.cuffed)
    Framework.Notify(t, state.cuffed and 'You have been cuffed.' or 'The cuffs are off.', 'inform')
    return true, nil, state.cuffed
end

function Field.Bag(src, targetSrc)
    local t, cid, err = pair(src, targetSrc, 'bag')
    if not t then return false, err end
    if not needsItem(src, Config.Radial.bagItem) then
        return false, ('you need %s'):format(Config.Radial.bagItem)
    end

    local state = stateOf(cid)
    state.bagged = not state.bagged
    TriggerClientEvent('XS-CriminalTablet:client:setRestraint', t, 'bagged', state.bagged)
    return true, nil, state.bagged
end

-- ── moving people ───────────────────────────────────────────
function Field.Carry(src, targetSrc)
    local t, cid, err = pair(src, targetSrc, 'carry')
    if not t then return false, err end

    local state = stateOf(cid)
    if state.carriedBy and state.carriedBy ~= src then return false, 'someone else has them' end

    state.carriedBy = state.carriedBy and nil or src
    TriggerClientEvent('XS-CriminalTablet:client:setCarried', t, state.carriedBy and src or nil, 'carry')
    return true, nil, state.carriedBy ~= nil
end

function Field.Escort(src, targetSrc)
    local t, cid, err = pair(src, targetSrc, 'escort')
    if not t then return false, err end

    local state = stateOf(cid)
    if not state.cuffed then return false, 'cuff them first' end
    if state.carriedBy and state.carriedBy ~= src then return false, 'someone else has them' end

    state.carriedBy = state.carriedBy and nil or src
    TriggerClientEvent('XS-CriminalTablet:client:setCarried', t, state.carriedBy and src or nil, 'escort')
    return true, nil, state.carriedBy ~= nil
end

function Field.Hostage(src, targetSrc)
    local t, cid, err = pair(src, targetSrc, 'hostage')
    if not t then return false, err end

    local state = stateOf(cid)
    if state.hostageOf and state.hostageOf ~= src then return false, 'someone else has them' end

    state.hostageOf = state.hostageOf and nil or src
    TriggerClientEvent('XS-CriminalTablet:client:setCarried', t, state.hostageOf and src or nil, 'hostage')
    Framework.Notify(t, state.hostageOf and 'You are being held hostage.' or 'You were let go.', 'inform')
    return true, nil, state.hostageOf ~= nil
end

function Field.Trunk(src, targetSrc, netId)
    local t, cid, err = pair(src, targetSrc, 'trunk')
    if not t then return false, err end

    local state = stateOf(cid)
    if not state.cuffed then return false, 'cuff them first' end

    local vehicle = netId and NetworkGetEntityFromNetworkId(netId) or nil
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'no vehicle there' end

    TriggerClientEvent('XS-CriminalTablet:client:setTrunk', t, netId)
    return true
end

-- ── search & rob ────────────────────────────────────────────
-- Takes cash, and optionally a couple of item stacks. The victim has to
-- be restrained (or hands-up) first unless the server owner turns that
-- requirement off, so this can't be a drive-by pickpocket.
function Field.SearchRob(src, targetSrc)
    local t, cid, err = pair(src, targetSrc, 'searchRob')
    if not t then return false, err end

    if Config.Radial.rob.requireHandsUp then
        local state = stateOf(cid)
        local handsUp = lib.callback.await('XS-CriminalTablet:field:handsUp', t)
        if not state.cuffed and not handsUp then return false, 'they need to be cuffed or hands up' end
    end

    local taken = {}
    local cash = Framework.GetMoney(t, 'cash') or 0
    if cash > 0 then
        Framework.RemoveMoney(t, 'cash', cash, 'robbed')
        Framework.AddMoney(src, 'cash', cash, 'robbery')
        taken[#taken + 1] = ('$%d'):format(cash)
    end

    if not Config.Radial.rob.cashOnly then
        local items = exports.ox_inventory:GetInventoryItems(t)
        local pool = {}
        for _, item in pairs(items or {}) do
            if item and item.name and (item.count or 0) > 0 then pool[#pool + 1] = item end
        end
        for i = #pool, 2, -1 do
            local j = math.random(i)
            pool[i], pool[j] = pool[j], pool[i]
        end
        for i = 1, math.min(Config.Radial.rob.maxItemStacks, #pool) do
            local item = pool[i]
            if exports.ox_inventory:RemoveItem(t, item.name, item.count, item.metadata) then
                exports.ox_inventory:AddItem(src, item.name, item.count, item.metadata)
                taken[#taken + 1] = ('%dx %s'):format(item.count, item.label or item.name)
            end
        end
    end

    if #taken == 0 then return false, 'they had nothing on them' end

    Framework.Notify(t, 'You were searched and robbed.', 'error')
    return true, nil, table.concat(taken, ', ')
end

-- ── tyres ───────────────────────────────────────────────────
function Field.SlashTyre(src, netId, tyreIndex)
    if not enabled('slashTyre') then return false, 'that action is disabled here' end

    -- The client checks too, but only so it can refuse before the
    -- animation. This is the one that counts.
    local cfg = Config.Radial.slash or {}
    if cfg.item and cfg.item ~= '' and not needsItem(src, cfg.item) then
        return false, 'you need something sharp for that'
    end

    local vehicle = netId and NetworkGetEntityFromNetworkId(netId) or nil
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'no vehicle there' end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(vehicle)) > 5.0 then return false, 'get closer' end

    if cfg.item and cfg.item ~= '' and cfg.consume then
        exports.ox_inventory:RemoveItem(src, cfg.item, 1)
    end

    -- Broadcast: the tyre has to pop on every client, not just the
    -- slasher's, and the vehicle owner may be anyone.
    TriggerClientEvent('XS-CriminalTablet:client:popTyre', -1, netId, tyreIndex)
    return true
end

-- ── cleanup ─────────────────────────────────────────────────
-- A restrained player whose captor disconnects has to be let go, or they
-- are stuck in an animation nobody can clear.
AddEventHandler('playerDropped', function()
    local src = source
    for cid, state in pairs(restrained) do
        if state.carriedBy == src or state.hostageOf == src then
            state.carriedBy, state.hostageOf = nil, nil
            local victimSrc = Gangs.SourceOf(cid)
            if victimSrc then TriggerClientEvent('XS-CriminalTablet:client:setCarried', victimSrc, nil, 'release') end
        end
    end
    local cid = Framework.GetCitizenId(src)
    if cid then restrained[cid] = nil end
end)

-- ── callbacks ───────────────────────────────────────────────
local ACTIONS = {
    cuff = Field.Cuff, bag = Field.Bag, carry = Field.Carry,
    escort = Field.Escort, hostage = Field.Hostage, searchRob = Field.SearchRob,
}

lib.callback.register('XS-CriminalTablet:field:action', function(src, action, targetSrc, extra)
    local fn = ACTIONS[action]
    if not fn then return { ok = false, error = 'unknown action' } end
    local ok, err, detail = fn(src, targetSrc, extra)
    return { ok = ok, error = err, detail = detail }
end)

lib.callback.register('XS-CriminalTablet:field:trunk', function(src, targetSrc, netId)
    local ok, err = Field.Trunk(src, targetSrc, netId)
    return { ok = ok, error = err }
end)

-- Lets the client refuse an action before playing three seconds of
-- animation the server was always going to reject.
lib.callback.register('XS-CriminalTablet:field:hasItem', function(src, item)
    return needsItem(src, item)
end)

lib.callback.register('XS-CriminalTablet:field:slashTyre', function(src, netId, tyreIndex)
    local ok, err = Field.SlashTyre(src, netId, tyreIndex)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:field:getRestraint', function(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    return stateOf(cid)
end)
