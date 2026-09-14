-- ─────────────────────────────────────────────────────────────
-- Server entry: device usage plus the callbacks the shell relies on.
-- The UI never talks to gang logic directly — everything routes through
-- validated callbacks, and the server is the sole source of truth.
-- ─────────────────────────────────────────────────────────────

-- Runs after Territory's own first-boot seed (Wait 2000) so a config gang
-- with a `territory` set has a zone row to actually claim.
CreateThread(function()
    Wait(3000)
    Gangs.SyncFromConfig()
end)

-- Open via command too. On a live server this can be made to require the
-- item, so the command isn't a way around carrying one.
RegisterCommand(Config.OpenCommand, function(src)
    if src == 0 then return end

    if Config.OpenCommandNeedsItem and Config.DeviceItem ~= '' then
        local count = exports.ox_inventory:GetItemCount(src, Config.DeviceItem)
        if (count or 0) < 1 then
            Framework.Notify(src, 'You are not carrying a tablet.', 'error')
            return
        end
    end

    TriggerClientEvent('XS-CriminalTablet:client:openDevice', src)
end, false)

-- ── Snapshot: everything the shell needs in one round trip ──
lib.callback.register('XS-CriminalTablet:getSnapshot', function(src)
    local cid = Framework.GetCitizenId(src)
    local gang = cid and Gangs.GetByCitizen(cid) or nil
    local snapshot = gang and Gangs.Snapshot(src) or nil

    local hasPerm = function(perm)
        return snapshot and snapshot.perms and snapshot.perms[perm] == true
    end

    return {
        apps = XSTablet.GetEnabledApps(gang ~= nil, hasPerm),
        appGroups = XSTablet.AppGroups,
        gang = snapshot,
        territories = gang and Territory.GetVisible(src) or {},
        capture = gang and Capture.Snapshot() or {},
        war = gang and War.PublicState(War.ActiveFor(gang.id)) or nil,
        stash = gang and War.StashFor(gang.id) or nil,
        testMode = TestMode.Snapshot(),
        noGangMessage = Config.NoGangMessage,
        isAdmin = IsPlayerAceAllowed(src, Config.AdminAce),
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
    for i = #results, 13, -1 do results[i] = nil end
    return results
end)

-- ── Live command center: where the crew actually is right now ──
lib.callback.register('XS-CriminalTablet:gang:getLiveMap', function(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return { members = {} } end

    local members = {}
    for _, memberSrc in ipairs(Gangs.OnlineSources(gang.id)) do
        local ped = GetPlayerPed(memberSrc)
        if ped and ped ~= 0 then
            local coords = GetEntityCoords(ped)
            local cid = Framework.GetCitizenId(memberSrc)
            local m = gang.members[cid]
            local zoneKey, zone = Territory.ZoneAt(coords)
            members[#members + 1] = {
                citizenid = cid,
                name = m and m.name or Framework.GetName(memberSrc),
                rank = m and gang.ranks[m.grade] and gang.ranks[m.grade].name or '?',
                coords = { x = coords.x, y = coords.y, z = coords.z },
                dead = GetEntityHealth(ped) <= 0,
                inVehicle = GetVehiclePedIsIn(ped, false) ~= 0,
                zone = zoneKey,
                zoneLabel = zone and zone.label or nil,
                isMe = memberSrc == src,
            }
        end
    end

    return {
        members = members,
        hq = Placeables.CoordsFor(gang.id, 'hq'),
        territories = Territory.GetVisible(src),
        capture = Capture.Snapshot(),
    }
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

lib.callback.register('XS-CriminalTablet:transferLeadership', function(src, citizenid)
    local ok, err = Gangs.TransferLeadership(src, citizenid)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:leaveGang', function(src)
    local ok, err = Gangs.Leave(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:setMotd', function(src, text)
    local ok, err = Gangs.SetMotd(src, text)
    return { ok = ok, error = err }
end)

RegisterNetEvent('XS-CriminalTablet:server:acceptInvite', function()
    local src = source
    local ok, err = Gangs.AcceptInvite(src)
    Framework.Notify(src, ok and 'You joined the gang.' or ('Could not join: ' .. tostring(err)),
        ok and 'success' or 'error')
    if ok then TriggerClientEvent('XS-CriminalTablet:client:refresh', src) end
end)

-- ── Treasury ──
lib.callback.register('XS-CriminalTablet:bankDeposit', function(src, amount)
    local ok, res = Bank.Deposit(src, amount)
    return { ok = ok, balance = ok and res or nil, error = not ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:bankWithdraw', function(src, amount)
    local ok, res = Bank.Withdraw(src, amount)
    return { ok = ok, balance = ok and res or nil, error = not ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:bankGetLedger', function(src)
    if not Gangs.HasPerm(src, 'bank_ledger') then return {} end
    local gang = Gangs.GetBySource(src)
    if not gang then return {} end
    return Bank.GetLedger(gang.id)
end)

-- ── Exports for other resources ──
exports('GetPlayerGang', function(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return nil end
    return { id = gang.id, name = gang.name, label = gang.label, color = gang.color }
end)

exports('HasGangPermission', function(src, perm)
    return Gangs.HasPerm(src, perm)
end)

exports('GetGangTerritories', function(gangId)
    return Territory.HeldBy(tonumber(gangId))
end)
