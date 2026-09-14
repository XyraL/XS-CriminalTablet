-- ─────────────────────────────────────────────────────────────
-- Admin tablet: staff-only NUI for running every gang on the server
-- without touching config.lua or the database by hand.
--
-- Every callback here re-checks the ACE permission server-side. The
-- client being able to open the panel is never treated as proof it's
-- allowed to do anything.
-- ─────────────────────────────────────────────────────────────
Admin = {}

local function now() return os.time() * 1000 end

local function isAdmin(src)
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

-- One place enforces the permission check, so a new action added later
-- can't accidentally ship ungated.
local function guarded(handler)
    return function(src, ...)
        if not isAdmin(src) then return { ok = false, error = 'not authorized' } end
        return handler(src, ...)
    end
end

-- Every successful admin action gets logged — the audit trail.
local function logAdmin(src, title, description, color)
    Discord.Send('admin', title, description, color, {
        { name = 'Admin', value = Framework.GetName(src) or tostring(src), inline = true },
    })
end

-- ── reads ───────────────────────────────────────────────────
function Admin.ListGangs()
    local rows = MySQL.query.await(
        'SELECT id, name, label, color, owner, notoriety, bank, max_members, war_wins, war_losses, perk_points ' ..
        'FROM xs_gangs ORDER BY label') or {}
    for _, row in ipairs(rows) do
        row.tier = Rep.Tier(row.notoriety)
        row.level = Rep.GangLevel(row.notoriety).level
        row.levelTitle = Rep.GangLevel(row.notoriety).title
        row.memberCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_members WHERE gang_id = ?', { row.id }) or 0
        row.effectiveMax = Gangs.MaxMembers(row.id)
        row.zones = Territory.CountHeldBy(row.id)
        row.online = #Gangs.OnlineSources(row.id)
        row.ownerName = row.owner ~= '' and (Framework.GetNameByCitizenId(row.owner) or row.owner) or nil
        row.hasHq = Placeables.FindFor(row.id, 'hq') ~= nil
        row.vehicles = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_vehicles WHERE gang_id = ?', { row.id }) or 0
    end
    return rows
end

function Admin.ListMembers(gangId)
    local gang = Gangs.Get(tonumber(gangId))
    if not gang then return {} end
    local online = Gangs.OnlineCitizenIds()
    local list = {}
    for _, m in pairs(gang.members) do
        list[#list + 1] = {
            citizenid = m.citizenid, name = m.name, grade = m.grade, rep = m.rep or 0,
            rank = gang.ranks[m.grade] and gang.ranks[m.grade].name or '?',
            isOwner = gang.owner == m.citizenid,
            online = online[m.citizenid] or false,
            lastSeen = m.last_seen or 0,
        }
    end
    table.sort(list, function(a, b)
        if a.grade ~= b.grade then return a.grade > b.grade end
        return a.name < b.name
    end)
    return list
end

function Admin.ListRanks(gangId)
    local gang = Gangs.Get(tonumber(gangId))
    if not gang then return { ranks = {}, groups = XSTablet.PermissionGroups } end
    local list = {}
    for grade, r in pairs(gang.ranks) do
        list[#list + 1] = {
            grade = grade, name = r.name,
            permissions = r.permissions == '*' and '*' or r.permissions,
            isTop = grade == Gangs._topGrade(gang.ranks),
        }
    end
    table.sort(list, function(a, b) return a.grade > b.grade end)
    return { ranks = list, groups = XSTablet.PermissionGroups, maxRanks = Config.MaxRanks }
end

-- ── gang CRUD ───────────────────────────────────────────────
-- The full creation payload: internal name, display label, colour, boss,
-- member cap, a starting zone and an optional starting balance. Doing all
-- of it in one shot is the point — staff shouldn't have to create a gang
-- then edit it five times to finish setting it up.
function Admin.CreateGang(opts)
    opts = opts or {}
    local name = (opts.name or ''):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    if #name < 3 then return false, 'internal name needs at least 3 characters' end
    if MySQL.single.await('SELECT id FROM xs_gangs WHERE name = ?', { name }) then return false, 'that name is taken' end

    local label = tostring(opts.label or name):sub(1, 64)
    local color = tostring(opts.color or Config.GangColors[1]):sub(1, 9)
    if not color:match('^#%x%x%x%x%x%x$') then color = Config.GangColors[1] end

    local boss = tostring(opts.boss or ''):gsub('%s', '')
    if boss ~= '' then
        local exists = MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ?', { boss })
        if not exists then return false, 'no character with that citizenid' end
        local already = MySQL.single.await('SELECT gang_id FROM xs_gang_members WHERE citizenid = ?', { boss })
        if already then return false, 'that character is already in a gang' end
    end

    local maxMembers = math.max(0, math.floor(tonumber(opts.maxMembers) or 0))
    local startBank = math.max(0, math.floor(tonumber(opts.bank) or 0))
    local motd = tostring(opts.motd or ''):sub(1, 255)

    local gangId = MySQL.insert.await(
        'INSERT INTO xs_gangs (name, label, color, motd, owner, bank, max_members, last_active) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { name, label, color, motd, boss, startBank, maxMembers, now() })
    if not gangId then return false, 'db error' end

    for grade, rank in pairs(Config.DefaultRanks) do
        MySQL.insert.await(
            'INSERT INTO xs_gang_ranks (gang_id, grade, name, permissions) VALUES (?, ?, ?, ?)',
            { gangId, grade, rank.name, Gangs._jsonPerms(rank.permissions) })
    end

    if boss ~= '' then
        local top = 0
        for g in pairs(Config.DefaultRanks) do if g > top then top = g end end
        local bossName = Framework.GetNameByCitizenId(boss) or boss
        MySQL.insert.await(
            'INSERT INTO xs_gang_members (gang_id, citizenid, name, grade) VALUES (?, ?, ?, ?)',
            { gangId, boss, bossName, top })
    end

    Gangs._reload(gangId)

    if opts.territory and opts.territory ~= '' then
        Territory.SetHolder(opts.territory, gangId, 'founded')
    end

    -- Seed the new crew's graffiti library with the stock catalogue so
    -- they have something to spray on day one.
    if opts.seedGraffiti ~= false then
        for _, c in ipairs(Config.Graffiti.catalogue) do
            MySQL.insert.await(
                'INSERT INTO xs_gang_art (gang_id, label, art, source, added_by) VALUES (?, ?, ?, ?, ?)',
                { gangId, c.label, c.art, 'catalogue', 'system' })
        end
    end

    Vault.Refresh(gangId)

    local bossSrc = boss ~= '' and Gangs.SourceOf(boss) or nil
    if bossSrc then
        Gangs._syncFramework(bossSrc, Gangs.Get(gangId), 4)
        Framework.Notify(bossSrc, ('You now run %s.'):format(label), 'success')
        TriggerClientEvent('XS-CriminalTablet:client:refresh', bossSrc)
    end

    return true, gangId
end

function Admin.UpdateGang(gangId, fields)
    gangId = tonumber(gangId)
    local gang = Gangs.Get(gangId)
    if not gang then return false, 'unknown gang' end

    if fields.label then
        local label = tostring(fields.label):sub(1, 64)
        MySQL.update('UPDATE xs_gangs SET label = ? WHERE id = ?', { label, gangId })
        gang.label = label
    end

    if fields.color then
        local color = tostring(fields.color):sub(1, 9)
        if color:match('^#%x%x%x%x%x%x$') then
            MySQL.update('UPDATE xs_gangs SET color = ? WHERE id = ?', { color, gangId })
            gang.color = color
        end
    end

    if fields.motd ~= nil then
        local motd = tostring(fields.motd):sub(1, 255)
        MySQL.update('UPDATE xs_gangs SET motd = ? WHERE id = ?', { motd, gangId })
        gang.motd = motd
    end

    if fields.maxMembers ~= nil then
        local cap = math.max(0, math.floor(tonumber(fields.maxMembers) or 0))
        MySQL.update('UPDATE xs_gangs SET max_members = ? WHERE id = ?', { cap, gangId })
        gang.max_members = cap
    end

    if fields.perkPoints ~= nil then
        local pts = math.max(0, math.floor(tonumber(fields.perkPoints) or 0))
        MySQL.update('UPDATE xs_gangs SET perk_points = ? WHERE id = ?', { pts, gangId })
        gang.perk_points = pts
    end

    -- The column is still `notoriety`; the field the UI sends is `rep`.
    if fields.rep ~= nil then
        local rep = math.max(0, math.min(Config.Rep.max, math.floor(tonumber(fields.rep) or 0)))
        MySQL.update('UPDATE xs_gangs SET notoriety = ? WHERE id = ?', { rep, gangId })
        gang.notoriety = rep
    end

    if fields.boss then
        local newBoss = tostring(fields.boss):gsub('%s', '')
        local top = Gangs._topGrade(gang.ranks)
        local existing = MySQL.single.await(
            'SELECT citizenid FROM xs_gang_members WHERE citizenid = ? AND gang_id = ?', { newBoss, gangId })
        local bossName = Framework.GetNameByCitizenId(newBoss) or newBoss

        if existing then
            MySQL.update('UPDATE xs_gang_members SET grade = ?, name = ? WHERE citizenid = ?',
                { top, bossName, newBoss })
        else
            local elsewhere = MySQL.single.await('SELECT gang_id FROM xs_gang_members WHERE citizenid = ?', { newBoss })
            if elsewhere then return false, 'that character is in another gang' end
            MySQL.insert.await(
                'INSERT INTO xs_gang_members (gang_id, citizenid, name, grade) VALUES (?, ?, ?, ?)',
                { gangId, newBoss, bossName, top })
        end

        MySQL.update('UPDATE xs_gangs SET owner = ? WHERE id = ?', { newBoss, gangId })
        gang.owner = newBoss
    end

    Gangs._reload(gangId)
    Gangs.Broadcast(gangId, 'gang', {})
    for _, src in ipairs(Gangs.OnlineSources(gangId)) do
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    end
    return true
end

function Admin.SetBank(gangId, amount)
    gangId = tonumber(gangId)
    local gang = Gangs.Get(gangId)
    if not gang then return false, 'unknown gang' end
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    gang.bank = amount
    MySQL.update('UPDATE xs_gangs SET bank = ? WHERE id = ?', { amount, gangId })
    Gangs.Log(gangId, ('Treasury set to $%d by staff'):format(amount), 'economy')
    Gangs.Broadcast(gangId, 'treasury', {})
    return true
end

function Admin.DisbandGang(gangId)
    gangId = tonumber(gangId)
    local gang = Gangs.Get(gangId)
    if not gang then return false, 'unknown gang' end

    local sources = Gangs.OnlineSources(gangId)
    -- cascades members/ranks/logs/placements/vehicles/art/graffiti
    MySQL.update('DELETE FROM xs_gangs WHERE id = ?', { gangId })
    Gangs._invalidate(gangId)
    Territory.ClearHolder(gangId)
    Capture.ClearGang(gangId)
    Placeables._reload()
    Territory.Broadcast()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())

    for _, src in ipairs(sources) do
        Gangs._syncFramework(src, nil)
        Framework.Notify(src, 'Your gang was disbanded.', 'error')
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    end
    return true
end

-- Wipe a gang back to a blank slate without deleting it — keeps the name,
-- label, colour, boss and roster, drops everything they built up.
function Admin.ResetGang(gangId)
    gangId = tonumber(gangId)
    local gang = Gangs.Get(gangId)
    if not gang then return false, 'unknown gang' end

    MySQL.update('UPDATE xs_gangs SET notoriety = 0, bank = 0, perk_points = 0, war_wins = 0, war_losses = 0 WHERE id = ?', { gangId })
    MySQL.update('DELETE FROM xs_gang_perks WHERE gang_id = ?', { gangId })
    MySQL.update('DELETE FROM xs_gang_upgrades WHERE gang_id = ?', { gangId })
    MySQL.update('DELETE FROM xs_gang_placements WHERE gang_id = ?', { gangId })
    MySQL.update('DELETE FROM xs_gang_graffiti WHERE gang_id = ?', { gangId })
    MySQL.update('UPDATE xs_gang_members SET rep = 0 WHERE gang_id = ?', { gangId })
    MySQL.update('UPDATE xs_territories SET gang_id = NULL WHERE gang_id = ?', { gangId })

    Territory.ClearHolder(gangId)
    Capture.ClearGang(gangId)
    Placeables.ClearBought(gangId)
    Gangs.InvalidateModifiers(gangId)
    Gangs._reload(gangId)
    Placeables._reload()
    Territory.Broadcast()
    TriggerClientEvent('XS-CriminalTablet:client:placeablesUpdate', -1, Placeables.GetAll())
    TriggerClientEvent('XS-CriminalTablet:client:graffitiUpdate', -1, Graffiti.GetAll())

    Gangs.Log(gangId, 'Staff reset this crew back to zero', 'general')
    for _, src in ipairs(Gangs.OnlineSources(gangId)) do
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    end
    return true
end

-- ── membership overrides ────────────────────────────────────
function Admin.AddMember(gangId, citizenid, grade)
    gangId = tonumber(gangId)
    local gang = Gangs.Get(gangId)
    if not gang then return false, 'unknown gang' end

    citizenid = tostring(citizenid or ''):gsub('%s', '')
    if citizenid == '' then return false, 'no citizenid' end
    if MySQL.single.await('SELECT gang_id FROM xs_gang_members WHERE citizenid = ?', { citizenid }) then
        return false, 'already in a gang'
    end
    if not MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ?', { citizenid }) then
        return false, 'no character with that citizenid'
    end

    grade = tonumber(grade) or 0
    if not gang.ranks[grade] then grade = 0 end

    local name = Framework.GetNameByCitizenId(citizenid) or citizenid
    MySQL.insert.await('INSERT INTO xs_gang_members (gang_id, citizenid, name, grade) VALUES (?, ?, ?, ?)',
        { gangId, citizenid, name, grade })
    Gangs._reload(gangId)

    local src = Gangs.SourceOf(citizenid)
    if src then
        Gangs._syncFramework(src, Gangs.Get(gangId), grade)
        Framework.Notify(src, ('Staff added you to %s.'):format(gang.label), 'inform')
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    end

    Gangs.Log(gangId, ('Staff added %s'):format(name), 'roster')
    Gangs.Broadcast(gangId, 'roster', {})
    return true
end

function Admin.KickMember(gangId, citizenid)
    gangId = tonumber(gangId)
    local gang = Gangs.Get(gangId)
    if not gang or not gang.members[citizenid] then return false, 'not a member' end
    if gang.owner == citizenid then return false, 'change the boss first' end

    local name = gang.members[citizenid].name
    MySQL.update('DELETE FROM xs_gang_members WHERE citizenid = ?', { citizenid })
    gang.members[citizenid] = nil

    local src = Gangs.SourceOf(citizenid)
    if src then
        Gangs._syncFramework(src, nil)
        Framework.Notify(src, 'Staff removed you from your gang.', 'error')
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    end

    Gangs.Log(gangId, ('Staff removed %s'):format(name), 'roster')
    Gangs.Broadcast(gangId, 'roster', {})
    return true
end

function Admin.SetMemberGrade(gangId, citizenid, grade)
    gangId = tonumber(gangId)
    local gang = Gangs.Get(gangId)
    if not gang or not gang.members[citizenid] then return false, 'not a member' end
    grade = tonumber(grade)
    if not gang.ranks[grade] then return false, 'invalid grade' end
    if gang.owner == citizenid then return false, 'that is the boss — change the boss instead' end

    MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE citizenid = ?', { grade, citizenid })
    gang.members[citizenid].grade = grade

    local src = Gangs.SourceOf(citizenid)
    if src then
        Gangs._syncFramework(src, gang, grade)
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    end

    Gangs.Log(gangId, ('Staff set %s to %s'):format(gang.members[citizenid].name, gang.ranks[grade].name), 'roster')
    Gangs.Broadcast(gangId, 'roster', {})
    return true
end

function Admin.AdjustMemberRep(citizenid, amount)
    return Gangs.AddMemberRep(citizenid, math.floor(tonumber(amount) or 0), 'admin adjustment')
end

function Admin.AdjustRep(gangId, amount)
    if not Gangs.Get(tonumber(gangId)) then return false, 'unknown gang' end
    Rep.Add(tonumber(gangId), math.floor(tonumber(amount) or 0), 'admin adjustment')
    return true
end

-- ── rank editing (staff bypass the "can't grant above your own" rule) ──
function Admin.UpdateRank(gangId, grade, fields)
    gangId, grade = tonumber(gangId), tonumber(grade)
    local gang = Gangs.Get(gangId)
    if not gang or not gang.ranks[grade] then return false, 'unknown rank' end

    local isTop = grade == Gangs._topGrade(gang.ranks)
    local rank = gang.ranks[grade]
    local name = fields.name and tostring(fields.name):sub(1, 48) or rank.name
    local perms = rank.permissions
    if fields.permissions ~= nil then
        perms = isTop and '*' or XSTablet.SanitizePermissions(fields.permissions)
    end

    MySQL.query.await(
        'INSERT INTO xs_gang_ranks (gang_id, grade, name, permissions) VALUES (?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE name = ?, permissions = ?',
        { gangId, grade, name, perms == '*' and '"*"' or json.encode(perms),
          name, perms == '*' and '"*"' or json.encode(perms) })

    gang.ranks[grade] = { name = name, permissions = perms }
    Gangs.Broadcast(gangId, 'ranks', {})
    return true
end

-- ── pricing ─────────────────────────────────────────────────
-- config.lua only sets defaults; what staff type here is what crews pay.
lib.callback.register('XS-CriminalTablet:admin:getPrices', guarded(function(src)
    return Prices.ListAll()
end))

lib.callback.register('XS-CriminalTablet:admin:setPrice', guarded(function(src, kind, key, price)
    if kind ~= 'unlock' and kind ~= 'upgrade' then return { ok = false, error = 'unknown price kind' } end
    Prices.Set(kind, key, price)
    logAdmin(src, 'Price set', ('%s %s → $%s'):format(kind, key, price), Discord.Color.info)
    return { ok = true }
end))

lib.callback.register('XS-CriminalTablet:admin:resetPrice', guarded(function(src, kind, key)
    if kind ~= 'unlock' and kind ~= 'upgrade' then return { ok = false, error = 'unknown price kind' } end
    Prices.Reset(kind, key)
    logAdmin(src, 'Price reset', ('%s %s back to the config default'):format(kind, key), Discord.Color.info)
    return { ok = true }
end))

-- ── territory ───────────────────────────────────────────────
-- A zone is always made FOR a crew. One without an owner is legal but
-- invisible to players, so the panel asks for the crew up front.
function Admin.CreateZone(zone, label, color, gangId)
    local ok, res = Territory.CreateZone(zone, label, tonumber(color) or 0)
    if not ok then return ok, res end

    gangId = tonumber(gangId)
    if gangId then Territory.SetHolder(res, gangId, 'staff assignment') end
    Territory.Broadcast()
    return true, res
end

function Admin.SetZoneCoordsToSrc(src, zone)
    local coords = GetEntityCoords(GetPlayerPed(src))
    local ok, err = Territory.SetZoneCoords(zone, coords)
    if ok then Territory.Broadcast() end
    return ok, err
end

-- Drop a square around the admin's feet — the fast path when a full
-- polygon is more precision than the block needs.
function Admin.SquareZoneAtSrc(src, zone, size)
    local coords = GetEntityCoords(GetPlayerPed(src))
    local ok, err = Territory.SetSquare(zone, coords, size)
    if ok then Territory.Broadcast() end
    return ok, err
end

-- Points walked out in the in-world creator.
function Admin.SetZonePolygon(zone, points, z)
    local ok, err = Territory.SetPolygon(zone, points, z)
    if ok then Territory.Broadcast() end
    return ok, err
end

function Admin.UpdateZone(zone, fields)
    local ok, err = Territory.UpdateZone(zone, fields or {})
    if ok then Territory.Broadcast() end
    return ok, err
end

function Admin.DeleteZone(zone)
    local existing = Territory.GetZone(zone)
    local holderId = existing and existing.gangId
    local ok, err = Territory.DeleteZone(zone)
    if ok then
        Territory.Broadcast()
        if holderId then Placeables.ClearForGang(holderId) end
    end
    return ok, err
end

function Admin.SetTerritoryHolder(zone, gangId)
    local ok, err = Territory.SetHolder(zone, gangId, 'staff assignment')
    return ok, err
end

-- ── callbacks ───────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:admin:checkAccess', function(src)
    return isAdmin(src)
end)

lib.callback.register('XS-CriminalTablet:admin:getOverview', guarded(function(src)
    return { gangs = Admin.ListGangs(), territories = Territory.GetAll() }
end))

lib.callback.register('XS-CriminalTablet:admin:getMembers', guarded(function(src, gangId)
    return Admin.ListMembers(gangId)
end))

lib.callback.register('XS-CriminalTablet:admin:getRanks', guarded(function(src, gangId)
    return Admin.ListRanks(gangId)
end))

lib.callback.register('XS-CriminalTablet:admin:updateRank', guarded(function(src, gangId, grade, fields)
    local ok, err = Admin.UpdateRank(gangId, grade, fields or {})
    if ok then logAdmin(src, 'Rank edited', ('Gang #%s grade %s'):format(gangId, grade), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:createGang', guarded(function(src, opts)
    local ok, res = Admin.CreateGang(opts or {})
    if ok then
        logAdmin(src, 'Gang created',
            ('%s (#%d), boss: %s'):format((opts or {}).label or '?', res, (opts or {}).boss or '—'), Discord.Color.good)
        Discord.Send('gang', 'Gang founded', ('%s (#%d)'):format((opts or {}).label or '?', res), Discord.Color.good)
    end
    return { ok = ok, error = not ok and res or nil, gangId = ok and res or nil }
end))

lib.callback.register('XS-CriminalTablet:admin:updateGang', guarded(function(src, gangId, fields)
    local ok, err = Admin.UpdateGang(gangId, fields or {})
    if ok then
        logAdmin(src, 'Gang updated', ('Gang #%s — %s'):format(gangId, json.encode(fields or {})), Discord.Color.info)
        if (fields or {}).boss then
            Discord.Send('gang', 'Boss changed', ('Gang #%s → %s'):format(gangId, fields.boss), Discord.Color.warn)
        end
    end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:setBank', guarded(function(src, gangId, amount)
    local ok, err = Admin.SetBank(gangId, amount)
    if ok then logAdmin(src, 'Treasury set', ('Gang #%s → $%s'):format(gangId, amount), Discord.Color.warn) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:disbandGang', guarded(function(src, gangId)
    local gang = Gangs.Get(tonumber(gangId))
    local label = gang and gang.label or ('#' .. tostring(gangId))
    local ok, err = Admin.DisbandGang(gangId)
    if ok then
        logAdmin(src, 'Gang disbanded', label, Discord.Color.bad)
        Discord.Send('gang', 'Gang disbanded', label, Discord.Color.bad)
    end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:resetGang', guarded(function(src, gangId)
    local ok, err = Admin.ResetGang(gangId)
    if ok then logAdmin(src, 'Gang reset', ('Gang #%s wiped to zero'):format(gangId), Discord.Color.bad) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:addMember', guarded(function(src, gangId, citizenid, grade)
    local ok, err = Admin.AddMember(gangId, citizenid, grade)
    if ok then logAdmin(src, 'Member added', ('Gang #%s — %s'):format(gangId, citizenid), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:kickMember', guarded(function(src, gangId, citizenid)
    local ok, err = Admin.KickMember(gangId, citizenid)
    if ok then logAdmin(src, 'Member kicked', ('Gang #%s — %s'):format(gangId, citizenid), Discord.Color.bad) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:setMemberGrade', guarded(function(src, gangId, citizenid, grade)
    local ok, err = Admin.SetMemberGrade(gangId, citizenid, grade)
    if ok then logAdmin(src, 'Member grade set', ('Gang #%s — %s → %s'):format(gangId, citizenid, grade), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:adjustRep', guarded(function(src, citizenid, amount)
    local ok, err = Admin.AdjustMemberRep(citizenid, amount)
    if ok then logAdmin(src, 'Member rep adjusted', ('%s — %+d'):format(citizenid, tonumber(amount) or 0), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:adjustRep', guarded(function(src, gangId, amount)
    local ok, err = Admin.AdjustRep(gangId, amount)
    if ok then logAdmin(src, 'Rep adjusted', ('Gang #%s — %+d'):format(gangId, tonumber(amount) or 0), Discord.Color.info) end
    return { ok = ok, error = err }
end))

-- ── zones ───────────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:admin:createZone', guarded(function(src, zone, label, color, gangId)
    local ok, res = Admin.CreateZone(zone, label, color, gangId)
    if ok then logAdmin(src, 'Zone created', ('%s (%s)'):format(label or zone, res), Discord.Color.good) end
    return { ok = ok, error = not ok and res or nil, zone = ok and res or nil }
end))

lib.callback.register('XS-CriminalTablet:admin:setZoneCoords', guarded(function(src, zone)
    local ok, err = Admin.SetZoneCoordsToSrc(src, zone)
    if ok then logAdmin(src, 'Zone moved', zone, Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:squareZone', guarded(function(src, zone, size)
    local ok, err = Admin.SquareZoneAtSrc(src, zone, size)
    if ok then logAdmin(src, 'Zone squared', zone, Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:setZonePolygon', guarded(function(src, zone, points, z)
    local ok, err = Admin.SetZonePolygon(zone, points, z)
    if ok then logAdmin(src, 'Zone redrawn', ('%s — %d corners'):format(zone, #(points or {})), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:updateZone', guarded(function(src, zone, fields)
    local ok, err = Admin.UpdateZone(zone, fields)
    if ok then logAdmin(src, 'Zone updated', ('%s — %s'):format(zone, json.encode(fields or {})), Discord.Color.info) end
    return { ok = ok, error = err }
end))

-- ── Map editor: everything the satellite view needs in one round trip ──
lib.callback.register('XS-CriminalTablet:admin:resolveCitizenId', guarded(function(src, targetId)
    targetId = tonumber(targetId)
    if not targetId then return nil end
    local cid = Framework.GetCitizenId(targetId)
    if not cid then return nil end
    return { citizenid = cid, name = Framework.GetName(targetId) or GetPlayerName(targetId) }
end))

-- ── Dealer: stock, spawns and the scalars, all live ──
lib.callback.register('XS-CriminalTablet:admin:dealerState', guarded(function(src)
    return Dealer.AdminState()
end))

lib.callback.register('XS-CriminalTablet:admin:dealerAddItem', guarded(function(src, item, label, priceMin, priceMax)
    local ok, err = Dealer.AddPoolItem(item, label, priceMin, priceMax)
    if ok then logAdmin(src, 'Dealer stock added', tostring(item), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:dealerRemoveItem', guarded(function(src, id)
    local ok, err = Dealer.RemovePoolItem(id)
    if ok then logAdmin(src, 'Dealer stock removed', ('#%s'):format(id), Discord.Color.warn) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:dealerAddSpawn', guarded(function(src, label, coords, heading)
    local ok, err = Dealer.AddSpawn(label, coords, heading)
    if ok then logAdmin(src, 'Dealer spawn added', tostring(label or '?'), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:dealerAddSpawnHere', guarded(function(src, label)
    local ped = GetPlayerPed(src)
    local c = GetEntityCoords(ped)
    local ok, err = Dealer.AddSpawn(label, { x = c.x, y = c.y, z = c.z }, GetEntityHeading(ped))
    if ok then logAdmin(src, 'Dealer spawn added', 'at staff position', Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:dealerRemoveSpawn', guarded(function(src, id)
    local ok, err = Dealer.RemoveSpawn(id)
    if ok then logAdmin(src, 'Dealer spawn removed', ('#%s'):format(id), Discord.Color.warn) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:dealerSetSetting', guarded(function(src, key, value)
    local ok, err = Dealer.SetSetting(key, value)
    if ok then logAdmin(src, 'Dealer setting', ('%s = %s'):format(key, tostring(value)), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:dealerResetSetting', guarded(function(src, key)
    local ok, err = Dealer.ResetSetting(key)
    if ok then logAdmin(src, 'Dealer setting reset', tostring(key), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:getMapData', guarded(function(src)
    return {
        zones = Territory.GetAll(),
        gangs = Admin.ListGangs(),
        placements = Placeables.GetAll(),
        catalogue = Placeables.CatalogueAll(),
        blips = Blips.GetAll(),
        capture = Capture.Snapshot(),
    }
end))

-- Where the admin is standing, so the map can jump to them and pick up a
-- sane ground height for whatever they are about to drop.
lib.callback.register('XS-CriminalTablet:admin:whereAmI', guarded(function(src)
    local coords = GetEntityCoords(GetPlayerPed(src))
    return { x = coords.x, y = coords.y, z = coords.z, heading = GetEntityHeading(GetPlayerPed(src)) }
end))

lib.callback.register('XS-CriminalTablet:admin:placeFor', guarded(function(src, gangId, unlockId, coords, heading)
    local ok, res = Placeables.AdminPlace(gangId, unlockId, coords, heading)
    if ok then logAdmin(src, 'Placement set', ('%s for gang #%s'):format(res, gangId), Discord.Color.info) end
    return { ok = ok, error = not ok and res or nil }
end))

lib.callback.register('XS-CriminalTablet:admin:removePlacement', guarded(function(src, gangId, unlockId)
    local ok, err = Placeables.AdminRemove(gangId, unlockId)
    if ok then logAdmin(src, 'Placement removed', ('%s from gang #%s'):format(unlockId, gangId), Discord.Color.warn) end
    return { ok = ok, error = err }
end))

-- ── Gang blips ──
lib.callback.register('XS-CriminalTablet:admin:createBlip', guarded(function(src, gangId, opts)
    local ok, res = Blips.Create(gangId, opts or {})
    if ok then logAdmin(src, 'Blip created', ('%s for gang #%s'):format((opts or {}).label or '?', gangId), Discord.Color.info) end
    return { ok = ok, error = not ok and res or nil, id = ok and res or nil }
end))

lib.callback.register('XS-CriminalTablet:admin:updateBlip', guarded(function(src, id, fields)
    local ok, err = Blips.Update(id, fields or {})
    if ok then logAdmin(src, 'Blip edited', ('#%s'):format(id), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:deleteBlip', guarded(function(src, id)
    local ok, err = Blips.Delete(id)
    if ok then logAdmin(src, 'Blip removed', ('#%s'):format(id), Discord.Color.warn) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:deleteZone', guarded(function(src, zone)
    local ok, err = Admin.DeleteZone(zone)
    if ok then logAdmin(src, 'Zone deleted', zone, Discord.Color.bad) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:setTerritory', guarded(function(src, zone, gangId)
    local ok, err = Admin.SetTerritoryHolder(zone, gangId and tonumber(gangId) or nil)
    if ok then logAdmin(src, 'Zone reassigned', ('%s → %s'):format(zone, gangId or 'unassigned'), Discord.Color.info) end
    return { ok = ok, error = err }
end))

-- ── graffiti ────────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:admin:graffitiListArt', guarded(function(src, gangId)
    return Graffiti.AdminListArt(gangId)
end))

lib.callback.register('XS-CriminalTablet:admin:graffitiAddArt', guarded(function(src, gangId, label, art, kind)
    local ok, res = Graffiti.AdminAddArt(gangId, label, art, kind)
    if ok then logAdmin(src, 'Graffiti added', ('Gang #%s — %s'):format(gangId, label or 'Custom'), Discord.Color.good) end
    return { ok = ok, error = not ok and res or nil, id = ok and res or nil }
end))

lib.callback.register('XS-CriminalTablet:admin:graffitiDeleteArt', guarded(function(src, artId)
    local ok, err = Graffiti.AdminDeleteArt(artId)
    if ok then logAdmin(src, 'Graffiti art removed', ('art #%s'):format(artId), Discord.Color.bad) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:graffitiListTags', guarded(function(src, limit)
    return Graffiti.AdminListTags(limit)
end))

lib.callback.register('XS-CriminalTablet:admin:graffitiRemoveTag', guarded(function(src, tagId)
    local ok, err = Graffiti.Remove(src, tagId)
    if ok then logAdmin(src, 'Tag removed', ('tag #%s'):format(tagId), Discord.Color.bad) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:graffitiWipeGang', guarded(function(src, gangId)
    Graffiti.AdminWipeGang(gangId)
    logAdmin(src, 'Tags wiped', ('Gang #%s'):format(gangId), Discord.Color.bad)
    return { ok = true }
end))

-- ── garage ──────────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:admin:garageList', guarded(function(src, gangId)
    return { vehicles = Garage.AdminList(gangId), models = Config.Garage.adminGrantModels }
end))

lib.callback.register('XS-CriminalTablet:admin:garageGrant', guarded(function(src, gangId, model, label)
    local ok, res = Garage.AdminGrant(gangId, model, label)
    if ok then logAdmin(src, 'Vehicle granted', ('Gang #%s — %s (%s)'):format(gangId, label or model, res), Discord.Color.good) end
    return { ok = ok, error = not ok and res or nil, plate = ok and res or nil }
end))

lib.callback.register('XS-CriminalTablet:admin:garageDelete', guarded(function(src, vehicleId)
    local ok, err = Garage.AdminDelete(vehicleId)
    if ok then logAdmin(src, 'Vehicle removed', ('#%s'):format(vehicleId), Discord.Color.bad) end
    return { ok = ok, error = err }
end))

-- ── war ─────────────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:admin:warList', guarded(function(src)
    return War.AdminList()
end))

lib.callback.register('XS-CriminalTablet:admin:warStop', guarded(function(src, warId)
    local ok, err = War.AdminStop(warId)
    if ok then logAdmin(src, 'Engagement stopped', ('#%s'):format(warId), Discord.Color.warn) end
    return { ok = ok, error = err }
end))

-- ── test mode ───────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:admin:testModeState', guarded(function(src)
    return TestMode.Snapshot()
end))

lib.callback.register('XS-CriminalTablet:admin:testModeZone', guarded(function(src, zone, on)
    local ok, err
    if on then ok, err = TestMode.StartZone(src, zone) else ok, err = TestMode.StopZone(zone) end
    if ok then logAdmin(src, 'Test mode', ('%s on %s'):format(on and 'started' or 'stopped', zone), Discord.Color.info) end
    return { ok = ok, error = err }
end))

lib.callback.register('XS-CriminalTablet:admin:testModeArm', guarded(function(src, gangId, on)
    TestMode.ArmGang(gangId, on)
    logAdmin(src, 'Test mode', ('raid defenders %s for gang #%s'):format(on and 'armed' or 'disarmed', gangId), Discord.Color.info)
    return { ok = true }
end))

lib.callback.register('XS-CriminalTablet:admin:testModeStopAll', guarded(function(src)
    TestMode.StopAll()
    logAdmin(src, 'Test mode', 'all stopped', Discord.Color.info)
    return { ok = true }
end))

-- ── blackmarket moderation ──────────────────────────────────
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

-- ── dealer control ──────────────────────────────────────────
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

-- ── server-wide dashboard ───────────────────────────────────
lib.callback.register('XS-CriminalTablet:admin:getDashboard', guarded(function(src)
    local zoneTotal = MySQL.scalar.await('SELECT COUNT(*) FROM xs_territories') or 0
    return {
        gangCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gangs') or 0,
        memberCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_members') or 0,
        zoneCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_territories WHERE gang_id IS NOT NULL') or 0,
        zoneTotal = zoneTotal,
        totalGangBank = MySQL.scalar.await('SELECT COALESCE(SUM(bank),0) FROM xs_gangs') or 0,
        vehicleCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_vehicles') or 0,
        graffitiCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_graffiti') or 0,
        worldMsgCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_chat_world') or 0,
        handleCount = MySQL.scalar.await('SELECT COUNT(*) FROM xs_chat_handles') or 0,
        activeWars = #War.AdminList(),
        contests = Capture.Snapshot(),
        testMode = TestMode.Snapshot(),
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
