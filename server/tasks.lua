-- ─────────────────────────────────────────────────────────────
-- Tasks: jobs members run (solo or co-op) for gang rep AND a separate
-- personal task rank (xs_task_stats — independent of gang, survives
-- switching gangs). minLevel on a task gates whether your rank can see it.
--
-- 'delivery': target the pickup item, then target a delivery ped at the
--   dropoff. 'kill': spawn an armed NPC, report back when it's dead
--   (trusted only after minKillSeconds). 'escort': a friendly NPC follows
--   you to a destination, fails if it dies en route. 'heist': three
--   sequential target points (infiltrate -> grab -> escape).
--
-- Co-op mirrors Boosting's crew pattern: invite a specific player, only
-- the crew leader's client spawns any entity (dropoff ped / kill ped /
-- escort ped) to avoid duplicates, only the leader advances/completes the
-- shared job, reward splits across the crew (XP is NOT split).
-- ─────────────────────────────────────────────────────────────
Tasks = {}

local active = {}  -- [src] = { id, stage, startedAt, ..., coop?, crew?, leaderSrc?, cids? }
local byId = {}
for _, t in ipairs(Config.Tasks) do byId[t.id] = t end

local crews = {}              -- [leaderSrc] = { members = {...}, names = {src=name} }
local pendingCoopInvites = {} -- [targetSrc] = { fromSrc, fromName }

-- vec4 (has a heading .w, used for van/dropoff spawn points) can't be
-- subtracted from a vec3 (what GetEntityCoords returns) — Lua's vector ops
-- require matching types. Flattening both sides here makes dist() safe no
-- matter which kind either argument actually is.
local function asVec3(v) return vec3(v.x, v.y, v.z) end
local function dist(a, b) return #(asVec3(a) - asVec3(b)) end

-- Validates a courier job's van by its actual networked position, not the
-- player's — mirrors how Boosting validates its drop-off by the vehicle's
-- position rather than just trusting the player walked up to the right spot.
local function vanNear(job, coords, radius)
    if not job or not job.vanNetId then return false end
    local veh = NetworkGetEntityFromNetworkId(job.vanNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    return dist(GetEntityCoords(veh), coords) <= (radius or 6.0)
end

local function cleanupVan(src, job)
    if not job or not job.vanNetId then return end
    local owner = job.coop and job.leaderSrc or src
    TriggerClientEvent('XS-CriminalTablet:client:taskCleanupVan', owner, job.vanNetId)
end

-- ── personal task rank ──
local function sortedTaskLevels()
    local levels = {}
    for _, l in ipairs(Config.TaskLevels) do levels[#levels + 1] = l end
    table.sort(levels, function(a, b) return a.level < b.level end)
    return levels
end

local function taskLevelDefFor(level)
    for _, l in ipairs(Config.TaskLevels) do
        if l.level == level then return l end
    end
    return Config.TaskLevels[1]
end

local function taskLevelForXp(xp)
    local best = sortedTaskLevels()[1]
    for _, l in ipairs(sortedTaskLevels()) do
        if xp >= l.xpNeeded then best = l end
    end
    return best.level
end

local function nextTaskLevelDef(level)
    for _, l in ipairs(sortedTaskLevels()) do
        if l.level > level then return l end
    end
    return nil
end

local function getStats(citizenid)
    return MySQL.single.await('SELECT * FROM xs_task_stats WHERE citizenid = ?', { citizenid })
end

local function ensureStats(citizenid, name)
    local row = getStats(citizenid)
    if row then return row end
    -- Multiple callbacks (getStatus/getAvailable/getAchievements/...) can
    -- all race to create the row on first tablet open — INSERT IGNORE
    -- makes the loser of that race a no-op instead of a duplicate-key error.
    MySQL.insert.await('INSERT IGNORE INTO xs_task_stats (citizenid, name) VALUES (?, ?)', { citizenid, name or citizenid })
    return getStats(citizenid)
end

local function achievementCountFor(level, totalCompleted)
    local count = 0
    for _, a in ipairs(Config.TaskAchievements) do
        local progress = a.type == 'level' and level or totalCompleted
        if progress >= a.value then count = count + 1 end
    end
    return count
end

local function newlyEarnedAchievements(before, after)
    local ids = {}
    for _, a in ipairs(Config.TaskAchievements) do
        local prevProgress = a.type == 'level' and before.level or before.total_completed
        local newProgress = a.type == 'level' and after.level or after.total_completed
        if newProgress >= a.value and prevProgress < a.value then ids[#ids + 1] = a.label end
    end
    return ids
end

function Tasks.GetStatus(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return nil end
    local stats = ensureStats(cid, Framework.GetName(src))
    local next_ = nextTaskLevelDef(stats.level)
    return {
        level = stats.level,
        title = taskLevelDefFor(stats.level).title,
        xp = stats.xp,
        xpNeeded = next_ and next_.xpNeeded or nil,
        totalCompleted = stats.total_completed,
        active = active[src],
    }
end

function Tasks.GetAchievements(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    local stats = ensureStats(cid, Framework.GetName(src))
    local list = {}
    for _, a in ipairs(Config.TaskAchievements) do
        local progress = a.type == 'level' and stats.level or stats.total_completed
        list[#list + 1] = { id = a.id, label = a.label, description = a.description, earned = progress >= a.value }
    end
    return list
end

-- Gang-scoped — tasks are about contributing to YOUR gang, so rank within
-- it, not a server-wide list.
function Tasks.GetLeaderboard(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return {} end
    local citizenids = {}
    for cid in pairs(gang.members) do citizenids[#citizenids + 1] = cid end
    if #citizenids == 0 then return {} end

    local placeholders = {}
    for _ = 1, #citizenids do placeholders[#placeholders + 1] = '?' end
    local rows = MySQL.query.await(
        ('SELECT name, level, total_completed FROM xs_task_stats WHERE citizenid IN (%s) ORDER BY total_completed DESC LIMIT 10')
            :format(table.concat(placeholders, ',')),
        citizenids) or {}
    for _, r in ipairs(rows) do r.badges = achievementCountFor(r.level, r.total_completed) end
    return rows
end

-- ── available list for the UI ──
local function cooldownRemaining(citizenid, taskId)
    local def = byId[taskId]
    if not def or not def.cooldownMinutes or def.cooldownMinutes <= 0 then return 0 end
    local row = MySQL.single.await(
        'SELECT completed_at FROM xs_task_cooldowns WHERE citizenid = ? AND task_id = ?',
        { citizenid, taskId })
    if not row then return 0 end
    local readyAt = row.completed_at + (def.cooldownMinutes * 60 * 1000)
    return math.max(0, readyAt - os.time() * 1000)
end

function Tasks.GetAvailable(src)
    local cid = Framework.GetCitizenId(src)
    local stats = cid and ensureStats(cid, Framework.GetName(src))
    local myLevel = stats and stats.level or 1
    local list = {}
    for _, t in ipairs(Config.Tasks) do
        if not t.coopOnly then
            list[#list + 1] = {
                id = t.id,
                label = t.label,
                type = t.type or 'delivery',
                reward = t.reward,
                xp = t.xp,
                minLevel = t.minLevel or 1,
                locked = (t.minLevel or 1) > myLevel,
                cooldownMs = cid and cooldownRemaining(cid, t.id) or 0,
            }
        end
    end
    return list, active[src]
end

-- Everything a crew leader could pick to run together — includes
-- coopOnly entries, still gated by the leader's own level.
function Tasks.GetCoopTasks(src)
    local cid = Framework.GetCitizenId(src)
    local stats = cid and ensureStats(cid, Framework.GetName(src))
    local myLevel = stats and stats.level or 1
    local list = {}
    for _, t in ipairs(Config.Tasks) do
        if (t.minLevel or 1) <= myLevel then
            list[#list + 1] = { id = t.id, label = t.label, reward = t.reward, xp = t.xp, coopOnly = t.coopOnly == true }
        end
    end
    return list
end

-- ── co-op crews (identical shape to Boosting's) ──
local function crewOf(src)
    if crews[src] then return crews[src], src end
    for leaderSrc, c in pairs(crews) do
        for _, m in ipairs(c.members) do
            if m == src then return c, leaderSrc end
        end
    end
    return nil, nil
end

function Tasks.GetCrewStatus(src)
    local c, leaderSrc = crewOf(src)
    if not c then return nil end
    return { isLeader = leaderSrc == src, leaderName = c.names[leaderSrc],
             members = c.names, size = #c.members, maxSize = Config.TasksCoop.maxCrewSize }
end

function Tasks.InviteCoop(src, targetId)
    if not Config.TasksCoop.enabled then return false, 'co-op is disabled' end
    if active[src] then return false, 'finish your current job first' end
    targetId = tonumber(targetId)
    if not targetId or GetPlayerName(targetId) == nil then return false, 'player not found' end
    if targetId == src then return false, "you can't invite yourself" end

    local c = crews[src]
    if not c then
        local name = Framework.GetName(src) or 'Someone'
        c = { members = { src }, names = { [src] = name } }
        crews[src] = c
    end
    if #c.members >= Config.TasksCoop.maxCrewSize then return false, 'crew is full' end
    for _, m in ipairs(c.members) do if m == targetId then return false, 'already in your crew' end end
    if crewOf(targetId) then return false, 'that player is already in a crew' end
    if active[targetId] then return false, 'that player is already on a job' end

    pendingCoopInvites[targetId] = { fromSrc = src, fromName = c.names[src] }
    TriggerClientEvent('XS-CriminalTablet:client:taskCoopInvite', targetId, { fromName = c.names[src] })
    return true
end

function Tasks.AcceptCoopInvite(src)
    local invite = pendingCoopInvites[src]
    if not invite then return false, 'no pending invite' end
    pendingCoopInvites[src] = nil

    local c = crews[invite.fromSrc]
    if not c then return false, 'that crew no longer exists' end
    if #c.members >= Config.TasksCoop.maxCrewSize then return false, 'crew is full' end

    c.members[#c.members + 1] = src
    c.names[src] = Framework.GetName(src) or 'Someone'
    Framework.Notify(invite.fromSrc, ('%s joined your crew.'):format(c.names[src]), 'success')
    TriggerClientEvent('XS-CriminalTablet:client:refresh', invite.fromSrc)
    TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    return true
end

function Tasks.CancelCrew(src)
    if not crews[src] then return false, 'no crew to cancel' end
    crews[src] = nil
    return true
end

-- ── building the per-stage client payload for a given task def ──
-- `job` (when given) carries the per-job-resolved courier spawn/dropoff —
-- one of each is picked at random when the job starts and stays fixed for
-- its whole lifetime, rather than re-rolling on every stage transition.
local function stagePayloadFor(def, stage, job)
    if (def.type or 'delivery') == 'kill' then
        return { type = 'kill', stage = 'kill' } -- spawn handled in Accept/AcceptCoop (needs a random point)
    elseif def.type == 'escort' then
        return { type = 'escort', stage = 'escort', spawn = def.spawn, destination = def.destination,
                 pedModel = def.pedModel, radius = def.radius }
    elseif def.type == 'heist' then
        if stage == 'infiltrate' then
            return { type = 'heist', stage = 'infiltrate', point = def.infiltrate, holdSeconds = def.holdSeconds, radius = def.radius }
        elseif stage == 'grab' then
            return { type = 'heist', stage = 'grab', point = def.grab, radius = def.radius }
        else
            return { type = 'heist', stage = 'escape', point = def.escape, radius = def.radius }
        end
    elseif def.type == 'courier' then
        local vanSpawn = job and job.vanSpawn
        local dropoff = job and job.dropoff
        if stage == 'pickup_van' then
            return { type = 'courier', stage = 'pickup_van', vanSpawn = vanSpawn, vanModel = def.vanModel,
                     dropoff = dropoff, dropoffPedModel = def.dropoffPedModel, radius = def.radius,
                     quartermasterModel = def.quartermasterModel }
        elseif stage == 'handoff' then
            return { type = 'courier', stage = 'handoff', dropoff = dropoff, carryProp = def.carryProp, dropoffPedModel = def.dropoffPedModel }
        elseif stage == 'return' then
            return { type = 'courier', stage = 'return', vanSpawn = vanSpawn, radius = def.radius }
        else
            return { type = 'courier', stage = 'enroute', vanSpawn = vanSpawn, vanModel = def.vanModel,
                     dropoff = dropoff, radius = def.radius, ambushChance = def.ambushChance,
                     dropoffPedModel = def.dropoffPedModel }
        end
    else
        return { type = 'delivery', stage = 'pickup', pickup = def.pickup, dropoff = def.dropoff, carryProp = def.carryProp }
    end
end

-- ── accept (solo) ──
function Tasks.Accept(src, taskId)
    local def = byId[taskId]
    if not def then return false, 'unknown task' end
    if def.coopOnly then return false, 'this task is co-op only' end
    if active[src] then return false, 'already on a task' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'no character' end
    local gang = Gangs.GetByCitizen(cid)
    if not gang then return false, 'no gang' end
    local stats = ensureStats(cid, Framework.GetName(src))
    if (def.minLevel or 1) > stats.level then return false, 'rank too low' end
    if cooldownRemaining(cid, taskId) > 0 then return false, 'on cooldown' end

    Gangs.Log(gang.id, ('%s started "%s"'):format(Framework.GetName(src) or cid, def.label))

    if (def.type or 'delivery') == 'kill' then
        local spawn = def.spawnPoints[math.random(#def.spawnPoints)]
        active[src] = { id = taskId, stage = 'kill', startedAt = os.time() * 1000, spawn = spawn }
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src,
            { id = taskId, type = 'kill', spawn = spawn, pedModel = def.pedModel, weapon = def.weapon })
    elseif def.type == 'escort' then
        active[src] = { id = taskId, stage = 'escort', startedAt = os.time() * 1000 }
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, stagePayloadFor(def))
    elseif def.type == 'heist' then
        active[src] = { id = taskId, stage = 'infiltrate', startedAt = os.time() * 1000 }
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, stagePayloadFor(def, 'infiltrate'))
    elseif def.type == 'courier' then
        local job = { id = taskId, stage = 'pickup_van', startedAt = os.time() * 1000,
                      vanSpawn = def.vanSpawns[math.random(#def.vanSpawns)],
                      dropoff = def.dropoffs[math.random(#def.dropoffs)] }
        active[src] = job
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, stagePayloadFor(def, 'pickup_van', job))
    else
        active[src] = { id = taskId, stage = 'pickup', startedAt = os.time() * 1000 }
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, stagePayloadFor(def))
    end
    return true
end

-- ── accept (co-op): leader picks a task, whole crew gets the shared job ──
function Tasks.AcceptCoop(src, taskId)
    if not Config.TasksCoop.enabled then return false, 'co-op is disabled' end
    local def = byId[taskId]
    if not def then return false, 'unknown task' end
    local c = crews[src]
    if not c then return false, 'you have no crew — invite someone first' end
    if #c.members < 2 then return false, 'need at least one crew member' end

    local cids = {}
    for _, m in ipairs(c.members) do
        local mcid = Framework.GetCitizenId(m)
        if not mcid then return false, 'a crew member has no character' end
        local mgang = Gangs.GetByCitizen(mcid)
        if not mgang then return false, ('%s is not in a gang'):format(c.names[m]) end
        local mstats = ensureStats(mcid, c.names[m])
        if (def.minLevel or 1) > mstats.level then return false, ('%s\'s rank is too low'):format(c.names[m]) end
        if active[m] then return false, ('%s is already on a job'):format(c.names[m]) end
        if cooldownRemaining(mcid, taskId) > 0 then return false, ('%s is on cooldown for this job'):format(c.names[m]) end
        cids[m] = mcid
    end

    local job = { id = taskId, startedAt = os.time() * 1000, coop = true, crew = c.members, crewNames = c.names,
                  leaderSrc = src, cids = cids }

    if (def.type or 'delivery') == 'kill' then
        job.stage = 'kill'
        job.spawn = def.spawnPoints[math.random(#def.spawnPoints)]
        for _, m in ipairs(c.members) do
            active[m] = job
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m,
                { id = taskId, type = 'kill', spawn = job.spawn, pedModel = def.pedModel, weapon = def.weapon, isLeader = (m == src) })
        end
    elseif def.type == 'escort' then
        job.stage = 'escort'
        for _, m in ipairs(c.members) do
            active[m] = job
            local payload = stagePayloadFor(def)
            payload.isLeader = (m == src)
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, payload)
        end
    elseif def.type == 'heist' then
        job.stage = 'infiltrate'
        for _, m in ipairs(c.members) do
            active[m] = job
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, stagePayloadFor(def, 'infiltrate'))
        end
    elseif def.type == 'courier' then
        job.stage = 'pickup_van'
        job.vanSpawn = def.vanSpawns[math.random(#def.vanSpawns)]
        job.dropoff = def.dropoffs[math.random(#def.dropoffs)]
        for _, m in ipairs(c.members) do
            active[m] = job
            local payload = stagePayloadFor(def, 'pickup_van', job)
            payload.isLeader = (m == src)
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, payload)
        end
    else
        job.stage = 'pickup'
        for _, m in ipairs(c.members) do
            active[m] = job
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, stagePayloadFor(def))
        end
    end

    crews[src] = nil
    return true
end

function Tasks.Cancel(src)
    local job = active[src]
    if not job then return false, 'no active task' end
    cleanupVan(src, job)
    if job.coop then
        for _, m in ipairs(job.crew) do
            active[m] = nil
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, nil)
        end
    else
        active[src] = nil
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, nil)
    end
    return true
end

-- ── reward: one call per crew member for coop, one call for solo ──
local function rewardMember(src, cid, def)
    local stats = ensureStats(cid, Framework.GetName(src))
    local gang = Gangs.GetByCitizen(cid)
    local newXp = stats.xp + (def.xp or 0)
    local newLevel = taskLevelForXp(newXp)
    local leveledUp = newLevel > stats.level

    MySQL.update(
        'UPDATE xs_task_stats SET xp = ?, level = ?, total_completed = total_completed + 1, name = ? WHERE citizenid = ?',
        { newXp, newLevel, Framework.GetName(src) or cid, cid })
    MySQL.insert(
        'INSERT INTO xs_task_cooldowns (citizenid, task_id, completed_at) VALUES (?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE completed_at = ?',
        { cid, def.id, os.time() * 1000, os.time() * 1000 })

    if gang then Gangs.AddMemberRep(cid, def.reward, 'task:' .. def.id) end

    Framework.Notify(src, ('Job complete — +%d rep, +%d XP.'):format(def.reward, def.xp or 0), 'success')
    if leveledUp then
        Framework.Notify(src, ('Rank up! You are now a %s.'):format(taskLevelDefFor(newLevel).title), 'success')
    end
    local afterStats = { level = newLevel, total_completed = stats.total_completed + 1 }
    for _, label in ipairs(newlyEarnedAchievements(stats, afterStats)) do
        Framework.Notify(src, ('Achievement unlocked: %s'):format(label), 'success')
    end
    if gang then
        Gangs.Log(gang.id, ('%s completed "%s" (+%d rep)'):format(Framework.GetName(src) or cid, def.label, def.reward))
    end
end

local function completeTask(src, def)
    local job = active[src]
    cleanupVan(src, job)
    if job and job.coop then
        for _, m in ipairs(job.crew) do
            active[m] = nil
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, nil)
        end
        for _, m in ipairs(job.crew) do
            local mcid = job.cids[m]
            if mcid then rewardMember(m, mcid, def) end
        end
    else
        active[src] = nil
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, nil)
        local cid = Framework.GetCitizenId(src)
        if cid then rewardMember(src, cid, def) end
    end
end

-- ── kill ──
function Tasks.ReportKill(src)
    local job = active[src]
    if not job or job.stage ~= 'kill' then return false, 'no active kill task' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can report this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local elapsed = (os.time() * 1000) - job.startedAt
    if elapsed < (def.minKillSeconds or 5) * 1000 then return false, 'too fast' end

    completeTask(src, def)
    return true
end

-- ── delivery ──
function Tasks.DoPickup(src)
    local job = active[src]
    if not job or job.stage ~= 'pickup' then return false, 'no active pickup' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local ped = GetPlayerPed(src)
    if ped == 0 or dist(GetEntityCoords(ped), def.pickup) > (def.radius or 3.0) then
        return false, 'too far from the pickup'
    end

    job.stage = 'dropoff'
    local payload = { id = job.id, type = 'delivery', stage = 'dropoff', pickup = def.pickup, dropoff = def.dropoff,
                       carryProp = def.carryProp, dropoffPedModel = def.dropoffPedModel }
    if job.coop then
        for _, m in ipairs(job.crew) do
            local p2 = {}
            for k, v in pairs(payload) do p2[k] = v end
            p2.isLeader = (m == src)
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, p2)
        end
    else
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, payload)
    end
    Framework.Notify(src, 'Picked up — deliver it.', 'success')
    return true
end

function Tasks.DoDropoff(src)
    local job = active[src]
    if not job or job.stage ~= 'dropoff' then return false, 'no active dropoff' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local ped = GetPlayerPed(src)
    if ped == 0 or dist(GetEntityCoords(ped), def.dropoff) > (def.radius or 3.0) then
        return false, 'too far from the dropoff'
    end

    completeTask(src, def)
    return true
end

-- ── escort ──
function Tasks.DoEscortComplete(src)
    local job = active[src]
    if not job or job.stage ~= 'escort' then return false, 'no active escort' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local ped = GetPlayerPed(src)
    if ped == 0 or dist(GetEntityCoords(ped), def.destination) > (def.radius or 5.0) then
        return false, 'not at the destination yet'
    end

    completeTask(src, def)
    return true
end

-- ── heist (3 stages) ──
local function heistAdvance(src, fromStage, toStage, point)
    local job = active[src]
    if not job or job.stage ~= fromStage then return false, 'wrong stage' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local ped = GetPlayerPed(src)
    if ped == 0 or dist(GetEntityCoords(ped), point) > (def.radius or 2.5) then
        return false, 'too far from the target'
    end

    job.stage = toStage
    local payload = stagePayloadFor(def, toStage)
    payload.id = job.id
    if job.coop then
        for _, m in ipairs(job.crew) do TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, payload) end
    else
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, payload)
    end
    return true
end

function Tasks.DoInfiltrate(src)
    local def = byId[active[src] and active[src].id]
    if not def then return false, 'unknown task' end
    return heistAdvance(src, 'infiltrate', 'grab', def.infiltrate)
end

function Tasks.DoGrab(src)
    local def = byId[active[src] and active[src].id]
    if not def then return false, 'unknown task' end
    return heistAdvance(src, 'grab', 'escape', def.grab)
end

function Tasks.DoEscape(src)
    local job = active[src]
    if not job or job.stage ~= 'escape' then return false, 'wrong stage' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local ped = GetPlayerPed(src)
    if ped == 0 or dist(GetEntityCoords(ped), def.escape) > (def.radius or 2.5) then
        return false, 'too far from the escape point'
    end

    completeTask(src, def)
    return true
end

-- ── courier (van delivery loop) ──
-- Only the leader's client ever spawns the van (co-op), so only the
-- leader's registration call should be trusted to set vanNetId.
function Tasks.RegisterVan(src, netId)
    local job = active[src]
    if not job or job.stage ~= 'pickup_van' then return false, 'no active courier job' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    job.vanNetId = netId
    return true
end

-- Talking to the quartermaster at the van is what "loads" the package.
function Tasks.DoPickupVan(src)
    local job = active[src]
    if not job or job.stage ~= 'pickup_van' then return false, 'no active courier job' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local ped = GetPlayerPed(src)
    if ped == 0 or dist(GetEntityCoords(ped), job.vanSpawn) > (def.radius or 6.0) then
        return false, 'too far from the van'
    end

    job.stage = 'enroute'
    local payload = stagePayloadFor(def, 'enroute', job)
    payload.id = job.id
    if job.coop then
        for _, m in ipairs(job.crew) do
            local p2 = {}
            for k, v in pairs(payload) do p2[k] = v end
            p2.isLeader = (m == src)
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, p2)
        end
    else
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, payload)
    end
    Framework.Notify(src, "Package loaded — get it there.", 'success')
    return true
end

function Tasks.DoUnload(src)
    local job = active[src]
    if not job or job.stage ~= 'enroute' then return false, 'no active courier job' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local ped = GetPlayerPed(src)
    if ped == 0 or dist(GetEntityCoords(ped), job.dropoff) > (def.radius or 6.0) then
        return false, 'too far from the dropoff'
    end
    if not vanNear(job, job.dropoff, def.radius) then
        return false, 'the van needs to be here too'
    end

    job.stage = 'handoff'
    local payload = stagePayloadFor(def, 'handoff', job)
    payload.id = job.id
    if job.coop then
        for _, m in ipairs(job.crew) do
            local p2 = {}
            for k, v in pairs(payload) do p2[k] = v end
            p2.isLeader = (m == src)
            TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, p2)
        end
    else
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, payload)
    end
    Framework.Notify(src, 'Unloaded — deliver it.', 'success')
    return true
end

function Tasks.DoCourierHandoff(src)
    local job = active[src]
    if not job or job.stage ~= 'handoff' then return false, 'no active handoff' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    local ped = GetPlayerPed(src)
    if ped == 0 or dist(GetEntityCoords(ped), job.dropoff) > (def.radius or 6.0) then
        return false, 'too far from the dropoff'
    end

    job.stage = 'return'
    local payload = stagePayloadFor(def, 'return', job)
    payload.id = job.id
    if job.coop then
        for _, m in ipairs(job.crew) do TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, payload) end
    else
        TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, payload)
    end
    Framework.Notify(src, 'Delivered — bring the van home.', 'success')
    return true
end

function Tasks.DoReturnVan(src)
    local job = active[src]
    if not job or job.stage ~= 'return' then return false, 'no active return' end
    if job.coop and src ~= job.leaderSrc then return false, 'only the crew leader can do this' end
    local def = byId[job.id]
    if not def then return false, 'unknown task' end

    if not vanNear(job, job.vanSpawn, def.radius) then
        return false, 'the van is not back yet'
    end

    completeTask(src, def)
    return true
end

-- ── time-limit enforcement ──
CreateThread(function()
    while true do
        Wait(1500)
        local seen = {}
        for src, job in pairs(active) do
            if not seen[job] then
                seen[job] = true
                if GetPlayerName(src) == nil then
                    active[src] = nil
                else
                    local def = byId[job.id]
                    if def and def.timeLimitSeconds and def.timeLimitSeconds > 0 then
                        if (os.time() * 1000) - job.startedAt > def.timeLimitSeconds * 1000 then
                            cleanupVan(src, job)
                            if job.coop then
                                for _, m in ipairs(job.crew) do
                                    active[m] = nil
                                    TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', m, nil)
                                    Framework.Notify(m, 'Job window expired.', 'error')
                                end
                            else
                                active[src] = nil
                                TriggerClientEvent('XS-CriminalTablet:client:taskUpdate', src, nil)
                                Framework.Notify(src, 'Job window expired.', 'error')
                            end
                        end
                    end
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    active[src] = nil
    crews[src] = nil
    pendingCoopInvites[src] = nil
    for _, c in pairs(crews) do
        for i, m in ipairs(c.members) do
            if m == src then table.remove(c.members, i); c.names[src] = nil; break end
        end
    end
end)

RegisterNetEvent('XS-CriminalTablet:server:acceptTaskCoopInvite', function()
    local src = source
    local ok, err = Tasks.AcceptCoopInvite(src)
    Framework.Notify(src, ok and 'Joined the crew.' or ('Could not join: ' .. tostring(err)), ok and 'success' or 'error')
end)

lib.callback.register('XS-CriminalTablet:tasks:getAvailable', function(src)
    local tasks, activeJob = Tasks.GetAvailable(src)
    return { tasks = tasks, active = activeJob }
end)

lib.callback.register('XS-CriminalTablet:tasks:getStatus', function(src)
    return Tasks.GetStatus(src)
end)

lib.callback.register('XS-CriminalTablet:tasks:getAchievements', function(src)
    return Tasks.GetAchievements(src)
end)

lib.callback.register('XS-CriminalTablet:tasks:getLeaderboard', function(src)
    return Tasks.GetLeaderboard(src)
end)

lib.callback.register('XS-CriminalTablet:tasks:getCoopTasks', function(src)
    return Tasks.GetCoopTasks(src)
end)

lib.callback.register('XS-CriminalTablet:tasks:getCrewStatus', function(src)
    return Tasks.GetCrewStatus(src)
end)

lib.callback.register('XS-CriminalTablet:tasks:inviteCoop', function(src, targetId)
    local ok, err = Tasks.InviteCoop(src, targetId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:cancelCrew', function(src)
    local ok, err = Tasks.CancelCrew(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:acceptCoop', function(src, taskId)
    local ok, err = Tasks.AcceptCoop(src, taskId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:accept', function(src, taskId)
    local ok, err = Tasks.Accept(src, taskId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:cancel', function(src)
    local ok, err = Tasks.Cancel(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:reportKill', function(src)
    local ok, err = Tasks.ReportKill(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doPickup', function(src)
    local ok, err = Tasks.DoPickup(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doDropoff', function(src)
    local ok, err = Tasks.DoDropoff(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doEscortComplete', function(src)
    local ok, err = Tasks.DoEscortComplete(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doInfiltrate', function(src)
    local ok, err = Tasks.DoInfiltrate(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doGrab', function(src)
    local ok, err = Tasks.DoGrab(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doEscape', function(src)
    local ok, err = Tasks.DoEscape(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:registerVan', function(src, netId)
    local ok, err = Tasks.RegisterVan(src, netId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doPickupVan', function(src)
    local ok, err = Tasks.DoPickupVan(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doUnload', function(src)
    local ok, err = Tasks.DoUnload(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doCourierHandoff', function(src)
    local ok, err = Tasks.DoCourierHandoff(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:tasks:doReturnVan', function(src)
    local ok, err = Tasks.DoReturnVan(src)
    return { ok = ok, error = err }
end)
