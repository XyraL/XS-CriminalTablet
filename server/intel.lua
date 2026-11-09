-- ─────────────────────────────────────────────────────────────
-- Rival intel. Everything one crew does to another is remembered for the
-- Rivals app, and the crew it happens to hears about it straight away:
-- tags on their walls, work on their blocks, rivals hanging round their
-- HQ, members taken out, raids and wars.
-- ─────────────────────────────────────────────────────────────
Intel = {}

local cooldowns = {}
local dwell = {}
local recentKills = {}
local DAY = 86400000

local function now() return os.time() * 1000 end

function Intel.On() return Config.Intel and Config.Intel.enabled end

function Intel.Record(kind, actorId, targetId, detail, coords, actorName)
    if not actorId or not targetId or actorId == targetId then return end
    MySQL.insert('INSERT INTO `xs_gang_events` (`kind`, `actor_id`, `target_id`, `detail`, `actor_name`, `x`, `y`, `z`, `created_at`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { kind, actorId, targetId, tostring(detail or ''):sub(1, 160), tostring(actorName or ''):sub(1, 96),
          coords and coords.x + 0.0 or 0.0, coords and coords.y + 0.0 or 0.0, coords and coords.z + 0.0 or 0.0, now() })
end

-- Tell a crew right away, at most once per place per few minutes.
function Intel.Alert(targetId, kind, key, message, coords)
    if not Intel.On() then return end
    local k = ('%s:%s:%s'):format(targetId, kind, tostring(key))
    if (cooldowns[k] or 0) > now() then return end
    cooldowns[k] = now() + (Config.Intel.alertCooldownMinutes or 5) * 60000
    local entry = { kind = kind, message = message, at = now() }
    if coords then entry.x, entry.y, entry.z = coords.x + 0.0, coords.y + 0.0, coords.z + 0.0 end
    for _, src in ipairs(Gangs.OnlineSources(targetId)) do
        Framework.Notify(src, message, 'error')
        TriggerClientEvent('XS-CriminalTablet:client:sync', src, 'intel', entry)
    end
end

-- Record it and, when there is something to say, say it.
function Intel.Event(kind, actorId, targetId, opts)
    opts = opts or {}
    Intel.Record(kind, actorId, targetId, opts.detail, opts.coords, opts.name)
    if opts.alert then Intel.Alert(targetId, kind, opts.key or kind, opts.alert, opts.coords) end
end

-- A member of one crew killed by a member of another. The victim reports
-- it; both deaths paths fire, so one of them is dropped here.
function Intel.Kill(killerSrc, victimSrc, killerGang, victimGang)
    if not Intel.On() or killerGang.id == victimGang.id then return end
    local key = ('%s:%s'):format(killerSrc, victimSrc)
    if (recentKills[key] or 0) + 15000 > now() then return end
    recentKills[key] = now()
    local victimName = Framework.GetName(victimSrc) or 'Someone'
    local pos = GetEntityCoords(GetPlayerPed(victimSrc))
    Intel.Event('kill', killerGang.id, victimGang.id, {
        detail = victimName, coords = pos, name = Framework.GetName(killerSrc),
        key = killerGang.id,
        alert = Config.Intel.alertKills and ('%s was taken out by %s.'):format(victimName, killerGang.label) or nil,
    })
end

-- Rivals near a crew's HQ, checked every few seconds against the server's
-- own idea of where everyone is.
function Intel.WatchHQs(step)
    if not Intel.On() then return end
    step = step or 5
    local hqs = {}
    for _, r in ipairs(Placeables.GetAll()) do
        if r.kind == 'hq' then hqs[#hqs + 1] = { gangId = r.gang_id, coords = vec3(r.x + 0.0, r.y + 0.0, r.z + 0.0) } end
    end
    if #hqs == 0 then return end
    local near = {}
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        local gang = Gangs.GetBySource(src)
        local ped = GetPlayerPed(src)
        if gang and ped and ped ~= 0 and GetEntityHealth(ped) > 0 then
            local pos = GetEntityCoords(ped)
            for _, hq in ipairs(hqs) do
                if hq.gangId ~= gang.id and #(pos - hq.coords) <= Config.Intel.hqRadius then
                    local k = hq.gangId .. ':' .. gang.id
                    near[k] = near[k] or { hq = hq, rival = gang, count = 0 }
                    near[k].count = near[k].count + 1
                end
            end
        end
    end
    for k in pairs(dwell) do if not near[k] then dwell[k] = nil end end
    for k, n in pairs(near) do
        dwell[k] = (dwell[k] or 0) + step
        if dwell[k] >= Config.Intel.hqSeconds then
            local fresh = (cooldowns[('%s:hq:%s'):format(n.hq.gangId, n.rival.id)] or 0) <= now()
            if fresh then
                Intel.Record('hq', n.rival.id, n.hq.gangId, ('%d seen'):format(n.count), n.hq.coords)
                Intel.Alert(n.hq.gangId, 'hq', n.rival.id, ('%s %s hanging round your HQ.'):format(
                    n.count == 1 and 'Someone from' or ('%d from'):format(n.count), n.rival.label), n.hq.coords)
            end
        end
    end
end

-- ── what the tablet reads ───────────────────────────────────
local function events(myId, rivalId, limit)
    local sql = 'SELECT * FROM `xs_gang_events` WHERE (`actor_id` = ? AND `target_id` = ?) OR (`actor_id` = ? AND `target_id` = ?) ORDER BY `id` DESC LIMIT ?'
    return MySQL.query.await(sql, { myId, rivalId, rivalId, myId, limit or 500 }) or {}
end

local function tally(myId, list)
    local t = { warsWon = 0, warsLost = 0, warsDrawn = 0, raidsWon = 0, raidsLost = 0, killsOurs = 0, killsTheirs = 0,
        tagsOnUs = 0, workOnUs = 0, hqVisits = 0, week = 0, last = 0 }
    for _, e in ipairs(list) do
        local ours = e.actor_id == myId
        local won = (e.detail == 'won') == ours
        if e.kind == 'war' then
            if e.detail == 'draw' then t.warsDrawn = t.warsDrawn + 1 elseif won then t.warsWon = t.warsWon + 1 else t.warsLost = t.warsLost + 1 end
        elseif e.kind == 'raid' then
            if won then t.raidsWon = t.raidsWon + 1 else t.raidsLost = t.raidsLost + 1 end
        elseif e.kind == 'kill' then
            if ours then t.killsOurs = t.killsOurs + 1 else t.killsTheirs = t.killsTheirs + 1 end
        elseif not ours and (e.kind == 'tag' or e.kind == 'cover') then t.tagsOnUs = t.tagsOnUs + 1
        elseif not ours and e.kind == 'work' then t.workOnUs = t.workOnUs + 1
        elseif not ours and e.kind == 'hq' then t.hqVisits = t.hqVisits + 1 end
        if (e.created_at or 0) > now() - 7 * DAY then t.week = t.week + 1 end
        if (e.created_at or 0) > t.last then t.last = e.created_at end
    end
    return t
end

function Intel.Rivals(src)
    local me = Gangs.GetBySource(src)
    if not me then return { rivals = {} } end
    local out = {}
    for _, row in ipairs(MySQL.query.await('SELECT `id` FROM `xs_gangs`') or {}) do
        if row.id ~= me.id then
            local g = Gangs.Get(row.id)
            if g then
                local t = tally(me.id, events(me.id, g.id, 500))
                out[#out + 1] = {
                    id = g.id, label = g.label, color = g.color, logo = g.logo,
                    tier = Rep.Tier(g.notoriety), level = Rep.GangLevel(g.notoriety).level,
                    members = Gangs.MemberCount(g), blocks = Territory.CountHeldBy(g.id), record = t,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.record.week ~= b.record.week then return a.record.week > b.record.week end
        return a.label < b.label
    end)
    local feed = MySQL.query.await('SELECT * FROM `xs_gang_events` WHERE `target_id` = ? ORDER BY `id` DESC LIMIT 15', { me.id }) or {}
    local labels = {}
    for _, e in ipairs(feed) do
        local g = Gangs.Get(e.actor_id)
        labels[#labels + 1] = { kind = e.kind, crew = g and g.label or '?', color = g and g.color or nil, detail = e.detail, name = e.actor_name, at = e.created_at, x = e.x, y = e.y }
    end
    return { rivals = out, feed = labels, myId = me.id }
end

function Intel.Dossier(src, rivalId)
    local me = Gangs.GetBySource(src)
    local g = Gangs.Get(tonumber(rivalId))
    if not me or not g or g.id == me.id then return nil end
    local list = events(me.id, g.id, 500)
    local faces, seen = {}, {}
    for _, e in ipairs(list) do
        -- Faces are only ever people the crew has actually run into: the
        -- ones who did something to them, or the ones they took out.
        local name = (e.actor_id == g.id and e.actor_name ~= '' and e.actor_name) or (e.kind == 'kill' and e.actor_id == me.id and e.detail) or nil
        if name and name ~= '' then
            if not seen[name] then seen[name] = { name = name, last = e.created_at, count = 0 }; faces[#faces + 1] = seen[name] end
            seen[name].count = seen[name].count + 1
        end
    end
    local blocks = {}
    for _, z in ipairs(Territory.HeldBy(g.id)) do
        local c = Territory.CenterOf(z.zone)
        blocks[#blocks + 1] = { zone = z.zone, label = z.label, x = c and c.x or nil, y = c and c.y or nil }
    end
    local timeline = {}
    for i = 1, math.min(25, #list) do
        local e = list[i]
        timeline[#timeline + 1] = { kind = e.kind, ours = e.actor_id == me.id, detail = e.detail, name = e.actor_name, at = e.created_at, x = e.x, y = e.y }
    end
    local level = Rep.GangLevel(g.notoriety)
    return {
        crew = { id = g.id, label = g.label, color = g.color, logo = g.logo, tier = Rep.Tier(g.notoriety), level = level.level, levelTitle = level.title,
            members = Gangs.MemberCount(g), online = #Gangs.OnlineSources(g.id), warWins = g.war_wins or 0, warLosses = g.war_losses or 0,
            treasury = Config.Analytics.publicTreasury and g.bank or nil },
        record = tally(me.id, list), faces = faces, blocks = blocks, timeline = timeline,
    }
end

CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `xs_gang_events` (
            `id`         INT          NOT NULL AUTO_INCREMENT,
            `kind`       VARCHAR(16)  NOT NULL,
            `actor_id`   INT          NOT NULL,
            `target_id`  INT          NOT NULL,
            `detail`     VARCHAR(160) NOT NULL DEFAULT '',
            `actor_name` VARCHAR(96)  NOT NULL DEFAULT '',
            `x` FLOAT NOT NULL DEFAULT 0, `y` FLOAT NOT NULL DEFAULT 0, `z` FLOAT NOT NULL DEFAULT 0,
            `created_at` BIGINT       NOT NULL,
            PRIMARY KEY (`id`),
            KEY `idx_pair` (`actor_id`, `target_id`),
            KEY `idx_target` (`target_id`, `created_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    while true do
        MySQL.update('DELETE FROM `xs_gang_events` WHERE `created_at` < ?', { now() - (Config.Intel.keepDays or 30) * DAY })
        Wait(6 * 3600000)
    end
end)

CreateThread(function()
    Wait(10000)
    while true do
        Wait(5000)
        local ok, err = pcall(Intel.WatchHQs, 5)
        if not ok and Config.Debug then print('^1[XS-CriminalTablet]^0 intel watch: ' .. tostring(err)) end
    end
end)

lib.callback.register('XS-CriminalTablet:intel:rivals', function(src)
    if not Intel.On() then return { rivals = {} } end
    return Intel.Rivals(src)
end)

lib.callback.register('XS-CriminalTablet:intel:dossier', function(src, rivalId)
    if not Intel.On() then return nil end
    return Intel.Dossier(src, rivalId)
end)
