-- ─────────────────────────────────────────────────────────────
-- Street standing: every gang on the server ranked side by side.
--
-- The composite score is deliberately config-weighted rather than hard
-- coded — what "the biggest crew on the server" means is a server-owner
-- decision, not this script's.
--
-- Rival treasuries are hidden unless Config.Analytics.publicTreasury is
-- on, because knowing exactly how much a gang is holding turns the
-- standings board into a raid shopping list.
-- ─────────────────────────────────────────────────────────────
Analytics = {}

local function scoreOf(row, zones, members)
    local w = Config.Analytics.weights
    return math.floor(
        (row.notoriety or 0) * w.rep
        + zones * w.territory
        + members * w.members
        + (row.bank or 0) * w.treasury
        + (row.war_wins or 0) * w.warWins
    )
end

function Analytics.Standings(src)
    if not Config.Analytics.enabled then return { gangs = {} } end
    local myGang = Gangs.GetBySource(src)
    local myId = myGang and myGang.id or nil

    local rows = MySQL.query.await(
        'SELECT id, label, color, notoriety, bank, war_wins, war_losses FROM xs_gangs') or {}

    local counts = {}
    for _, r in ipairs(MySQL.query.await(
        'SELECT gang_id, COUNT(*) AS n FROM xs_gang_members GROUP BY gang_id') or {}) do
        counts[r.gang_id] = r.n
    end

    local list = {}
    for _, row in ipairs(rows) do
        local zones = Territory.CountHeldBy(row.id)
        local members = counts[row.id] or 0
        local mine = row.id == myId
        list[#list + 1] = {
            id = row.id,
            label = row.label,
            color = row.color,
            tier = Rep.Tier(row.notoriety),
            level = Rep.GangLevel(row.notoriety).level,
            levelTitle = Rep.GangLevel(row.notoriety).title,
            rep = row.notoriety,
            zones = zones,
            members = members,
            online = #Gangs.OnlineSources(row.id),
            warWins = row.war_wins or 0,
            warLosses = row.war_losses or 0,
            -- Only ever expose the number when it's your own crew, or the
            -- server has explicitly opted into public books.
            treasury = (mine or Config.Analytics.publicTreasury) and row.bank or nil,
            score = scoreOf(row, zones, members),
            mine = mine,
        }
    end

    table.sort(list, function(a, b) return a.score > b.score end)
    for i, g in ipairs(list) do g.rank = i end

    local limited = {}
    for i = 1, math.min(#list, Config.Analytics.limit) do limited[#limited + 1] = list[i] end

    -- Always include the caller's own gang even if it's off the bottom of
    -- the board — seeing where you actually stand is the point.
    local myEntry
    for _, g in ipairs(list) do if g.mine then myEntry = g break end end
    local inList = false
    for _, g in ipairs(limited) do if g.mine then inList = true break end end
    if myEntry and not inList then limited[#limited + 1] = myEntry end

    -- Where the caller's own crew sits across each individual measure.
    local breakdown = nil
    if myEntry then
        local function rankBy(field)
            local sorted = {}
            for _, g in ipairs(list) do sorted[#sorted + 1] = g end
            table.sort(sorted, function(a, b) return (a[field] or 0) > (b[field] or 0) end)
            for i, g in ipairs(sorted) do if g.mine then return i end end
            return #sorted
        end
        breakdown = {
            total = #list,
            overall = myEntry.rank,
            rep = rankBy('rep'),
            territory = rankBy('zones'),
            members = rankBy('members'),
            wars = rankBy('warWins'),
        }
    end

    return { gangs = limited, breakdown = breakdown, weights = Config.Analytics.weights }
end

lib.callback.register('XS-CriminalTablet:analytics:getStandings', function(src)
    if not Gangs.HasPerm(src, 'view_analytics') then return { gangs = {}, error = 'no permission' } end
    return Analytics.Standings(src)
end)
