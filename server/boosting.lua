-- ─────────────────────────────────────────────────────────────
-- Car boosting: fully standalone from gangs. Personal level/XP only —
-- no gang rep, no gang gating. Steal a marked vehicle (no custom minigame
-- here — qbx_core's own lockpick/hotwire system handles a locked vehicle
-- with no keys; we just watch for the engine to actually start), drive it
-- to the drop-off to sell it. Higher level = access to better vehicles in
-- the rotation (cumulative — you keep access to lower tiers too).
-- ─────────────────────────────────────────────────────────────
Boosting = {}

local active = {}  -- [src] = { stage, startedAt, vehicleNetId, vehicleDef, coop?, crew?, leaderSrc? }
                    -- for a coop job every crew member's `active[src]` is the SAME table reference,
                    -- so a stage change made through one member is instantly visible to all of them.
local crews = {}    -- [leaderSrc] = { members = { src, ... }, names = { src = name } }
local pendingCoopInvites = {} -- [targetSrc] = { fromSrc, fromName }

local function dist(a, b) return #(a - b) end

local function sortedLevels()
    local levels = {}
    for _, l in ipairs(Config.Boosting.levels) do levels[#levels + 1] = l end
    table.sort(levels, function(a, b) return a.level < b.level end)
    return levels
end

local function levelDefFor(level)
    for _, l in ipairs(Config.Boosting.levels) do
        if l.level == level then return l end
    end
    return Config.Boosting.levels[1]
end

-- Highest level whose xpNeeded the player's xp actually clears.
local function levelForXp(xp)
    local best = sortedLevels()[1]
    for _, l in ipairs(sortedLevels()) do
        if xp >= l.xpNeeded then best = l end
    end
    return best.level
end

local function nextLevelDef(level)
    for _, l in ipairs(sortedLevels()) do
        if l.level > level then return l end
    end
    return nil -- already max level
end

-- Cumulative vehicle pool: everything unlocked at this level and below.
local function vehiclePoolFor(level)
    local pool = {}
    for _, l in ipairs(Config.Boosting.levels) do
        if l.level <= level then
            for _, v in ipairs(l.vehicles) do pool[#pool + 1] = v end
        end
    end
    return pool
end

local function getStats(citizenid)
    return MySQL.single.await('SELECT * FROM xs_boost_stats WHERE citizenid = ?', { citizenid })
end

local function ensureStats(citizenid, name)
    local row = getStats(citizenid)
    if row then return row end
    MySQL.insert.await('INSERT INTO xs_boost_stats (citizenid, name) VALUES (?, ?)', { citizenid, name or citizenid })
    return getStats(citizenid)
end

-- ── perks: passive modifiers bought with perk_points ──
local function ownedPerkIds(citizenid)
    local rows = MySQL.query.await('SELECT perk_id FROM xs_boost_perks WHERE citizenid = ?', { citizenid }) or {}
    local owned = {}
    for _, r in ipairs(rows) do owned[r.perk_id] = true end
    return owned
end

-- Aggregates every owned perk into one set of numbers the rest of the
-- module can just apply — nothing else needs to know the perk list shape.
local function modifiersFor(citizenid)
    local owned = ownedPerkIds(citizenid)
    local mods = { cashBonusPct = 0, guardReduction = 0, dispatchDelay = 0, cooldownReductionPct = 0 }
    for _, p in ipairs(Config.Boosting.perks) do
        if owned[p.id] then
            if p.type == 'cash_bonus_pct' then mods.cashBonusPct = mods.cashBonusPct + p.value
            elseif p.type == 'guard_reduction' then mods.guardReduction = mods.guardReduction + p.value
            elseif p.type == 'dispatch_delay' then mods.dispatchDelay = mods.dispatchDelay + p.value
            elseif p.type == 'cooldown_reduction_pct' then mods.cooldownReductionPct = mods.cooldownReductionPct + p.value
            end
        end
    end
    mods.cooldownReductionPct = math.min(90, mods.cooldownReductionPct) -- never quite zero cooldown
    return mods, owned
end

local function effectiveCooldownMs(level, mods)
    local base = (levelDefFor(level).cooldownMinutes or Config.Boosting.cooldownMinutes) * 60 * 1000
    return math.floor(base * (1 - mods.cooldownReductionPct / 100))
end

function Boosting.GetPerks(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    local stats = ensureStats(cid, Framework.GetName(src))
    local _, owned = modifiersFor(cid)
    local list = {}
    for _, p in ipairs(Config.Boosting.perks) do
        list[#list + 1] = {
            id = p.id, label = p.label, description = p.description, cost = p.cost,
            owned = owned[p.id] == true,
            affordable = stats.perk_points >= p.cost,
        }
    end
    return list, stats.perk_points
end

function Boosting.BuyPerk(src, perkId)
    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'no character' end
    local def
    for _, p in ipairs(Config.Boosting.perks) do if p.id == perkId then def = p; break end end
    if not def then return false, 'unknown perk' end

    local stats = ensureStats(cid, Framework.GetName(src))
    local _, owned = modifiersFor(cid)
    if owned[perkId] then return false, 'already owned' end
    if stats.perk_points < def.cost then return false, 'not enough perk points' end

    local ok = pcall(function()
        MySQL.insert.await('INSERT INTO xs_boost_perks (citizenid, perk_id) VALUES (?, ?)', { cid, perkId })
    end)
    if not ok then return false, 'already owned' end

    MySQL.update('UPDATE xs_boost_stats SET perk_points = perk_points - ? WHERE citizenid = ?', { def.cost, cid })
    return true
end

function Boosting.GetStatus(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return nil end
    local stats = ensureStats(cid, Framework.GetName(src))
    local next_ = nextLevelDef(stats.level)
    local mods = modifiersFor(cid)
    local cooldownMs = math.max(0, (stats.last_boost_at + effectiveCooldownMs(stats.level, mods)) - os.time() * 1000)

    return {
        level = stats.level,
        label = levelDefFor(stats.level).label,
        xp = stats.xp,
        xpNeeded = next_ and next_.xpNeeded or nil,
        totalBoosted = stats.total_boosted,
        totalCash = stats.total_cash,
        perkPoints = stats.perk_points,
        cooldownMs = cooldownMs,
        active = active[src],
    }
end

local function achievementCountFor(level, totalBoosted)
    local count = 0
    for _, a in ipairs(Config.Boosting.achievements) do
        local progress = a.type == 'level' and level or totalBoosted
        if progress >= a.value then count = count + 1 end
    end
    return count
end

function Boosting.GetLeaderboard()
    local rows = MySQL.query.await(
        'SELECT name, level, total_boosted, total_cash FROM xs_boost_stats ORDER BY total_boosted DESC LIMIT 10') or {}
    for _, r in ipairs(rows) do
        r.badges = achievementCountFor(r.level, r.total_boosted)
    end
    return rows
end

-- ── admin oversight ──
function Boosting.AdminSearch(query)
    query = (query or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if query == '' then
        return MySQL.query.await('SELECT * FROM xs_boost_stats ORDER BY total_boosted DESC LIMIT 25') or {}
    end
    return MySQL.query.await(
        'SELECT * FROM xs_boost_stats WHERE name LIKE ? OR citizenid = ? ORDER BY total_boosted DESC LIMIT 25',
        { '%' .. query .. '%', query }) or {}
end

function Boosting.AdminSetStats(citizenid, fields)
    local row = getStats(citizenid)
    if not row then return false, 'no stats for that citizenid' end

    local level = math.max(1, math.floor(tonumber(fields.level) or row.level))
    local xp = math.max(0, math.floor(tonumber(fields.xp) or row.xp))
    local totalBoosted = math.max(0, math.floor(tonumber(fields.total_boosted) or row.total_boosted))
    local totalCash = math.max(0, math.floor(tonumber(fields.total_cash) or row.total_cash))
    local perkPoints = math.max(0, math.floor(tonumber(fields.perk_points) or row.perk_points))

    MySQL.update(
        'UPDATE xs_boost_stats SET level = ?, xp = ?, total_boosted = ?, total_cash = ?, perk_points = ? WHERE citizenid = ?',
        { level, xp, totalBoosted, totalCash, perkPoints, citizenid })
    return true
end

function Boosting.AdminResetStats(citizenid)
    local row = getStats(citizenid)
    if not row then return false, 'no stats for that citizenid' end
    MySQL.update(
        'UPDATE xs_boost_stats SET level = 1, xp = 0, total_boosted = 0, total_cash = 0, perk_points = 0, last_boost_at = 0 WHERE citizenid = ?',
        { citizenid })
    MySQL.update('DELETE FROM xs_boost_perks WHERE citizenid = ?', { citizenid })
    return true
end

function Boosting.AdminGetDashboard()
    local totals = MySQL.single.await(
        'SELECT COUNT(*) AS players, COALESCE(SUM(total_boosted),0) AS boosted, COALESCE(SUM(total_cash),0) AS cash FROM xs_boost_stats')
        or { players = 0, boosted = 0, cash = 0 }
    local activeJobs = 0
    local seen = {}
    for _, job in pairs(active) do
        if not seen[job] then seen[job] = true; activeJobs = activeJobs + 1 end
    end
    return { players = totals.players, totalBoosted = totals.boosted, totalCash = totals.cash, activeJobs = activeJobs }
end

-- ── achievements (computed live — no separate "earned" tracking table) ──
function Boosting.GetAchievements(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    local stats = ensureStats(cid, Framework.GetName(src))
    local list = {}
    for _, a in ipairs(Config.Boosting.achievements) do
        local progress = a.type == 'level' and stats.level or stats.total_boosted
        list[#list + 1] = { id = a.id, label = a.label, description = a.description, earned = progress >= a.value }
    end
    return list
end

-- Returns the ids newly crossed between `before` and `after` stat rows —
-- used right after a sale to know what to toast.
local function newlyEarned(before, after)
    local ids = {}
    for _, a in ipairs(Config.Boosting.achievements) do
        local prevProgress = a.type == 'level' and before.level or before.total_boosted
        local newProgress = a.type == 'level' and after.level or after.total_boosted
        if newProgress >= a.value and prevProgress < a.value then ids[#ids + 1] = a.label end
    end
    return ids
end

-- ── wanted vehicles: several active at once, refreshed on a timer ──
local activeWanted = {} -- [id] = { def, id }

local function rollWanted()
    activeWanted = {}
    local pool = Config.Boosting.wanted.pool
    if not Config.Boosting.wanted.enabled or #pool == 0 then return end

    local indices = {}
    for i = 1, #pool do indices[i] = i end
    for i = #indices, 2, -1 do
        local j = math.random(i)
        indices[i], indices[j] = indices[j], indices[i]
    end

    local count = math.min(Config.Boosting.wanted.activeCount, #pool)
    for i = 1, count do
        local id = ('wanted_%d'):format(indices[i])
        activeWanted[id] = { id = id, def = pool[indices[i]] }
    end
end

function Boosting.GetWanted()
    local list = {}
    for _, w in pairs(activeWanted) do
        list[#list + 1] = { id = w.id, label = w.def.label, cash = w.def.cash, xp = w.def.xp }
    end
    return list
end

-- ── co-op crews: invite a specific player, like a gang invite ──
local function crewOf(src)
    if crews[src] then return crews[src], src end -- src is the leader
    for leaderSrc, c in pairs(crews) do
        for _, m in ipairs(c.members) do
            if m == src then return c, leaderSrc end
        end
    end
    return nil, nil
end

function Boosting.GetCrewStatus(src)
    local c, leaderSrc = crewOf(src)
    if not c then return nil end
    return { isLeader = leaderSrc == src, leaderName = c.names[leaderSrc],
             members = c.names, size = #c.members, maxSize = Config.Boosting.coop.maxCrewSize }
end

function Boosting.InviteCoop(src, targetId)
    if not Config.Boosting.coop.enabled then return false, 'co-op is disabled' end
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
    if #c.members >= Config.Boosting.coop.maxCrewSize then return false, 'crew is full' end
    for _, m in ipairs(c.members) do if m == targetId then return false, 'already in your crew' end end
    if crewOf(targetId) then return false, 'that player is already in a crew' end
    if active[targetId] then return false, 'that player is already on a job' end

    pendingCoopInvites[targetId] = { fromSrc = src, fromName = c.names[src] }
    TriggerClientEvent('XS-CriminalTablet:client:coopInvite', targetId, { fromName = c.names[src] })
    return true
end

function Boosting.AcceptCoopInvite(src)
    local invite = pendingCoopInvites[src]
    if not invite then return false, 'no pending invite' end
    pendingCoopInvites[src] = nil

    local c = crews[invite.fromSrc]
    if not c then return false, 'that crew no longer exists' end
    if #c.members >= Config.Boosting.coop.maxCrewSize then return false, 'crew is full' end

    c.members[#c.members + 1] = src
    c.names[src] = Framework.GetName(src) or 'Someone'
    Framework.Notify(invite.fromSrc, ('%s joined your crew.'):format(c.names[src]), 'success')
    TriggerClientEvent('XS-CriminalTablet:client:refresh', invite.fromSrc)
    TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    return true
end

function Boosting.CancelCrew(src)
    if not crews[src] then return false, 'no crew to cancel' end
    crews[src] = nil
    return true
end

function Boosting.Accept(src, wantedId)
    if not Config.Boosting.enabled then return false, 'boosting is disabled' end
    if active[src] then return false, 'already on a job' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'no character' end
    local stats = ensureStats(cid, Framework.GetName(src))
    local mods = modifiersFor(cid)

    local cooldownMs = (stats.last_boost_at + effectiveCooldownMs(stats.level, mods)) - os.time() * 1000
    if cooldownMs > 0 then return false, 'on cooldown' end

    local v
    if wantedId then
        local w = activeWanted[wantedId]
        if not w then return false, 'that wanted vehicle is no longer active' end
        v = w.def
    else
        local pool = vehiclePoolFor(stats.level)
        if #pool == 0 then return false, 'no vehicles configured' end
        v = pool[math.random(#pool)]
    end
    -- Pool the vehicle's own spots with the shared extra ones — which
    -- exact spot a given car lands at doesn't matter mechanically.
    local spawnPool = {}
    for _, s in ipairs(v.spawns) do spawnPool[#spawnPool + 1] = s end
    for _, s in ipairs(Config.Boosting.extraSpawns or {}) do spawnPool[#spawnPool + 1] = s end
    local spawn = spawnPool[math.random(#spawnPool)]
    local plate = ('BST%04d'):format(math.random(0, 9999))

    active[src] = { stage = 'theft', startedAt = os.time() * 1000, vehicleDef = v, plate = plate, mods = mods,
                     spawn = spawn, timeLimitSeconds = Config.Boosting.timeLimitSeconds }
    local g = Config.Boosting.guards
    local guardCount = g.enabled and math.max(0, g.count - mods.guardReduction) or 0
    TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', src,
        { stage = 'theft', spawn = spawn, model = v.model, label = v.label or v.model, plate = plate,
          searchRadius = Config.Boosting.searchRadius, guardTriggerRadius = Config.Boosting.guardTriggerRadius,
          spawnRadius = Config.Boosting.searchRadius + 50.0,
          dispatchDelay = mods.dispatchDelay,
          guards = guardCount > 0 and { count = guardCount, radius = g.radius, model = g.model, weapon = g.weapon } or nil })
    return true
end

-- Co-op: a separate, harder job started for the whole crew at once. Every
-- crew member's active[src] points at the exact same table, so a stage
-- change is instantly visible to all of them — broadcasting the update
-- event to each member is the only thing that has to happen per-person.
function Boosting.AcceptCoop(src)
    if not Config.Boosting.coop.enabled then return false, 'co-op is disabled' end
    local c = crews[src]
    if not c then return false, 'you have no crew — invite someone first' end
    if #c.members < 2 then return false, 'need at least one crew member' end

    for _, m in ipairs(c.members) do
        if active[m] then return false, ('%s is already on a job'):format(c.names[m]) end
    end

    local cids, mods = {}, {}
    for _, m in ipairs(c.members) do
        local mcid = Framework.GetCitizenId(m)
        if not mcid then return false, 'a crew member has no character' end
        cids[m] = mcid
        local stats = ensureStats(mcid, c.names[m])
        local memberMods = modifiersFor(mcid)
        local cooldownMs = (stats.last_boost_at + effectiveCooldownMs(stats.level, memberMods)) - os.time() * 1000
        if cooldownMs > 0 then return false, ('%s is on cooldown'):format(c.names[m]) end
        mods[m] = memberMods
    end

    local pool = Config.Boosting.coop.vehicles
    if #pool == 0 then return false, 'no co-op vehicles configured' end
    local v = pool[math.random(#pool)]
    local spawnPool = {}
    for _, s in ipairs(v.spawns) do spawnPool[#spawnPool + 1] = s end
    for _, s in ipairs(Config.Boosting.extraSpawns or {}) do spawnPool[#spawnPool + 1] = s end
    local spawn = spawnPool[math.random(#spawnPool)]
    local plate = ('BST%04d'):format(math.random(0, 9999))

    local leaderMods = mods[src]
    local g = Config.Boosting.guards
    local guardCount = g.enabled
        and math.max(0, g.count + Config.Boosting.coop.extraGuards - leaderMods.guardReduction) or 0

    local job = {
        stage = 'theft', startedAt = os.time() * 1000, vehicleDef = v, plate = plate,
        coop = true, crew = c.members, crewNames = c.names, leaderSrc = src, cids = cids, mods = leaderMods,
        spawn = spawn, timeLimitSeconds = Config.Boosting.coop.timeLimitSeconds,
    }
    -- Every member gets the same spot. Whoever reaches it first spawns the
    -- vehicle (and later the guards / buyer) via the claim callbacks below,
    -- so nothing depends on where the leader happens to be.
    for _, m in ipairs(c.members) do
        active[m] = job
        TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', m,
            { stage = 'theft', spawn = spawn, model = v.model, label = v.label or v.model, plate = plate,
              isLeader = (m == src),
              searchRadius = Config.Boosting.searchRadius, guardTriggerRadius = Config.Boosting.guardTriggerRadius,
              spawnRadius = Config.Boosting.searchRadius + 50.0,
              dispatchDelay = 0, -- coop always alerts instantly, no perk applies
              coop = true, crewSize = #c.members,
              guards = guardCount > 0 and { count = guardCount, radius = g.radius, model = g.model, weapon = g.weapon } or nil })
    end
    crews[src] = nil
    return true
end

function Boosting.Cancel(src)
    local job = active[src]
    if not job then return false, 'no active job' end
    if job.coop then
        for _, m in ipairs(job.crew) do
            active[m] = nil
            TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', m, nil)
        end
    else
        active[src] = nil
        TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', src, nil)
    end
    return true
end

-- The vehicle's engine actually started — however that happened
-- (qbx_core's own break-in/hotwire system, since we don't run our own).
function Boosting.DoHotwire(src, netId)
    local job = active[src]
    if not job or job.stage ~= 'theft' then return false, 'no active theft' end
    if not job.vehicleNetId or netId ~= job.vehicleNetId then return false, 'wrong vehicle' end

    local dropoff = Config.Boosting.dropoffs[math.random(#Config.Boosting.dropoffs)]
    job.stage = 'dropoff'
    job.dropoff = dropoff

    local payload = { stage = 'dropoff', dropoff = dropoff, dropoffRadius = Config.Boosting.dropoffRadius,
                       buyerPedModel = Config.Boosting.buyerPedModel, vehicleNetId = netId }
    if job.coop then
        for _, m in ipairs(job.crew) do TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', m, payload) end
    else
        TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', src, payload)
    end
    return true
end

-- Applies one member's share of a sale: stats, money, notifications,
-- achievements, activity log. Used identically for a solo sale (one call)
-- and a coop sale (one call per crew member, each with their own cash share).
local function rewardMember(src, cid, v, cash, xp)
    local stats = ensureStats(cid, Framework.GetName(src))
    local newXp = stats.xp + xp
    local newLevel = levelForXp(newXp)
    local leveledUp = newLevel > stats.level

    -- Award perk points for every level actually crossed (a big XP jump
    -- could cross more than one), not just the final level landed on.
    local perkPointsGained = 0
    if leveledUp then
        for _, l in ipairs(sortedLevels()) do
            if l.level > stats.level and l.level <= newLevel then
                perkPointsGained = perkPointsGained + (l.perkPoints or 0)
            end
        end
    end

    MySQL.update(
        'UPDATE xs_boost_stats SET xp = ?, level = ?, total_boosted = total_boosted + 1, ' ..
        'total_cash = total_cash + ?, last_boost_at = ?, perk_points = perk_points + ?, name = ? WHERE citizenid = ?',
        { newXp, newLevel, cash, os.time() * 1000, perkPointsGained, Framework.GetName(src) or cid, cid })

    Framework.AddMoney(src, Config.Boosting.cashAccount or 'cash', cash, 'xs-boost-sale')
    Framework.Notify(src, ('Sold — +$%d, +%d XP.'):format(cash, xp), 'success')
    if leveledUp then
        Framework.Notify(src, ('Level up! You are now a %s.'):format(levelDefFor(newLevel).label), 'success')
        if perkPointsGained > 0 then
            Framework.Notify(src, ('+%d perk point%s to spend.'):format(perkPointsGained, perkPointsGained > 1 and 's' or ''), 'success')
        end
    end

    local afterStats = { level = newLevel, total_boosted = stats.total_boosted + 1 }
    for _, label in ipairs(newlyEarned(stats, afterStats)) do
        Framework.Notify(src, ('Achievement unlocked: %s'):format(label), 'success')
    end

    MySQL.insert('INSERT INTO xs_boost_log (name, vehicle_label, cash) VALUES (?, ?, ?)',
        { Framework.GetName(src) or cid, v.label or v.model, cash })
end

-- Sold to the buyer ped: validated by the TRACKED VEHICLE's actual
-- position (via its network id), not the player's — and the player must
-- have actually gotten out of it first, not just parked nearby.
function Boosting.DoDropoff(src, netId)
    local job = active[src]
    if not job or job.stage ~= 'dropoff' or job.vehicleNetId == nil then return false, 'no active drop-off' end
    if netId ~= job.vehicleNetId then return false, 'wrong vehicle' end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'vehicle not found' end
    -- job.dropoff is a vec4 (carries heading for the buyer ped) — strip to
    -- vec3 for the distance check so we're never doing vector4 arithmetic.
    local dropoffPos = vec3(job.dropoff.x, job.dropoff.y, job.dropoff.z)
    if dist(GetEntityCoords(vehicle), dropoffPos) > Config.Boosting.dropoffRadius then
        return false, 'the vehicle is too far from the drop-off'
    end

    local ped = GetPlayerPed(src)
    if GetVehiclePedIsIn(ped, false) == vehicle then
        return false, 'get out of the vehicle first'
    end

    if job.coop then
        for _, m in ipairs(job.crew) do
            active[m] = nil
            TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', m, nil)
        end
    else
        active[src] = nil
        TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', src, nil)
    end

    local v = job.vehicleDef
    if job.coop then
        local total = math.floor((v.cash or 0) * (1 + (Config.Boosting.coop.cashBonusPct or 0) / 100)
            * (1 + (job.mods.cashBonusPct or 0) / 100))
        local crewSize = #job.crew
        local share = math.floor(total / crewSize)
        local remainder = total - (share * crewSize)
        for i, m in ipairs(job.crew) do
            local memberCash = share + (i == 1 and remainder or 0) -- leader absorbs the rounding remainder
            local mcid = job.cids[m]
            if mcid then rewardMember(m, mcid, v, memberCash, v.xp or 0) end
        end
    else
        local cid = Framework.GetCitizenId(src)
        if not cid then return true end
        local mods = job.mods or modifiersFor(cid)
        local cash = math.floor((v.cash or 0) * (1 + mods.cashBonusPct / 100))
        rewardMember(src, cid, v, cash, v.xp or 0)
    end

    return true
end

-- Cumulative vehicle pool for the UI's "what might I get" preview.
function Boosting.GetAvailableVehicles(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    local stats = ensureStats(cid, Framework.GetName(src))
    local list = {}
    for _, v in ipairs(vehiclePoolFor(stats.level)) do
        list[#list + 1] = { label = v.label or v.model, cash = v.cash, xp = v.xp }
    end
    return list
end

function Boosting.GetRecentActivity()
    return MySQL.query.await(
        'SELECT name, vehicle_label, cash, created_at FROM xs_boost_log ORDER BY id DESC LIMIT ?',
        { Config.Boosting.recentActivityLimit or 10 }) or {}
end

CreateThread(function()
    while true do
        Wait(1500)
        for src, job in pairs(active) do
            if GetPlayerName(src) == nil then
                active[src] = nil
            elseif (os.time() * 1000) - job.startedAt > (job.timeLimitSeconds or Config.Boosting.timeLimitSeconds) * 1000 then
                active[src] = nil
                TriggerClientEvent('XS-CriminalTablet:client:boostUpdate', src, nil)
                Framework.Notify(src, 'Job window expired.', 'error')
            end
        end
    end
end)

CreateThread(function()
    rollWanted()
    while true do
        Wait(Config.Boosting.wanted.rotateMinutes * 60 * 1000)
        rollWanted()
        if Config.Debug then print('^3[XS-CriminalTablet]^0 boosting wanted vehicles rerolled') end
    end
end)

AddEventHandler('playerDropped', function()
    active[source] = nil
    crews[source] = nil
    pendingCoopInvites[source] = nil
    -- if they were a member (not leader) of someone else's crew, drop them from it
    for _, c in pairs(crews) do
        for i, m in ipairs(c.members) do
            if m == source then table.remove(c.members, i); c.names[source] = nil; break end
        end
    end
end)

lib.callback.register('XS-CriminalTablet:boosting:getStatus', function(src)
    return Boosting.GetStatus(src)
end)

lib.callback.register('XS-CriminalTablet:boosting:getCrewStatus', function(src)
    return Boosting.GetCrewStatus(src)
end)

lib.callback.register('XS-CriminalTablet:boosting:inviteCoop', function(src, targetId)
    local ok, err = Boosting.InviteCoop(src, targetId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:boosting:cancelCrew', function(src)
    local ok, err = Boosting.CancelCrew(src)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:boosting:acceptCoop', function(src)
    local ok, err = Boosting.AcceptCoop(src)
    return { ok = ok, error = err }
end)

RegisterNetEvent('XS-CriminalTablet:server:acceptCoopInvite', function()
    local src = source
    local ok, err = Boosting.AcceptCoopInvite(src)
    Framework.Notify(src, ok and 'Joined the crew.' or ('Could not join: ' .. tostring(err)), ok and 'success' or 'error')
end)

lib.callback.register('XS-CriminalTablet:boosting:getPerks', function(src)
    local perks, perkPoints = Boosting.GetPerks(src)
    return { perks = perks, perkPoints = perkPoints }
end)

lib.callback.register('XS-CriminalTablet:boosting:buyPerk', function(src, perkId)
    local ok, err = Boosting.BuyPerk(src, perkId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:boosting:getLeaderboard', function()
    return Boosting.GetLeaderboard()
end)

lib.callback.register('XS-CriminalTablet:boosting:getAvailableVehicles', function(src)
    return Boosting.GetAvailableVehicles(src)
end)

lib.callback.register('XS-CriminalTablet:boosting:getRecentActivity', function()
    return Boosting.GetRecentActivity()
end)

lib.callback.register('XS-CriminalTablet:boosting:getAchievements', function(src)
    return Boosting.GetAchievements(src)
end)

lib.callback.register('XS-CriminalTablet:boosting:getWanted', function()
    return Boosting.GetWanted()
end)

lib.callback.register('XS-CriminalTablet:boosting:accept', function(src, wantedId)
    local ok, err = Boosting.Accept(src, wantedId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:boosting:cancel', function(src)
    local ok, err = Boosting.Cancel(src)
    return { ok = ok, error = err }
end)

-- Spawn claims: the first crew member to reach something spawns it, the
-- rest are told its network id. A claim held by someone who has since
-- dropped is handed on.
local function claimSpawn(src, wantStage, spawnerKey, netIdKey)
    local job = active[src]
    if not job or job.stage ~= wantStage then return { ok = false } end
    if job[netIdKey] then return { ok = false, netId = job[netIdKey] } end
    local holder = job[spawnerKey]
    if holder and holder ~= src and GetPlayerName(holder) ~= nil then return { ok = false } end
    job[spawnerKey] = src
    return { ok = true }
end

local function registerSpawn(src, wantStage, spawnerKey, netIdKey, netId, event)
    local job = active[src]
    if not job or job.stage ~= wantStage or job[spawnerKey] ~= src then return { ok = false } end
    netId = tonumber(netId)
    if not netId then return { ok = false } end
    job[netIdKey] = netId
    local targets = job.coop and job.crew or { src }
    for _, m in ipairs(targets) do
        if m ~= src then TriggerClientEvent(event, m, { netId = netId }) end
    end
    return { ok = true }
end

lib.callback.register('XS-CriminalTablet:boosting:claimVehicle', function(src)
    return claimSpawn(src, 'theft', 'vehicleSpawner', 'vehicleNetId')
end)

lib.callback.register('XS-CriminalTablet:boosting:registerVehicle', function(src, netId)
    return registerSpawn(src, 'theft', 'vehicleSpawner', 'vehicleNetId', netId, 'XS-CriminalTablet:client:boostVehicle')
end)

lib.callback.register('XS-CriminalTablet:boosting:claimGuards', function(src)
    local job = active[src]
    if not job or job.stage ~= 'theft' or job.guardsClaimed then return { ok = false } end
    job.guardsClaimed = src
    return { ok = true }
end)

lib.callback.register('XS-CriminalTablet:boosting:claimBuyer', function(src)
    return claimSpawn(src, 'dropoff', 'buyerSpawner', 'buyerNetId')
end)

lib.callback.register('XS-CriminalTablet:boosting:registerBuyer', function(src, netId)
    return registerSpawn(src, 'dropoff', 'buyerSpawner', 'buyerNetId', netId, 'XS-CriminalTablet:client:boostBuyer')
end)

lib.callback.register('XS-CriminalTablet:boosting:doHotwire', function(src, netId)
    local ok, err = Boosting.DoHotwire(src, tonumber(netId))
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:boosting:doDropoff', function(src, netId)
    local ok, err = Boosting.DoDropoff(src, tonumber(netId))
    return { ok = ok, error = err }
end)
