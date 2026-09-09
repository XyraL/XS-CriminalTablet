-- ─────────────────────────────────────────────────────────────
-- Gang core: create/disband, membership, ranks, permissions.
-- Exposes a server-side Gangs API used by territory/bank/notoriety.
-- ─────────────────────────────────────────────────────────────
Gangs = {}

local cache = {}        -- [gangId] = gang row + members + ranks

-- ── helpers ─────────────────────────────────────────────────
local function now() return os.time() * 1000 end

local function jsonPerms(perms)
    if perms == '*' then return '"*"' end
    return json.encode(perms or {})
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

-- ── loading ─────────────────────────────────────────────────
local function loadGang(id)
    local row = MySQL.single.await('SELECT * FROM xs_gangs WHERE id = ?', { id })
    if not row then return nil end

    local ranks = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM xs_gang_ranks WHERE gang_id = ?', { id }) or {}) do
        local perms = r.permissions == '"*"' and '*' or json.decode(r.permissions)
        ranks[r.grade] = { name = r.name, permissions = perms }
    end

    local members = {}
    for _, m in ipairs(MySQL.query.await('SELECT * FROM xs_gang_members WHERE gang_id = ?', { id }) or {}) do
        members[m.citizenid] = { citizenid = m.citizenid, name = m.name, grade = m.grade, rep = m.rep or 0,
            dues_paid_at = m.dues_paid_at or 0, last_seen = m.last_seen or 0 }
    end

    row.ranks = ranks
    row.members = members
    cache[id] = row
    return row
end

function Gangs.Get(id)
    return cache[id] or loadGang(id)
end

-- Resolve which gang a citizenid belongs to (loads from DB if needed).
function Gangs.GetByCitizen(citizenid)
    for id, gang in pairs(cache) do
        if gang.members[citizenid] then return gang end
    end
    local row = MySQL.single.await('SELECT gang_id FROM xs_gang_members WHERE citizenid = ?', { citizenid })
    if row then return Gangs.Get(row.gang_id) end
    return nil
end

function Gangs.GetBySource(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return nil end
    return Gangs.GetByCitizen(cid)
end

-- ── logging ─────────────────────────────────────────────────
function Gangs.Log(gangId, message)
    MySQL.insert('INSERT INTO xs_gang_logs (gang_id, message) VALUES (?, ?)', { gangId, message })
end

-- ── permission check ────────────────────────────────────────
-- Returns true if the player at src has `perm` in their gang.
function Gangs.HasPerm(src, perm)
    local cid = Framework.GetCitizenId(src)
    if not cid then return false end
    local gang = Gangs.GetByCitizen(cid)
    if not gang then return false end
    local member = gang.members[cid]
    if not member then return false end
    return gradeHasPerm(gang, member.grade, perm)
end

-- ── config sync ─────────────────────────────────────────────
-- Gangs are admin-defined in Config.Gangs only. On start, create any
-- missing gang, keep label/boss in sync with config, and seed default
-- ranks. There is no in-game create/disband — that's by design.
local function topGradeOf(ranks)
    local top = 0
    for g in pairs(ranks) do if g > top then top = g end end
    return top
end

function Gangs.SyncFromConfig()
    for name, def in pairs(Config.Gangs) do
        local row = MySQL.single.await('SELECT id FROM xs_gangs WHERE name = ?', { name })
        local gangId

        if not row then
            gangId = MySQL.insert.await(
                'INSERT INTO xs_gangs (name, label, owner, last_active) VALUES (?, ?, ?, ?)',
                { name, def.label or name, def.boss or '', now() })
            for grade, rank in pairs(Config.DefaultRanks) do
                MySQL.insert.await(
                    'INSERT INTO xs_gang_ranks (gang_id, grade, name, permissions) VALUES (?, ?, ?, ?)',
                    { gangId, grade, rank.name, jsonPerms(rank.permissions) })
            end
            if Config.Debug then print(('^2[XS-CriminalTablet]^0 seeded gang "%s" (#%d) from config'):format(name, gangId)) end
            Discord.Send('gang', 'Gang founded', ('%s (#%d) — seeded from config.lua'):format(def.label or name, gangId), Discord.Color.good)
        else
            gangId = row.id
            MySQL.update('UPDATE xs_gangs SET label = ?, owner = ? WHERE id = ?',
                { def.label or name, def.boss or '', gangId })
        end

        if def.territory and Config.Territories[def.territory] then
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
                    'INSERT INTO xs_gang_members (gang_id, citizenid, name, grade, dues_paid_at) VALUES (?, ?, ?, ?, ?)',
                    { gangId, def.boss, bossName, top, now() })
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

    local count = 0
    for _ in pairs(gang.members) do count = count + 1 end
    local mods = GangPerks.ModifiersFor(gang.id)
    if count >= Config.MaxMembers + mods.maxMembersBonus then return false, 'gang is full' end

    local targetCid = Framework.GetCitizenId(targetSrc)
    if not targetCid then return false, 'target offline' end
    if Gangs.GetByCitizen(targetCid) then return false, 'target already in a gang' end

    pendingInvites[targetSrc] = { gangId = gang.id, from = Framework.GetName(src) }
    TriggerClientEvent('XS-CriminalTablet:client:gangInvite', targetSrc, { gang = gang.label, from = pendingInvites[targetSrc].from })
    return true
end

function Gangs.AcceptInvite(src)
    local invite = pendingInvites[src]
    if not invite then return false, 'no pending invite' end
    pendingInvites[src] = nil

    local cid = Framework.GetCitizenId(src)
    if Gangs.GetByCitizen(cid) then return false, 'already in a gang' end

    MySQL.insert.await(
        'INSERT INTO xs_gang_members (gang_id, citizenid, name, grade, dues_paid_at) VALUES (?, ?, ?, 0, ?)',
        { invite.gangId, cid, Framework.GetName(src), now() })

    loadGang(invite.gangId) -- refresh cache
    Gangs.Log(invite.gangId, ('%s joined the gang'):format(Framework.GetName(src)))
    Notoriety.Add(invite.gangId, Config.Notoriety.rewards.member_recruited, 'recruit')
    return true
end

function Gangs.Kick(src, targetCid)
    if not Gangs.HasPerm(src, 'kick') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang or not gang.members[targetCid] then return false, 'not a member' end
    if gang.owner == targetCid then return false, 'cannot kick the boss' end

    MySQL.update('DELETE FROM xs_gang_members WHERE citizenid = ?', { targetCid })
    gang.members[targetCid] = nil
    Gangs.Log(gang.id, ('%s was removed'):format(targetCid))
    return true
end

function Gangs.SetGrade(src, targetCid, grade)
    if not Gangs.HasPerm(src, 'promote') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang or not gang.members[targetCid] then return false, 'not a member' end
    if not gang.ranks[grade] then return false, 'invalid grade' end
    if gang.owner == targetCid then return false, 'cannot change the boss grade' end

    MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE citizenid = ?', { grade, targetCid })
    gang.members[targetCid].grade = grade
    Gangs.Log(gang.id, ('%s set to %s'):format(targetCid, gang.ranks[grade].name))
    return true
end

-- ── rep ──────────────────────────────────────────────────────
-- Personal rep for one member; also feeds the gang's total notoriety.
-- This is the single entry point tasks/jobs should call to reward rep.
function Gangs.AddMemberRep(citizenid, amount, reason)
    local gang = Gangs.GetByCitizen(citizenid)
    if not gang then return false, 'not in a gang' end
    local member = gang.members[citizenid]
    if not member then return false, 'not a member' end

    member.rep = math.max(0, (member.rep or 0) + amount)
    MySQL.update('UPDATE xs_gang_members SET rep = ? WHERE citizenid = ?', { member.rep, citizenid })
    Notoriety.Add(gang.id, amount, reason)
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
    local members = {}
    for _, m in pairs(gang.members) do
        members[#members + 1] = {
            citizenid = m.citizenid,
            name = m.name,
            grade = m.grade,
            rep = m.rep or 0,
            lastSeen = m.last_seen or 0,
            rank = gang.ranks[m.grade] and gang.ranks[m.grade].name or '?',
            isOwner = gang.owner == m.citizenid,
            online = online[m.citizenid] or false,
        }
    end
    table.sort(members, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.grade > b.grade
    end)

    local logs = MySQL.query.await(
        'SELECT message, created_at FROM xs_gang_logs WHERE gang_id = ? ORDER BY id DESC LIMIT 25',
        { gang.id }) or {}

    local tierMin, nextTierMin = 0, nil
    if Notoriety then tierMin, nextTierMin = Notoriety.Progress(gang.notoriety) end

    local gangLevel, nextGangLevel
    if Notoriety then
        gangLevel = Notoriety.GangLevel(gang.notoriety)
        nextGangLevel = Notoriety.NextGangLevel(gangLevel.level)
    end

    return {
        id = gang.id,
        name = gang.name,
        label = gang.label,
        bank = gang.bank,
        notoriety = gang.notoriety,
        tier = Notoriety and Notoriety.Tier(gang.notoriety) or 'Unknown',
        tierMin = tierMin,
        nextTierMin = nextTierMin,
        gangLevel = gangLevel and gangLevel.level or 1,
        gangLevelTitle = gangLevel and gangLevel.title or 'Crew',
        gangLevelRep = gangLevel and gangLevel.repNeeded or 0,
        nextGangLevelRep = nextGangLevel and nextGangLevel.repNeeded or nil,
        perkPoints = gang.perk_points or 0,
        inactivityDays = Config.GangInactivityDays,
        myGrade = gang.members[cid] and gang.members[cid].grade or 0,
        myRep = gang.members[cid] and gang.members[cid].rep or 0,
        ranks = gang.ranks,
        members = members,
        logs = logs,
        territories = Territory and Territory.HeldBy(gang.id) or {},
    }
end

-- expose helper for other modules
Gangs._gradeHasPerm = gradeHasPerm
Gangs._reload = loadGang
function Gangs._invalidate(id) cache[id] = nil end
