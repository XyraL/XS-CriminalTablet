-- ─────────────────────────────────────────────────────────────
-- Server entry: device usage + all callbacks the NUI relies on.
-- The UI never talks to gang logic directly — everything routes
-- through these validated callbacks/events.
-- ─────────────────────────────────────────────────────────────

-- Device is opened client-side via the item's client.export — see client/main.lua.

CreateThread(function()
    Gangs.SyncFromConfig()
end)

-- Open via command too (handy for testing without an item).
RegisterCommand(Config.OpenCommand, function(src)
    TriggerClientEvent('XS-CriminalTablet:client:openDevice', src)
end, false)

-- ── Snapshot: everything the Gang Ops app needs in one round trip ──
lib.callback.register('XS-CriminalTablet:getSnapshot', function(src)
    local cid = Framework.GetCitizenId(src)
    local hasGang = cid and Gangs.GetByCitizen(cid) ~= nil
    return {
        apps = XSTablet.GetEnabledApps(hasGang),
        gang = Gangs.Snapshot(src),
        territories = Territory.GetAssigned(),
    }
end)

-- ── Online player search (feeds every invite box) ──
lib.callback.register('XS-CriminalTablet:players:search', function(src, query)
    query = tostring(query or ''):lower():match('^%s*(.-)%s*$')
    local results = {}
    for _, p in ipairs(GetPlayers()) do
        local id = tonumber(p)
        if id and id ~= src then
            local name = Framework.GetName(id) or GetPlayerName(id) or ('Player ' .. id)
            local hit = query == ''
                or tostring(id):find(query, 1, true) == 1
                or name:lower():find(query, 1, true) ~= nil
            if hit then results[#results + 1] = { id = id, name = name } end
        end
    end
    table.sort(results, function(a, b) return a.id < b.id end)
    if #results > 12 then
        for i = #results, 13, -1 do results[i] = nil end
    end
    return results
end)

-- ── Membership ──
lib.callback.register('XS-CriminalTablet:invite', function(src, targetId)
    local ok, err = Gangs.Invite(src, tonumber(targetId))
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:kick', function(src, citizenid)
    local ok, err = Gangs.Kick(src, citizenid)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:setGrade', function(src, citizenid, grade)
    local ok, err = Gangs.SetGrade(src, citizenid, tonumber(grade))
    return { ok = ok, error = err }
end)

RegisterNetEvent('XS-CriminalTablet:server:acceptInvite', function()
    local src = source
    local ok, err = Gangs.AcceptInvite(src)
    Framework.Notify(src, ok and 'You joined the gang.' or ('Could not join: ' .. tostring(err)),
        ok and 'success' or 'error')
    if ok then TriggerClientEvent('XS-CriminalTablet:client:refresh', src) end
end)

-- ── Bank ──
lib.callback.register('XS-CriminalTablet:bankDeposit', function(src, amount)
    local ok, res = Bank.Deposit(src, amount)
    return { ok = ok, balance = ok and res or nil, error = not ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:bankWithdraw', function(src, amount)
    local ok, res = Bank.Withdraw(src, amount)
    return { ok = ok, balance = ok and res or nil, error = not ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:bankGetLedger', function(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return {} end
    return Bank.GetLedger(gang.id)
end)

