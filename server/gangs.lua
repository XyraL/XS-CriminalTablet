-- ─────────────────────────────────────────────────────────────
-- Gang core: membership, ranks, permissions, snapshots.
-- Exposes the server-side Gangs API every other module builds on.
-- ─────────────────────────────────────────────────────────────
Gangs = {}

local cache = {}        -- [gangId] = gang row + members + ranks

-- ── helpers ─────────────────────────────────────────────────
local function now() return os.time() * 1000 end

local function jsonPerms(perms)
    if perms == '*' then return '"*"' end
    return json.encode(XSTablet.SanitizePermissions(perms))
end

-- True if a grade has a permission. '*' on a rank grants everything.
local function gradeHasPerm(gang, grade, perm)
    local rank = gang.ranks[grade]
    if not rank then return false end
    if rank.permissions == '*' then return true end
    for _, p in ipairs(rank.permissions) do
        if p == perm then return true end
    end
    return false
end

local function topGradeOf(ranks)
    local top = 0
    for g in pairs(ranks) do if g > top then top = g end end
    return top
end

-- ── loading ─────────────────────────────────────────────────
local function loadGang(id)
    local row = MySQL.single.await('SELECT * FROM xs_gangs WHERE id = ?', { id })
    if not row then return nil end

    local ranks = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM xs_gang_ranks WHERE gang_id = ?', { id }) or {}) do
        local perms = r.permissions == '"*"' and '*' or XSTablet.SanitizePermissions(json.decode(r.permissions))
        ranks[r.grade] = { name = r.name, permissions = perms }
    end

    local members = {}
    for _, m in ipairs(MySQL.query.await('SELECT * FROM xs_gang_members WHERE gang_id = ?', { id }) or {}) do
        members[m.citizenid] = {
            citizenid = m.citizenid, name = m.name, grade = m.grade,
            rep = m.rep or 0, last_seen = m.last_seen or 0,
        }
    end

    row.ranks = ranks
    row.members = members
    cache[id] = row
    return row
end

function Gangs.Get(id)
    if not id then return nil end
    return cache[id] or loadGang(id)
end

-- Resolve which gang a citizenid belongs to (loads from DB if needed).
function Gangs.GetByCitizen(citizenid)
    if not citizenid then return nil end
    for _, gang in pairs(cache) do
        if gang.members[citizenid] then return gang end
    end
    local row = MySQL.single.await('SELECT gang_id FROM xs_gang_members WHERE citizenid = ?', { citizenid })
    if row then return Gangs.Get(row.gang_id) end
    return nil
end

function Gangs.GetBySource(src)
    return Gangs.GetByCitizen(Framework.GetCitizenId(src))
end

function Gangs.MemberCount(gang)
    local count = 0
    for _ in pairs(gang.members) do count = count + 1 end
    return count
end

-- Effective member cap: base (or the admin-set per-gang override) plus
-- everything perks and treasury upgrades have added.
function Gangs.MaxMembers(gangId)
    local gang = Gangs.Get(gangId)
    if not gang then return Config.MaxMembers end
    local base = (gang.max_members and gang.max_members > 0) and gang.max_members or Config.MaxMembers
    local mods = Gangs.Modifiers(gangId)
    return base + mods.maxMembersBonus
end

-- One merged view of every modifier source (perk tree + treasury
-- upgrades) so callers never have to know where a bonus came from.
--
-- Cached, because the influence tick asks for this once per occupied zone
-- per second and both sources hit the database. Perks and upgrades only
-- change when someone buys one, and those paths call Gangs.InvalidateModifiers.
local modCache = {}

function Gangs.InvalidateModifiers(gangId)
    if gangId then modCache[gangId] = nil else modCache = {} end
end

function Gangs.Modifiers(gangId)
    local cached = modCache[gangId]
    if cached then return cached end

    local perks = GangPerks.ModifiersFor(gangId)
    local ups = Upgrades.ModifiersFor(gangId)
    local mods = {
        maxMembersBonus     = perks.maxMembersBonus + ups.maxMembersBonus,
        vaultSlotsBonus     = perks.vaultSlotsBonus + ups.vaultSlotsBonus,
        vaultWeightBonusPct = perks.vaultWeightBonusPct + ups.vaultWeightBonusPct,
        garageSlotsBonus    = ups.garageSlotsBonus,
        craftTimePct        = perks.craftTimePct,
        bonusOutputChance   = perks.bonusOutputChance,
        tierBoost           = perks.tierBoost,
        captureSpeedPct     = perks.captureSpeedPct + ups.captureSpeedPct,
        defenceWeightPct    = perks.defenceWeightPct,
        raidCutPct          = perks.raidCutPct + ups.raidRewardPct,
    }

    -- Caching under a nil key would throw, so an unknown gang just gets
    -- the computed zeroes back uncached.
    if gangId then modCache[gangId] = mods end
    return mods
end

-- ── logging ─────────────────────────────────────────────────
function Gangs.Log(gangId, message, category)
    MySQL.insert('INSERT INTO xs_gang_logs (gang_id, message, category) VALUES (?, ?, ?)',
        { gangId, message, category or 'general' })
    Gangs.Broadcast(gangId, 'log', { message = message, category = category or 'general' })
end

-- ── real-time sync ──────────────────────────────────────────
-- Server ids of every connected member of a gang.
function Gangs.OnlineSources(gangId)
    local gang = Gangs.Get(gangId)
    if not gang then return {} end
    local out = {}
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        local cid = Framework.GetCitizenId(src)
        if cid and gang.members[cid] then out[#out + 1] = src end
    end
    return out
end

-- Push a live update to every online member. The UI applies these
-- without reopening, which is what makes the tablet feel live.
function Gangs.Broadcast(gangId, event, data)
    for _, src in ipairs(Gangs.OnlineSources(gangId)) do
        TriggerClientEvent('XS-CriminalTablet:client:sync', src, event, data)
    end
end

function Gangs.NotifyGang(gangId, message, type)
    for _, src in ipairs(Gangs.OnlineSources(gangId)) do
        Framework.Notify(src, message, type)
    end
end

-- ── permission check ────────────────────────────────────────
function Gangs.HasPerm(src, perm)
    local cid = Framework.GetCitizenId(src)
    if not cid then return false end
    local gang = Gangs.GetByCitizen(cid)
    if not gang then return false end
    local member = gang.members[cid]
    if not member then return false end
    return gradeHasPerm(gang, member.grade, perm)
end

-- ── framework gang mirroring ────────────────────────────────
-- Optional: writes membership into the framework's own gang field so
-- other resources can see it. Off unless Config.SyncFrameworkGang.
local function syncFrameworkGang(src, gang, grade)
    if not Config.SyncFrameworkGang or not src then return end
    local player = Framework.GetPlayer(src)
    if not player or not player.Functions or not player.Functions.SetGang then return end
    pcall(function()
        if gang then player.Functions.SetGang(gang.name, grade or 0)
        else player.Functions.SetGang('none', 0) end
    end)
end

local function sourceOfCitizen(citizenid)
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        if Framework.GetCitizenId(src) == citizenid then return src end
    end
    return nil
end
Gangs.SourceOf = sourceOfCitizen

-- ── config sync ─────────────────────────────────────────────
-- Config.Gangs is a first-boot seed only. Everything after that is owned
-- by the admin tablet.
function Gangs.SyncFromConfig()
    for name, def in pairs(Config.Gangs) do
        local row = MySQL.single.await('SELECT id FROM xs_gangs WHERE name = ?', { name })
        local gangId

        if not row then
            gangId = MySQL.insert.await(
                'INSERT INTO xs_gangs (name, label, color, owner, last_active) VALUES (?, ?, ?, ?, ?)',
                { name, def.label or name, def.color or Config.GangColors[1], def.boss or '', now() })
            for grade, rank in pairs(Config.DefaultRanks) do
                MySQL.insert.await(
                    'INSERT INTO xs_gang_ranks (gang_id, grade, name, permissions) VALUES (?, ?, ?, ?)',
                    { gangId, grade, rank.name, jsonPerms(rank.permissions) })
            end
            if Config.Debug then print(('^2[XS-CriminalTablet]^0 seeded gang "%s" (#%d) from config'):format(name, gangId)) end
            Discord.Send('gang', 'Gang founded', ('%s (#%d) — seeded from config.lua'):format(def.label or name, gangId), Discord.Color.good)
        else
            gangId = row.id
            MySQL.update('UPDATE xs_gangs SET label = ?, owner = ?, color = ? WHERE id = ?',
                { def.label or name, def.boss or '', def.color or Config.GangColors[1], gangId })
        end

        if def.territory then
            MySQL.update('UPDATE xs_territories SET gang_id = ? WHERE zone = ? AND gang_id IS NULL',
                { gangId, def.territory })
        end

        -- make sure the boss has a member row at the top grade
        if def.boss and def.boss ~= '' then
            local member = MySQL.single.await('SELECT citizenid FROM xs_gang_members WHERE citizenid = ?', { def.boss })
            local ranks = MySQL.query.await('SELECT grade FROM xs_gang_ranks WHERE gang_id = ?', { gangId }) or {}
            local grades = {}
            for _, r in ipairs(ranks) do grades[r.grade] = true end
            local top = topGradeOf(grades)
            if not member then
                local bossName = Framework.GetNameByCitizenId(def.boss) or def.boss
                MySQL.insert.await(
                    'INSERT INTO xs_gang_members (gang_id, citizenid, name, grade) VALUES (?, ?, ?, ?)',
                    { gangId, def.boss, bossName, top })
            else
                MySQL.update('UPDATE xs_gang_members SET gang_id = ?, grade = ? WHERE citizenid = ?',
                    { gangId, top, def.boss })
            end
        end

        loadGang(gangId)
    end
end

-- ── membership ──────────────────────────────────────────────
local pendingInvites = {} -- [targetSrc] = { gangId, from }

function Gangs.Invite(src, targetSrc)
    if not Gangs.HasPerm(src, 'invite') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    if Gangs.MemberCount(gang) >= Gangs.MaxMembers(gang.id) then return false, 'gang is full' end

    local targetCid = Framework.GetCitizenId(targetSrc)
    if not targetCid then return false, 'target offline' end
    if Gangs.GetByCitizen(targetCid) then return false, 'target already in a gang' end

    pendingInvites[targetSrc] = { gangId = gang.id, from = Framework.GetName(src) }
    TriggerClientEvent('XS-CriminalTablet:client:gangInvite', targetSrc,
        { gang = gang.label, from = pendingInvites[targetSrc].from })
    return true
end

function Gangs.AcceptInvite(src)
    local invite = pendingInvites[src]
    if not invite then return false, 'no pending invite' end
    pendingInvites[src] = nil

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'no character' end
    if Gangs.GetByCitizen(cid) then return false, 'already in a gang' end

    local gang = Gangs.Get(invite.gangId)
    if not gang then return false, 'gang no longer exists' end
    if Gangs.MemberCount(gang) >= Gangs.MaxMembers(gang.id) then return false, 'gang is full' end

    local name = Framework.GetName(src)
    MySQL.insert.await(
        'INSERT INTO xs_gang_members (gang_id, citizenid, name, grade) VALUES (?, ?, ?, 0)',
        { invite.gangId, cid, name })

    loadGang(invite.gangId)
    syncFrameworkGang(src, Gangs.Get(invite.gangId), 0)
    Gangs.Log(invite.gangId, ('%s joined the gang'):format(name), 'roster')
    Rep.Add(invite.gangId, Config.Rep.rewards.member_recruited, 'recruit')
    Gangs.Broadcast(invite.gangId, 'roster', {})
    return true
end

function Gangs.Kick(src, targetCid)
    if not Gangs.HasPerm(src, 'kick') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang or not gang.members[targetCid] then return false, 'not a member' end
    if gang.owner == targetCid then return false, 'cannot kick the boss' end

    local actorCid = Framework.GetCitizenId(src)
    local actor = gang.members[actorCid]
    if actor and gang.members[targetCid].grade >= actor.grade then
        return false, 'cannot kick someone at or above your own rank'
    end

    local name = gang.members[targetCid].name
    MySQL.update('DELETE FROM xs_gang_members WHERE citizenid = ?', { targetCid })
    gang.members[targetCid] = nil

    local targetSrc = sourceOfCitizen(targetCid)
    if targetSrc then
        syncFrameworkGang(targetSrc, nil)
        Framework.Notify(targetSrc, ('You were removed from %s.'):format(gang.label), 'error')
        TriggerClientEvent('XS-CriminalTablet:client:refresh', targetSrc)
    end

    Gangs.Log(gang.id, ('%s was removed'):format(name), 'roster')
    Gangs.Broadcast(gang.id, 'roster', {})
    return true
end

function Gangs.SetGrade(src, targetCid, grade)
    local gang = Gangs.GetBySource(src)
    if not gang or not gang.members[targetCid] then return false, 'not a member' end
    if not gang.ranks[grade] then return false, 'invalid grade' end
    if gang.owner == targetCid then return false, 'cannot change the boss grade' end

    local current = gang.members[targetCid].grade
    if grade == current then return false, 'already that rank' end

    local needed = grade > current and 'promote' or 'demote'
    if not Gangs.HasPerm(src, needed) then return false, 'no permission' end

    -- Nobody may hand out a rank at or above their own.
    local actorCid = Framework.GetCitizenId(src)
    local actor = gang.members[actorCid]
    if actor and gang.owner ~= actorCid then
        if grade >= actor.grade then return false, 'cannot set a rank at or above your own' end
        if current >= actor.grade then return false, 'cannot change someone at or above your own rank' end
    end

    MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE citizenid = ?', { grade, targetCid })
    gang.members[targetCid].grade = grade

    local targetSrc = sourceOfCitizen(targetCid)
    if targetSrc then
        syncFrameworkGang(targetSrc, gang, grade)
        Framework.Notify(targetSrc, ('You are now %s.'):format(gang.ranks[grade].name), 'inform')
        TriggerClientEvent('XS-CriminalTablet:client:refresh', targetSrc)
    end

    Gangs.Log(gang.id, ('%s is now %s'):format(gang.members[targetCid].name, gang.ranks[grade].name), 'roster')
    Gangs.Broadcast(gang.id, 'roster', {})
    return true
end

-- Hand the crew over. The old boss drops to the rank below the top, so
-- they stay in the gang rather than being silently kicked out of it.
function Gangs.TransferLeadership(src, targetCid)
    if not Gangs.HasPerm(src, 'transfer_leadership') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local actorCid = Framework.GetCitizenId(src)
    if gang.owner ~= actorCid then return false, 'only the boss can hand over the crew' end
    if not gang.members[targetCid] then return false, 'not a member' end
    if targetCid == actorCid then return false, 'you already run this crew' end

    local top = topGradeOf(gang.ranks)
    local second = 0
    for g in pairs(gang.ranks) do if g < top and g > second then second = g end end

    MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE citizenid = ?', { top, targetCid })
    MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE citizenid = ?', { second, actorCid })
    MySQL.update('UPDATE xs_gangs SET owner = ? WHERE id = ?', { targetCid, gang.id })

    gang.members[targetCid].grade = top
    gang.members[actorCid].grade = second
    gang.owner = targetCid

    local targetSrc = sourceOfCitizen(targetCid)
    if targetSrc then
        syncFrameworkGang(targetSrc, gang, top)
        Framework.Notify(targetSrc, ('You now run %s.'):format(gang.label), 'success')
        TriggerClientEvent('XS-CriminalTablet:client:refresh', targetSrc)
    end
    syncFrameworkGang(src, gang, second)

    Gangs.Log(gang.id, ('%s handed the crew to %s'):format(
        gang.members[actorCid].name, gang.members[targetCid].name), 'roster')
    Discord.Send('gang', 'Boss changed', ('%s → %s'):format(gang.label, gang.members[targetCid].name), Discord.Color.warn)
    Gangs.Broadcast(gang.id, 'roster', {})
    return true
end

-- Walk out on your own. The boss can't leave without handing over first —
-- otherwise the crew is left headless with no in-game way to fix it.
function Gangs.Leave(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    local cid = Framework.GetCitizenId(src)
    if gang.owner == cid then return false, 'hand the crew over before you leave' end

    local name = gang.members[cid] and gang.members[cid].name or cid
    MySQL.update('DELETE FROM xs_gang_members WHERE citizenid = ?', { cid })
    gang.members[cid] = nil
    syncFrameworkGang(src, nil)
    Gangs.Log(gang.id, ('%s walked away'):format(name), 'roster')
    Gangs.Broadcast(gang.id, 'roster', {})
    return true
end

-- ── crew notice ─────────────────────────────────────────────
function Gangs.SetMotd(src, text)
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    local cid = Framework.GetCitizenId(src)
    if gang.owner ~= cid and not Gangs.HasPerm(src, 'manage_motd') then return false, 'no permission' end

    text = tostring(text or ''):sub(1, 255)
    MySQL.update('UPDATE xs_gangs SET motd = ? WHERE id = ?', { text, gang.id })
    gang.motd = text
    Gangs.Broadcast(gang.id, 'motd', { motd = text })
    return true
end

-- ── rep ──────────────────────────────────────────────────────
-- Personal rep for one member; also feeds the gang's total rep.
function Gangs.AddMemberRep(citizenid, amount, reason)
    local gang = Gangs.GetByCitizen(citizenid)
    if not gang then return false, 'not in a gang' end
    local member = gang.members[citizenid]
    if not member then return false, 'not a member' end

    member.rep = math.max(0, (member.rep or 0) + amount)
    MySQL.update('UPDATE xs_gang_members SET rep = ? WHERE citizenid = ?', { member.rep, citizenid })
    Rep.Add(gang.id, amount, reason)
    return true
end

-- citizenid -> true for everyone currently connected.
local function onlineCitizenIds()
    local online = {}
    for _, p in ipairs(GetPlayers()) do
        local cid = Framework.GetCitizenId(tonumber(p))
        if cid then online[cid] = true end
    end
    return online
end
Gangs.OnlineCitizenIds = onlineCitizenIds

-- ── snapshot for UI ─────────────────────────────────────────
function Gangs.Snapshot(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return nil end

    local cid = Framework.GetCitizenId(src)

    -- Opening the tablet counts as activity — last_seen drives the
    -- roster's inactivity flag.
    if cid and gang.members[cid] then
        local nowMs = now()
        gang.members[cid].last_seen = nowMs
        MySQL.update('UPDATE xs_gang_members SET last_seen = ? WHERE citizenid = ?', { nowMs, cid })
    end

    local online = onlineCitizenIds()
    local members, onlineCount = {}, 0
    for _, m in pairs(gang.members) do
        local isOnline = online[m.citizenid] or false
        if isOnline then onlineCount = onlineCount + 1 end
        members[#members + 1] = {
            citizenid = m.citizenid,
            name = m.name,
            grade = m.grade,
            rep = m.rep or 0,
            lastSeen = m.last_seen or 0,
            rank = gang.ranks[m.grade] and gang.ranks[m.grade].name or "?",
            isOwner = gang.owner == m.citizenid,
            online = isOnline,
        }
    end
    table.sort(members, function(a, b)
        if a.online ~= b.online then return a.online end
        if a.grade ~= b.grade then return a.grade > b.grade end
        return a.name < b.name
    end)

    local logs = MySQL.query.await(
        'SELECT message, category, created_at FROM xs_gang_logs WHERE gang_id = ? ORDER BY id DESC LIMIT 30',
        { gang.id }) or {}

    local tierMin, nextTierMin = Rep.Progress(gang.notoriety)
    local gangLevel = Rep.GangLevel(gang.notoriety)
    local nextGangLevel = Rep.NextGangLevel(gangLevel.level)

    -- Flatten my own permission set so the UI can grey out what I can't
    -- do. The server still re-checks every single action.
    local myGrade = gang.members[cid] and gang.members[cid].grade or 0
    local myPerms = {}
    if gang.ranks[myGrade] then
        if gang.ranks[myGrade].permissions == '*' then
            for _, id in ipairs(XSTablet.PermissionOrder) do myPerms[id] = true end
        else
            for _, id in ipairs(gang.ranks[myGrade].permissions) do myPerms[id] = true end
        end
    end

    local ranks = {}
    for grade, r in pairs(gang.ranks) do
        ranks[#ranks + 1] = {
            grade = grade, name = r.name,
            permissions = r.permissions == '*' and '*' or r.permissions,
            isTop = grade == topGradeOf(gang.ranks),
        }
    end
    table.sort(ranks, function(a, b) return a.grade > b.grade end)

    return {
        id = gang.id,
        name = gang.name,
        label = gang.label,
        color = gang.color or Config.GangColors[1],
        motd = gang.motd or '',
        bank = gang.bank,
        rep = gang.notoriety,
        tier = Rep.Tier(gang.notoriety),
        tierMin = tierMin,
        nextTierMin = nextTierMin,
        gangLevel = gangLevel.level,
        gangLevelTitle = gangLevel.title,
        gangLevelRep = gangLevel.repNeeded,
        nextGangLevelRep = nextGangLevel and nextGangLevel.repNeeded or nil,
        perkPoints = gang.perk_points or 0,
        warWins = gang.war_wins or 0,
        warLosses = gang.war_losses or 0,
        maxMembers = Gangs.MaxMembers(gang.id),
        memberCount = #members,
        onlineCount = onlineCount,
        inactivityDays = Config.GangInactivityDays,
        myGrade = myGrade,
        myRank = gang.ranks[myGrade] and gang.ranks[myGrade].name or '—',
        myRep = gang.members[cid] and gang.members[cid].rep or 0,
        myCitizenId = cid,
        isOwner = gang.owner == cid,
        perms = myPerms,
        ranks = ranks,
        members = members,
        logs = logs,
        territories = Territory.HeldBy(gang.id),
    }
end

-- expose helpers for other modules
Gangs._gradeHasPerm = gradeHasPerm
Gangs._topGrade = topGradeOf
Gangs._jsonPerms = jsonPerms
Gangs._reload = loadGang
Gangs._syncFramework = syncFrameworkGang
function Gangs._invalidate(id)
    cache[id] = nil
    Gangs.InvalidateModifiers(id)
end
