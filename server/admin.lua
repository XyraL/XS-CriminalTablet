-- ─────────────────────────────────────────────────────────────
-- Admin tablet: staff-only NUI for managing gangs without touching
-- config.lua or the database directly. Every callback here re-checks
-- the ACE permission server-side — never trust the client's claim that
-- it's allowed to be open.
-- ─────────────────────────────────────────────────────────────
Admin = {}

local function isAdmin(src)
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- Every admin callback wraps its handler with this so a single place
-- enforces the permission check, even if a new action is added later.
local function guarded(handler)
    return function(src, ...)
        if not isAdmin(src) then return { ok = false, error = 'not authorized' } end
        return handler(src, ...)
    end
end

-- Every successful admin-tablet action gets logged here — the audit trail.
local function logAdmin(src, title, description, color)
    Discord.Send('admin', title, description, color, {
        { name = 'Admin', value = Framework.GetName(src) or tostring(src), inline = true },
    })
end

-- ── reads ───────────────────────────────────────────────────
function Admin.ListGangs()
    local rows = MySQL.query.await('SELECT id, name, label, owner, notoriety, bank FROM xs_gangs ORDER BY label') or {}
    for _, row in ipairs(rows) do
        row.tier = Notoriety.Tier(row.notoriety)
        row.memberCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_members WHERE gang_id = ?', { row.id }) or 0
    end
    return rows
end

function Admin.ListMembers(gangId)
    return MySQL.query.await(
        'SELECT citizenid, name, grade, rep FROM xs_gang_members WHERE gang_id = ? ORDER BY grade DESC',
        { gangId }) or {}
end

function Admin.ListTerritories()
    return Territory.GetAll()
end

-- ── gang CRUD ───────────────────────────────────────────────
function Admin.CreateGang(name, label, boss)
    name = (name or ''):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    if #name < 3 then return false, 'name too short' end
    if MySQL.single.await('SELECT id FROM xs_gangs WHERE name = ?', { name }) then return false, 'name taken' end

    local gangId = MySQL.insert.await(
        'INSERT INTO xs_gangs (name, label, owner, last_active) VALUES (?, ?, ?, ?)',
        { name, label or name, boss or '', os.time() * 1000 })
    if not gangId then return false, 'db error' end

    for grade, rank in pairs(Config.DefaultRanks) do
        local perms = rank.permissions == '*' and '"*"' or json.encode(rank.permissions or {})
        MySQL.insert.await(
            'INSERT INTO xs_gang_ranks (gang_id, grade, name, permissions) VALUES (?, ?, ?, ?)',
            { gangId, grade, rank.name, perms })
    end

    if boss and boss ~= '' then
        local top = 0
        for g in pairs(Config.DefaultRanks) do if g > top then top = g end end
        local bossName = Framework.GetNameByCitizenId(boss) or boss
        MySQL.insert.await(
            'INSERT INTO xs_gang_members (gang_id, citizenid, name, grade, dues_paid_at) VALUES (?, ?, ?, ?, ?)',
            { gangId, boss, bossName, top, os.time() * 1000 })
    end

    Gangs._reload(gangId)
    return true, gangId
end

function Admin.UpdateGang(gangId, fields)
    local gang = Gangs.Get(gangId)
    if not gang then return false, 'unknown gang' end

    if fields.label then
        MySQL.update('UPDATE xs_gangs SET label = ? WHERE id = ?', { fields.label, gangId })
        gang.label = fields.label
    end

    if fields.boss then
        local existing = MySQL.single.await('SELECT citizenid FROM xs_gang_members WHERE citizenid = ? AND gang_id = ?', { fields.boss, gangId })
        local top = 0
        for g in pairs(gang.ranks) do if g > top then top = g end end
        if existing then
            local bossName = Framework.GetNameByCitizenId(fields.boss)
            if bossName then
                MySQL.update('UPDATE xs_gang_members SET grade = ?, name = ? WHERE citizenid = ?', { top, bossName, fields.boss })
            else
                MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE citizenid = ?', { top, fields.boss })
            end
        else
            local bossName = Framework.GetNameByCitizenId(fields.boss) or fields.boss
            MySQL.insert.await(
                'INSERT INTO xs_gang_members (gang_id, citizenid, name, grade, dues_paid_at) VALUES (?, ?, ?, ?, ?)',
                { gangId, fields.boss, bossName, top, os.time() * 1000 })
        end
        MySQL.update('UPDATE xs_gangs SET owner = ? WHERE id = ?', { fields.boss, gangId })
        gang.owner = fields.boss
    end

    Gangs._reload(gangId)
    return true
end

function Admin.DisbandGang(gangId)
    if not Gangs.Get(gangId) then return false, 'unknown gang' end
    MySQL.update('DELETE FROM xs_gangs WHERE id = ?', { gangId }) -- cascades members/ranks/logs/placements
    Gangs._invalidate(gangId)
    Territory.ClearHolder(gangId)
    TriggerClientEvent('XS-CriminalTablet:client:territoryUpdate', -1, Territory.GetAssigned())
    return true
end

-- ── rep / notoriety / economy overrides ─────────────────────
function Admin.AdjustMemberRep(citizenid, amount)
    return Gangs.AddMemberRep(citizenid, amount, 'admin adjustment')
end

function Admin.AdjustNotoriety(gangId, amount)
    if not Gangs.Get(gangId) then return false, 'unknown gang' end
    Notoriety.Add(gangId, amount, 'admin adjustment')
    return true
end

function Admin.SetBank(gangId, amount)
    local gang = Gangs.Get(gangId)
    if not gang then return false, 'unknown gang' end
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    gang.bank = amount
    MySQL.update('UPDATE xs_gangs SET bank = ? WHERE id = ?', { amount, gangId })
    Gangs.Log(gangId, ('Bank set to $%d by an admin'):format(amount))
    return true
end

-- ── membership overrides ─────────────────────────────────────
function Admin.KickMember(gangId, citizenid)
    local gang = Gangs.Get(gangId)
    if not gang or not gang.members[citizenid] then return false, 'not a member' end
    if gang.owner == citizenid then return false, 'cannot kick the boss — change boss first' end

    MySQL.update('DELETE FROM xs_gang_members WHERE citizenid = ?', { citizenid })
    gang.members[citizenid] = nil
    Gangs.Log(gangId, ('%s was removed by an admin'):format(citizenid))
    return true
end

function Admin.SetMemberGrade(gangId, citizenid, grade)
    local gang = Gangs.Get(gangId)
    if not gang or not gang.members[citizenid] then return false, 'not a member' end
    if not gang.ranks[grade] then return false, 'invalid grade' end
    if gang.owner == citizenid then return false, 'cannot change the boss grade' end

    MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE citizenid = ?', { grade, citizenid })
    gang.members[citizenid].grade = grade
    Gangs.Log(gangId, ('%s set to %s by an admin'):format(citizenid, gang.ranks[grade].name))
    return true
end

-- ── territory: fully admin-owned, no in-world capture ────────
local function broadcastTerritory()
    TriggerClientEvent('XS-CriminalTablet:client:territoryUpdate', -1, Territory.GetAssigned())
end

function Admin.CreateZone(zone, label, color)
    local ok, res = Territory.CreateZone(zone, label, tonumber(color) or 0)
    if ok then broadcastTerritory() end
    return ok, res
end

function Admin.SetZoneCoordsToSrc(src, zone)
    local coords = GetEntityCoords(GetPlayerPed(src))
    local existing = Territory.GetZone(zone)
    local holderId = existing and existing.gangId
    local ok, err = Territory.SetZoneCoords(zone, coords)
    if ok then
        broadcastTerritory()
        -- the zone moved out from under whatever was placed there
        if holderId then Placeables.ClearForGang(holderId) end
    end
    return ok, err
end

function Admin.UpdateZone(zone, fields)
    local ok, err = Territory.UpdateZone(zone, fields)
    if ok then broadcastTerritory() end
    return ok, err
end

function Admin.DeleteZone(zone)
    local existing = Territory.GetZone(zone)
    local holderId = existing and existing.gangId
    local ok, err = Territory.DeleteZone(zone)
    if ok then
        broadcastTerritory()
        if holderId then Placeables.ClearForGang(holderId) end
    end
    return ok, err
end

function Admin.SetTerritoryHolder(zone, gangId)
    local ok, err, previousGangId = Territory.SetHolder(zone, gangId)
    if ok then
        broadcastTerritory()
        -- whoever held this zone before just lost it — their placements
        -- there are no longer inside any zone they hold
        if previousGangId and previousGangId ~= gangId then Placeables.ClearForGang(previousGangId) end
    end
    return ok, err
end

-- ── callbacks ────────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:admin:checkAccess', function(src)
    return isAdmin(src)
end)

lib.callback.register('XS-CriminalTablet:admin:getOverview', guarded(function(src)
    return { gangs = Admin.ListGangs(), territories = Admin.ListTerritories() }
end))

lib.callback.register('XS-CriminalTablet:admin:getMembers', guarded(function(src, gangId)
    return Admin.ListMembers(tonumber(gangId))
end))

lib.callback.register('XS-CriminalTablet:admin:kickMember', guarded(function(src, gangId, citizenid)
    local ok, err = Admin.KickMember(tonumber(gangId), citizenid)
    if ok then logAdmin(src, 'Member kicked', ('Gang #%d — %s'):format(gangId, citizenid), Discord.Color.bad) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:setMemberGrade', guarded(function(src, gangId, citizenid, grade)
    local ok, err = Admin.SetMemberGrade(tonumber(gangId), citizenid, tonumber(grade))
    if ok then logAdmin(src, 'Member grade set', ('Gang #%d — %s → grade %s'):format(gangId, citizenid, grade), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:createGang', guarded(function(src, name, label, boss)
    local ok, res = Admin.CreateGang(name, label, boss)
    if ok then
        logAdmin(src, 'Gang created', ('%s (#%d), boss: %s'):format(label or name, res, boss or '—'), Discord.Color.good)
        Discord.Send('gang', 'Gang founded', ('%s (#%d)'):format(label or name, res), Discord.Color.good)
    end
    return { ok = ok, error = not ok and res or nil, gangId = ok and res or nil }
end))

lib.callback.register('XS-CriminalTablet:admin:updateGang', guarded(function(src, gangId, fields)
    local ok, err = Admin.UpdateGang(tonumber(gangId), fields or {})
    if ok then
        if fields.label then logAdmin(src, 'Gang renamed', ('Gang #%d → %s'):format(gangId, fields.label), Discord.Color.info) end
        if fields.boss then
            logAdmin(src, 'Boss changed', ('Gang #%d → %s'):format(gangId, fields.boss), Discord.Color.warn)
            Discord.Send('gang', 'Boss changed', ('Gang #%d → %s'):format(gangId, fields.boss), Discord.Color.warn)
        end
    end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:disbandGang', guarded(function(src, gangId)
    local gang = Gangs.Get(tonumber(gangId))
    local label = gang and gang.label or ('#' .. tostring(gangId))
    local ok, err = Admin.DisbandGang(tonumber(gangId))
    if ok then
        logAdmin(src, 'Gang disbanded', label, Discord.Color.bad)
        Discord.Send('gang', 'Gang disbanded', label, Discord.Color.bad)
    end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:adjustRep', guarded(function(src, citizenid, amount)
    local ok, err = Admin.AdjustMemberRep(citizenid, tonumber(amount) or 0)
    if ok then logAdmin(src, 'Member rep adjusted', ('%s — %+d rep'):format(citizenid, tonumber(amount) or 0), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:adjustNotoriety', guarded(function(src, gangId, amount)
    local ok, err = Admin.AdjustNotoriety(tonumber(gangId), tonumber(amount) or 0)
    if ok then logAdmin(src, 'Gang notoriety adjusted', ('Gang #%d — %+d rep'):format(gangId, tonumber(amount) or 0), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:setBank', guarded(function(src, gangId, amount)
    local ok, err = Admin.SetBank(tonumber(gangId), amount)
    if ok then logAdmin(src, 'Gang bank set', ('Gang #%d → $%d'):format(gangId, tonumber(amount) or 0), Discord.Color.warn) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:setTerritory', guarded(function(src, zone, gangId)
    local ok, err = Admin.SetTerritoryHolder(zone, gangId and tonumber(gangId) or nil)
    if ok then logAdmin(src, 'Zone holder set', ('%s → %s'):format(zone, gangId or 'unassigned'), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:createZone', guarded(function(src, zone, label, color)
    local ok, res = Admin.CreateZone(zone, label, color)
    if ok then logAdmin(src, 'Zone created', ('%s (%s)'):format(label or zone, res), Discord.Color.good) end
    return { ok = ok, error = not ok and res or nil, zone = ok and res or nil }
end))

lib.callback.register('XS-CriminalTablet:admin:setZoneCoords', guarded(function(src, zone)
    local ok, err = Admin.SetZoneCoordsToSrc(src, zone)
    if ok then logAdmin(src, 'Zone moved', zone, Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:updateZone', guarded(function(src, zone, fields)
    local ok, err = Admin.UpdateZone(zone, fields or {})
    if ok then logAdmin(src, 'Zone updated', ('%s — %s'):format(zone, json.encode(fields or {})), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:deleteZone', guarded(function(src, zone)
    local ok, err = Admin.DeleteZone(zone)
    if ok then logAdmin(src, 'Zone deleted', zone, Discord.Color.bad) end
    return { ok = ok, error = err }
end))

-- ── boosting oversight ──
lib.callback.register('XS-CriminalTablet:admin:boostSearch', guarded(function(src, query)
    return Boosting.AdminSearch(query)
end))

lib.callback.register('XS-CriminalTablet:admin:boostSetStats', guarded(function(src, citizenid, fields)
    local ok, err = Boosting.AdminSetStats(citizenid, fields or {})
    if ok then logAdmin(src, 'Boosting stats edited', ('%s — %s'):format(citizenid, json.encode(fields or {})), Discord.Color.warn) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:boostResetStats', guarded(function(src, citizenid)
    local ok, err = Boosting.AdminResetStats(citizenid)
    if ok then logAdmin(src, 'Boosting stats reset', citizenid, Discord.Color.bad) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:boostDashboard', guarded(function(src)
    return Boosting.AdminGetDashboard()
end))

-- ── blackmarket moderation ──
lib.callback.register('XS-CriminalTablet:admin:chatGetWorld', guarded(function(src)
    return Chat.GetWorldHistoryAdmin()
end))

lib.callback.register('XS-CriminalTablet:admin:chatDeleteWorld', guarded(function(src, id)
    local ok, err = Chat.DeleteWorldMessage(tonumber(id))
    if ok then logAdmin(src, 'Chat message deleted', ('id #%s'):format(tostring(id)), Discord.Color.bad) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:chatResolveHandle', guarded(function(src, handle)
    local citizenid = Chat.ResolveHandle(handle)
    if not citizenid then return { ok = false, error = 'no one with that handle' } end
    logAdmin(src, 'Handle resolved', ('%s -> %s'):format(handle, citizenid), Discord.Color.info)
    return { ok = true, citizenid = citizenid }
end))

-- ── dealer control ──
lib.callback.register('XS-CriminalTablet:admin:dealerGetStock', guarded(function(src)
    return Dealer.GetStock()
end))

lib.callback.register('XS-CriminalTablet:admin:dealerReroll', guarded(function(src)
    Dealer.ForceReroll()
    logAdmin(src, 'Dealer stock rerolled', '', Discord.Color.info)
    return { ok = true }
end))

lib.callback.register('XS-CriminalTablet:admin:dealerClearCooldown', guarded(function(src)
    Dealer.ClearCooldown()
    logAdmin(src, 'Dealer cooldown cleared', '', Discord.Color.info)
    return { ok = true }
end))

lib.callback.register('XS-CriminalTablet:admin:dealerGetStatus', guarded(function(src)
    return Dealer.GetStatus()
end))

-- ── server-wide dashboard ──
lib.callback.register('XS-CriminalTablet:admin:getDashboard', guarded(function(src)
    local gangCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gangs') or 0
    local zoneCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_territories WHERE gang_id IS NOT NULL') or 0
    local totalBank = MySQL.scalar.await('SELECT COALESCE(SUM(bank),0) FROM xs_gangs') or 0
    local worldMsgCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_chat_world') or 0
    local handleCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_chat_handles') or 0
    return {
        gangCount = gangCount,
        zoneCount = zoneCount,
        totalGangBank = totalBank,
        worldMsgCount = worldMsgCount,
        handleCount = handleCount,
        boosting = Boosting.AdminGetDashboard(),
        dealer = Dealer.GetStatus(),
    }
end))

RegisterCommand(Config.AdminCommand, function(src)
    if src == 0 then return end -- console
    if not isAdmin(src) then
        Framework.Notify(src, 'You are not authorized to use this.', 'error')
        return
    end
    TriggerClientEvent('XS-CriminalTablet:client:openAdmin', src)
end, false)
