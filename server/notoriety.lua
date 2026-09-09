-- ─────────────────────────────────────────────────────────────
-- Notoriety: a gang-wide reputation score that rises with activity
-- and decays with inactivity. Tiers can gate future apps/markets.
-- ─────────────────────────────────────────────────────────────
Notoriety = {}

function Notoriety.Tier(score)
    local name = Config.Notoriety.tiers[1].name
    for _, t in ipairs(Config.Notoriety.tiers) do
        if score >= t.min then name = t.name end
    end
    return name
end

-- Current tier's floor and the next tier's floor (nil if already at the
-- top), for progress-bar UI. Computed server-side since config.lua isn't
-- reachable from the NUI webview.
function Notoriety.Progress(score)
    local tiers = Config.Notoriety.tiers
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

-- A more granular prestige number+title on the SAME notoriety value the
-- broad tiers use — purely additive, doesn't affect tier-gated unlocks.
function Notoriety.GangLevel(score)
    local best = sortedGangLevels()[1]
    for _, l in ipairs(sortedGangLevels()) do
        if score >= l.repNeeded then best = l end
    end
    return best
end

function Notoriety.NextGangLevel(level)
    for _, l in ipairs(sortedGangLevels()) do
        if l.level > level then return l end
    end
    return nil -- already max
end

-- Add (or subtract, with negative amount) notoriety to a gang.
-- Exported so other resources can reward your gangs:
--   exports.XS-CriminalTablet:AddNotoriety(gangId, amount, reason)
function Notoriety.Add(gangId, amount, reason)
    local gang = Gangs.Get(gangId)
    if not gang then return end
    local oldLevel = Notoriety.GangLevel(gang.notoriety).level
    local newVal = math.max(0, math.min(Config.Notoriety.max, gang.notoriety + amount))
    gang.notoriety = newVal
    local newLevel = Notoriety.GangLevel(newVal).level

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
            Notoriety.GangLevel(newVal).title, perkPointsGained, perkPointsGained > 1 and 's' or ''))
    end

    if Config.Debug then
        print(('^3[XS-CriminalTablet]^0 gang %d notoriety %+d (%s) -> %d'):format(gangId, amount, reason or '?', newVal))
    end

    -- tier may have just changed, so re-push territory state (drives unlocks).
    if Territory then TriggerClientEvent('XS-CriminalTablet:client:territoryUpdate', -1, Territory.GetAssigned()) end
end

exports('AddNotoriety', function(gangId, amount, reason)
    Notoriety.Add(gangId, amount, reason)
end)

-- Friendly fire: killing your own gang member costs the killer rep. The
-- victim self-reports their death + killer (client-side, like the kill
-- task's "target down" report) — the server only acts on it if both
-- players actually belong to the same gang and aren't the same person.
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

    Gangs.AddMemberRep(killerCid, -Config.Notoriety.friendlyFirePenalty, 'friendly_fire')
    Gangs.Log(killerGang.id, ('%s killed a fellow member (%s) — -%d rep'):format(
        Framework.GetName(killerServerId) or killerCid, Framework.GetName(victimSrc) or victimCid,
        Config.Notoriety.friendlyFirePenalty))
end)
