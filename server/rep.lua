-- ─────────────────────────────────────────────────────────────
-- Rep: the gang-wide reputation score. No idle decay — it only drops
-- from the friendly-fire penalty, losing turf or a war, or a staff
-- adjustment. Tiers gate unlocks and recipes; levels award perk points.
--
-- The database column is still called `notoriety` — renaming a live
-- column buys nothing and risks everything, so only the name players
-- and server owners actually read was changed.
-- ─────────────────────────────────────────────────────────────
Rep = {}

function Rep.Tier(score)
    local name = Config.Rep.tiers[1].name
    for _, t in ipairs(Config.Rep.tiers) do
        if score >= t.min then name = t.name end
    end
    return name
end

-- Current tier's floor and the next tier's floor (nil if already at the
-- top), for progress-bar UI. Computed server-side since config.lua isn't
-- reachable from the NUI webview.
function Rep.Progress(score)
    local tiers = Config.Rep.tiers
    local currentMin = tiers[1].min
    local nextMin = nil
    for i, t in ipairs(tiers) do
        if score >= t.min then
            currentMin = t.min
            nextMin = tiers[i + 1] and tiers[i + 1].min or nil
        end
    end
    return currentMin, nextMin
end

local function sortedGangLevels()
    local levels = {}
    for _, l in ipairs(Config.GangLevels) do levels[#levels + 1] = l end
    table.sort(levels, function(a, b) return a.level < b.level end)
    return levels
end

-- A more granular prestige number+title on the SAME rep value the
-- broad tiers use — purely additive, doesn't affect tier-gated unlocks.
function Rep.GangLevel(score)
    local best = sortedGangLevels()[1]
    for _, l in ipairs(sortedGangLevels()) do
        if score >= l.repNeeded then best = l end
    end
    return best
end

function Rep.NextGangLevel(level)
    for _, l in ipairs(sortedGangLevels()) do
        if l.level > level then return l end
    end
    return nil -- already max
end

-- Add (or subtract, with negative amount) rep to a gang.
-- Exported so other resources can reward your gangs:
--   exports['XS-CriminalTablet']:AddRep(gangId, amount, reason)
function Rep.Add(gangId, amount, reason)
    local gang = Gangs.Get(gangId)
    if not gang then return end
    local oldLevel = Rep.GangLevel(gang.notoriety).level
    local newVal = math.max(0, math.min(Config.Rep.max, gang.notoriety + amount))
    gang.notoriety = newVal
    local newLevel = Rep.GangLevel(newVal).level

    -- Award perk points for every gang level actually crossed (a big swing
    -- could cross more than one), not just the final level landed on.
    local perkPointsGained = 0
    if newLevel > oldLevel then
        for _, l in ipairs(sortedGangLevels()) do
            if l.level > oldLevel and l.level <= newLevel then
                perkPointsGained = perkPointsGained + (l.perkPoints or 0)
            end
        end
    end

    MySQL.update('UPDATE xs_gangs SET notoriety = ?, last_active = ?, perk_points = perk_points + ? WHERE id = ?',
        { newVal, os.time() * 1000, perkPointsGained, gangId })
    if perkPointsGained > 0 then
        gang.perk_points = (gang.perk_points or 0) + perkPointsGained
        Gangs.Log(gangId, ('Reached %s — +%d perk point%s'):format(
            Rep.GangLevel(newVal).title, perkPointsGained, perkPointsGained > 1 and 's' or ''))
    end

    if Config.Debug then
        print(('^3[XS-CriminalTablet]^0 gang %d rep %+d (%s) -> %d'):format(gangId, amount, reason or '?', newVal))
    end

    -- tier may have just changed, so re-push territory state (drives unlocks).
    if Territory and Territory.Broadcast then Territory.Broadcast() end
    if Gangs and Gangs.Broadcast then
        Gangs.Broadcast(gangId, 'rep', { rep = newVal, tier = Rep.Tier(newVal) })
    end
end

exports('AddRep', function(gangId, amount, reason)
    Rep.Add(gangId, amount, reason)
end)

-- Kept so anything already wired to the 1.x name keeps working.
exports('AddNotoriety', function(gangId, amount, reason)
    Rep.Add(gangId, amount, reason)
end)

-- Friendly fire: killing your own gang member costs the killer rep. The
-- victim self-reports their death + killer (client-side, like the kill
-- task's "target down" report) — the server only acts on it if both
-- players actually belong to the same gang and aren't the same person.
local recentFriendlyFire = {}

RegisterNetEvent('XS-CriminalTablet:server:reportGangKill', function(killerServerId)
    local victimSrc = source
    killerServerId = tonumber(killerServerId)
    if not killerServerId or killerServerId == victimSrc then return end

    local victimCid = Framework.GetCitizenId(victimSrc)
    local killerCid = Framework.GetCitizenId(killerServerId)
    if not victimCid or not killerCid then return end

    local victimGang = Gangs.GetByCitizen(victimCid)
    local killerGang = Gangs.GetByCitizen(killerCid)
    if not victimGang or not killerGang or victimGang.id ~= killerGang.id then return end

    -- One death reaches here twice: the damage event in client/war.lua fires
    -- it, and so does the death poll in client/main.lua. Without this the
    -- killer is docked the penalty twice and the log reads double.
    local pairKey = killerCid .. ':' .. victimCid
    local at = os.time() * 1000
    if (recentFriendlyFire[pairKey] or 0) + 15000 > at then return end
    recentFriendlyFire[pairKey] = at

    Gangs.AddMemberRep(killerCid, -Config.Rep.friendlyFirePenalty, 'friendly_fire')
    Gangs.Log(killerGang.id, ('%s killed a fellow member (%s) — -%d rep'):format(
        Framework.GetName(killerServerId) or killerCid, Framework.GetName(victimSrc) or victimCid,
        Config.Rep.friendlyFirePenalty))
end)
