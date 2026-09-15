-- ─────────────────────────────────────────────────────────────
-- Raids and gang war.
--
-- RAID — a short strike on a rival's HQ. The attacker stages cash, gets a
--   prep window (the defender is told, always — no blindsides), then has
--   to hold the defender's HQ uncontested for holdSeconds. Winner takes a
--   cut of the loser's treasury (and a zone, if captureZoneOnWin is on).
--
-- WAR — a declared, two-sided fight. Kills between the two gangs feed a
--   shared meter; whoever leads by scoreToWin (or is ahead when the clock
--   runs out) wins. Winning opens the stash raid.
--
-- STASH RAID — after a war win, the loser's placed Crew Safe is lootable
--   for a window. Real cash out of their treasury and real stacks out of
--   their vault, so the safe is a genuine liability to place.
-- ─────────────────────────────────────────────────────────────
War = {}

local active = {}        -- [warId] = live state

-- Staging a raid or a war yields (the treasury charge, then the insert) well
-- before the result lands in `active`, and War.ActiveFor only reads `active`.
-- Two clicks on the button therefore both got through: two rows, two ticking
-- states for one pair, and the cost taken twice. Claimed synchronously, so the
-- second call loses before it can yield.
--
-- Stamped rather than flagged so a claim cannot outlive its call: if the
-- insert throws between the charge and the release, the pair frees itself
-- instead of locking that crew out of raiding until the next restart.
local staging = {}
local STAGING_TTL = 10

local function claimPair(a, b)
    local t = os.time()
    if (staging[a] or 0) + STAGING_TTL > t or (staging[b] or 0) + STAGING_TTL > t then return false end
    staging[a], staging[b] = t, t
    return true
end

local function releasePair(a, b)
    staging[a], staging[b] = nil, nil
end

local recentKills = {}   -- ['killerCid:victimCid'] = unix ms

local function now() return os.time() * 1000 end

local function onlineCount(gangId)
    return #Gangs.OnlineSources(gangId)
end

local function bothSides(state, fn)
    fn(state.attackerId)
    fn(state.defenderId)
end

local function announce(state, message, type)
    bothSides(state, function(gangId)
        Gangs.NotifyGang(gangId, message, type or 'inform')
    end)
end

local function pushState(state)
    bothSides(state, function(gangId)
        Gangs.Broadcast(gangId, 'war', War.PublicState(state))
    end)
end

-- ── shared state shape ──────────────────────────────────────
function War.PublicState(state)
    if not state then return nil end
    local attacker = Gangs.Get(state.attackerId)
    local defender = Gangs.Get(state.defenderId)
    return {
        id = state.id,
        kind = state.kind,
        phase = state.phase,
        attackerId = state.attackerId,
        attackerLabel = attacker and attacker.label or '?',
        attackerColor = attacker and attacker.color or nil,
        defenderId = state.defenderId,
        defenderLabel = defender and defender.label or '?',
        defenderColor = defender and defender.color or nil,
        scoreAttack = state.scoreAttack or 0,
        scoreDefend = state.scoreDefend or 0,
        scoreToWin = Config.War.war.scoreToWin,
        holdProgress = state.holdProgress and math.floor(state.holdProgress) or 0,
        holdTarget = Config.War.raid.holdSeconds,
        endsAt = state.endsAt,
        startsAt = state.startsAt,
        target = state.targetCoords and
            { x = state.targetCoords.x, y = state.targetCoords.y, z = state.targetCoords.z } or nil,
        radius = Config.War.raid.radius,
    }
end

-- The engagement a given gang is currently in, if any.
function War.ActiveFor(gangId)
    for _, state in pairs(active) do
        if state.attackerId == gangId or state.defenderId == gangId then return state end
    end
    return nil
end

-- ── finishing ───────────────────────────────────────────────
local function payoutRaid(winnerId, loserId)
    local loser = Gangs.Get(loserId)
    if not loser then return 0 end

    local mods = Gangs.Modifiers(winnerId)
    local pct = Config.War.raid.cashCutPct * (1 + mods.raidCutPct / 100)
    local amount = math.floor(math.min(loser.bank * (pct / 100), Config.War.raid.cashCutMax))
    if amount <= 0 then return 0 end

    local affected = MySQL.update.await('UPDATE xs_gangs SET bank = bank - ? WHERE id = ? AND bank >= ?',
        { amount, loserId, amount })
    if not affected or affected < 1 then return 0 end

    loser.bank = loser.bank - amount
    MySQL.update('UPDATE xs_gangs SET bank = bank + ? WHERE id = ?', { amount, winnerId })
    local winner = Gangs.Get(winnerId)
    if winner then winner.bank = winner.bank + amount end

    MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
        { winnerId, '', 'Raid payout', 'raid', amount })
    MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
        { loserId, '', 'Raid loss', 'raid', -amount })
    return amount
end

-- Takes one of the loser's zones at random for the winner. Only reachable
-- with Config.War.raid.captureZoneOnWin switched on — off by default,
-- since turf is staff-assigned and nothing players do moves it. This is
-- the one caller that wants the rep swing, hence awardRep.
local function flipOneZone(winnerId, loserId)
    local held = Territory.HeldBy(loserId)
    if #held == 0 then return nil end
    local pick = held[math.random(#held)]
    Territory.SetHolder(pick.zone, winnerId, 'raid', true)
    return pick.label
end

local function openStashWindow(warId, winnerId, loserId)
    if not Config.War.stash.enabled then return end
    -- No safe placed means nothing to loot — don't open a window that
    -- sends the winner chasing a marker that doesn't exist.
    if not Placeables.FindFor(loserId, 'safe') then
        Gangs.NotifyGang(winnerId, 'They never placed a safe — nothing to loot.', 'inform')
        return
    end

    local expires = now() + (Config.War.war.stashWindowMinutes * 60000)
    MySQL.insert.await(
        'INSERT INTO xs_gang_stash_windows (war_id, winner_id, loser_id, expires_at) VALUES (?, ?, ?, ?)',
        { warId, winnerId, loserId, expires })

    Gangs.NotifyGang(winnerId, ('Their safe is exposed for %d minutes — go get it.'):format(
        Config.War.war.stashWindowMinutes), 'success')
    Gangs.NotifyGang(loserId, 'Your safe is exposed. Defend it.', 'error')
    Gangs.Broadcast(winnerId, 'stash', War.StashFor(winnerId))
    Gangs.Broadcast(loserId, 'stash', {})
end

local function finish(state, winnerId, reason)
    if state.finished then return end
    state.finished = true
    active[state.id] = nil

    local loserId = winnerId and (winnerId == state.attackerId and state.defenderId or state.attackerId) or nil

    if winnerId then
        MySQL.update('UPDATE xs_gang_wars SET state = ?, winner_id = ?, finished_at = ?, score_attack = ?, score_defend = ? WHERE id = ?',
            { 'finished', winnerId, now(), state.scoreAttack or 0, state.scoreDefend or 0, state.id })
    else
        -- A nil in the middle of the parameter list leaves a hole, and a Lua
        -- table with a hole crosses the export boundary as a map instead of an
        -- array, so nothing binds and the row stays 'active'. Both draws and
        -- staff cancels land here.
        MySQL.update('UPDATE xs_gang_wars SET state = ?, winner_id = NULL, finished_at = ?, score_attack = ?, score_defend = ? WHERE id = ?',
            { 'finished', now(), state.scoreAttack or 0, state.scoreDefend or 0, state.id })
    end

    if not winnerId then
        announce(state, 'It ended in a stalemate.', 'inform')
    else
        local winner = Gangs.Get(winnerId)
        local loser = Gangs.Get(loserId)

        if state.kind == 'raid' then
            local cash = payoutRaid(winnerId, loserId)
            local zone = Config.War.raid.captureZoneOnWin and flipOneZone(winnerId, loserId) or nil

            Rep.Add(winnerId, Config.Rep.rewards.raid_won, 'raid won')
            Rep.Add(loserId, Config.Rep.rewards.raid_lost, 'raid lost')

            local detail = cash > 0 and ('$%d'):format(cash) or 'nothing worth taking'
            if zone then detail = detail .. ' and ' .. zone end
            Gangs.NotifyGang(winnerId, ('Raid won — you took %s.'):format(detail), 'success')
            Gangs.NotifyGang(loserId, ('You lost the raid — they took %s.'):format(detail), 'error')
            Gangs.Log(winnerId, ('Won a raid on %s (%s)'):format(loser and loser.label or '?', detail), 'war')
            Gangs.Log(loserId, ('Lost a raid to %s (%s)'):format(winner and winner.label or '?', detail), 'war')
        else
            MySQL.update('UPDATE xs_gangs SET war_wins = war_wins + 1 WHERE id = ?', { winnerId })
            MySQL.update('UPDATE xs_gangs SET war_losses = war_losses + 1 WHERE id = ?', { loserId })
            if winner then winner.war_wins = (winner.war_wins or 0) + 1 end
            if loser then loser.war_losses = (loser.war_losses or 0) + 1 end

            Rep.Add(winnerId, Config.Rep.rewards.war_won, 'war won')
            Rep.Add(loserId, Config.Rep.rewards.war_lost, 'war lost')

            Gangs.NotifyGang(winnerId, 'You won the war.', 'success')
            Gangs.NotifyGang(loserId, 'You lost the war.', 'error')
            Gangs.Log(winnerId, ('Won the war against %s'):format(loser and loser.label or '?'), 'war')
            Gangs.Log(loserId, ('Lost the war against %s'):format(winner and winner.label or '?'), 'war')

            openStashWindow(state.id, winnerId, loserId)
        end

        Discord.Send('war', state.kind == 'raid' and 'Raid finished' or 'War finished',
            ('%s beat %s (%s)'):format(winner and winner.label or '?', loser and loser.label or '?', reason or ''),
            Discord.Color.warn)
    end

    -- Defender gets a breather either way. StartRaid reads this off the
    -- cached gang row, which nothing rebuilds on its own, so writing only to
    -- the database left the immunity unenforced until the next reload.
    local immuneUntil = now() + Config.War.raid.immunityMinutes * 60000
    MySQL.update('UPDATE xs_gangs SET raid_immune = ? WHERE id = ?', { immuneUntil, state.defenderId })
    local defender = Gangs.Get(state.defenderId)
    if defender then defender.raid_immune = immuneUntil end

    bothSides(state, function(gangId) Gangs.Broadcast(gangId, 'war', nil) end)
    if TestMode then TestMode.StopWar(state.id) end
end

-- ── raid ────────────────────────────────────────────────────
function War.StartRaid(src, defenderGangId)
    if not Config.War.enabled then return false, 'war is disabled' end
    if not Gangs.HasPerm(src, 'start_raid') then return false, 'no permission' end

    local attacker = Gangs.GetBySource(src)
    if not attacker then return false, 'no gang' end
    defenderGangId = tonumber(defenderGangId)
    local defender = Gangs.Get(defenderGangId)
    if not defender then return false, 'unknown gang' end
    if defender.id == attacker.id then return false, 'you cannot raid yourselves' end

    if War.ActiveFor(attacker.id) then return false, 'you are already in something' end
    if War.ActiveFor(defender.id) then return false, 'they are already under attack' end

    if (attacker.raid_cooldown or 0) > now() then
        return false, ('your crew can raid again in %d min'):format(math.ceil((attacker.raid_cooldown - now()) / 60000))
    end
    if (defender.raid_immune or 0) > now() then
        return false, ('they are still recovering — %d min'):format(math.ceil((defender.raid_immune - now()) / 60000))
    end

    local hq = Placeables.CoordsFor(defender.id, 'hq')
    if not hq then return false, 'they have no HQ to hit' end

    local attackersOnline = onlineCount(attacker.id)
    if attackersOnline < Config.War.raid.minAttackers then
        return false, ('you need %d of your crew online'):format(Config.War.raid.minAttackers)
    end
    if onlineCount(defender.id) < Config.War.raid.minDefendersOnline then
        return false, 'nobody from that crew is around — not a raid, just a mugging'
    end

    if attacker.bank < Config.War.raid.cost then
        return false, ('staging a raid costs $%d'):format(Config.War.raid.cost)
    end

    if not claimPair(attacker.id, defender.id) then return false, 'that is already being staged' end

    local affected = MySQL.update.await('UPDATE xs_gangs SET bank = bank - ? WHERE id = ? AND bank >= ?',
        { Config.War.raid.cost, attacker.id, Config.War.raid.cost })
    if not affected or affected < 1 then
        releasePair(attacker.id, defender.id)
        return false, 'not enough in the treasury'
    end
    attacker.bank = attacker.bank - Config.War.raid.cost

    local startsAt = now() + Config.War.raid.prepSeconds * 1000
    local endsAt = startsAt + Config.War.raid.durationSeconds * 1000

    local warId = MySQL.insert.await(
        'INSERT INTO xs_gang_wars (kind, attacker_id, defender_id, state, started_at, ends_at) VALUES (?, ?, ?, ?, ?, ?)',
        { 'raid', attacker.id, defender.id, 'prep', startsAt, endsAt })

    MySQL.update('UPDATE xs_gangs SET raid_cooldown = ? WHERE id = ?',
        { now() + Config.War.raid.cooldownMinutes * 60000, attacker.id })
    attacker.raid_cooldown = now() + Config.War.raid.cooldownMinutes * 60000

    active[warId] = {
        id = warId, kind = 'raid', phase = 'prep',
        attackerId = attacker.id, defenderId = defender.id,
        startsAt = startsAt, endsAt = endsAt,
        targetCoords = hq, holdProgress = 0,
        scoreAttack = 0, scoreDefend = 0,
        -- Staff can arm a gang so its next raid comes with NPC defenders,
        -- which is what makes the whole loop testable solo.
        autoTest = TestMode and TestMode.IsArmed(defender.id) or false,
    }
    releasePair(attacker.id, defender.id)

    Gangs.NotifyGang(defender.id, ('%s is mobilising on your HQ. You have %d seconds.'):format(
        attacker.label, Config.War.raid.prepSeconds), 'error')
    Gangs.NotifyGang(attacker.id, ('Raid staged on %s. Move out.'):format(defender.label), 'inform')
    Gangs.Log(attacker.id, ('Raid launched on %s'):format(defender.label), 'war')
    Gangs.Log(defender.id, ('%s launched a raid on us'):format(attacker.label), 'war')
    Discord.Send('war', 'Raid launched', ('%s → %s'):format(attacker.label, defender.label), Discord.Color.bad)

    pushState(active[warId])
    return true
end

-- ── war ─────────────────────────────────────────────────────
function War.Declare(src, defenderGangId)
    if not Config.War.enabled then return false, 'war is disabled' end
    if not Gangs.HasPerm(src, 'declare_war') then return false, 'no permission' end

    local attacker = Gangs.GetBySource(src)
    if not attacker then return false, 'no gang' end
    defenderGangId = tonumber(defenderGangId)
    local defender = Gangs.Get(defenderGangId)
    if not defender then return false, 'unknown gang' end
    if defender.id == attacker.id then return false, 'you cannot war yourselves' end

    if War.ActiveFor(attacker.id) then return false, 'you are already in something' end
    if War.ActiveFor(defender.id) then return false, 'they are already at war' end

    -- Config.War.war.cooldownMinutes existed but nothing ever read it, so a
    -- rich crew could re-declare the moment a war ended and keep one rival
    -- permanently at war.
    if (attacker.war_cooldown or 0) > now() then
        return false, ('your crew can declare again in %d min'):format(
            math.ceil((attacker.war_cooldown - now()) / 60000))
    end

    if attacker.bank < Config.War.war.declareCost then
        return false, ('declaring war costs $%d'):format(Config.War.war.declareCost)
    end

    if not claimPair(attacker.id, defender.id) then return false, 'that is already being declared' end

    local affected = MySQL.update.await('UPDATE xs_gangs SET bank = bank - ? WHERE id = ? AND bank >= ?',
        { Config.War.war.declareCost, attacker.id, Config.War.war.declareCost })
    if not affected or affected < 1 then
        releasePair(attacker.id, defender.id)
        return false, 'not enough in the treasury'
    end
    attacker.bank = attacker.bank - Config.War.war.declareCost

    local startsAt = now()
    local endsAt = startsAt + Config.War.war.durationMinutes * 60000

    local warId = MySQL.insert.await(
        'INSERT INTO xs_gang_wars (kind, attacker_id, defender_id, state, started_at, ends_at) VALUES (?, ?, ?, ?, ?, ?)',
        { 'war', attacker.id, defender.id, 'active', startsAt, endsAt })

    active[warId] = {
        id = warId, kind = 'war', phase = 'active',
        attackerId = attacker.id, defenderId = defender.id,
        startsAt = startsAt, endsAt = endsAt,
        scoreAttack = 0, scoreDefend = 0,
    }
    releasePair(attacker.id, defender.id)

    local cooldownUntil = now() + (Config.War.war.cooldownMinutes or 0) * 60000
    MySQL.update('UPDATE xs_gangs SET war_cooldown = ? WHERE id = ?', { cooldownUntil, attacker.id })
    attacker.war_cooldown = cooldownUntil

    announce(active[warId], ('War: %s vs %s. %d minutes.'):format(
        attacker.label, defender.label, Config.War.war.durationMinutes), 'error')
    Gangs.Log(attacker.id, ('Declared war on %s'):format(defender.label), 'war')
    Gangs.Log(defender.id, ('%s declared war on us'):format(attacker.label), 'war')
    Discord.Send('war', 'War declared', ('%s vs %s'):format(attacker.label, defender.label), Discord.Color.bad)

    pushState(active[warId])
    return true
end

-- Kills between the two sides feed the meter. The victim self-reports
-- (same pattern as the friendly-fire penalty) and the server only counts
-- it if both players really are on opposite sides of a live war.
RegisterNetEvent('XS-CriminalTablet:server:reportWarKill', function(killerServerId)
    local victimSrc = source
    killerServerId = tonumber(killerServerId)
    if not killerServerId or killerServerId == victimSrc then return end

    local victimCid = Framework.GetCitizenId(victimSrc)
    local killerCid = Framework.GetCitizenId(killerServerId)
    if not victimCid or not killerCid then return end

    local victimGang = Gangs.GetByCitizen(victimCid)
    local killerGang = Gangs.GetByCitizen(killerCid)
    if not victimGang or not killerGang or victimGang.id == killerGang.id then return end

    local state = War.ActiveFor(killerGang.id)
    if not state or state.kind ~= 'war' or state.phase ~= 'active' then return end
    if state.attackerId ~= victimGang.id and state.defenderId ~= victimGang.id then return end

    -- Farming the same person over and over doesn't pay.
    local pairKey = killerCid .. ':' .. victimCid
    if (recentKills[pairKey] or 0) + (Config.War.war.repeatKillCooldownSeconds * 1000) > now() then return end
    recentKills[pairKey] = now()

    if killerGang.id == state.attackerId then
        state.scoreAttack = (state.scoreAttack or 0) + Config.War.war.killScore
    else
        state.scoreDefend = (state.scoreDefend or 0) + Config.War.war.killScore
    end

    pushState(state)

    local lead = (state.scoreAttack or 0) - (state.scoreDefend or 0)
    if math.abs(lead) >= Config.War.war.scoreToWin then
        finish(state, lead > 0 and state.attackerId or state.defenderId, 'score')
    end
end)

-- ── tick ────────────────────────────────────────────────────
local function raidTick(state)
    if state.phase == 'prep' then
        if now() >= state.startsAt then
            state.phase = 'active'
            MySQL.update('UPDATE xs_gang_wars SET state = ? WHERE id = ?', { 'active', state.id })
            announce(state, 'The raid is live.', 'error')
            if TestMode then TestMode.StartWar(state) end
            pushState(state)
        end
        return
    end

    if now() >= state.endsAt then
        finish(state, state.defenderId, 'timeout')
        return
    end

    -- Count bodies at the HQ.
    local attackers, defenders = 0, 0
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 and GetEntityHealth(ped) > 0 then
            if #(GetEntityCoords(ped) - state.targetCoords) <= Config.War.raid.radius then
                local gang = Gangs.GetBySource(src)
                if gang then
                    if gang.id == state.attackerId then attackers = attackers + 1
                    elseif gang.id == state.defenderId then defenders = defenders + 1 end
                end
            end
        end
    end

    if TestMode and Config.TestMode.countAsDefenders then
        defenders = defenders + TestMode.WarDefenderCount(state.id)
    end

    state.scoreAttack = attackers
    state.scoreDefend = defenders

    if attackers >= Config.War.raid.minAttackers and defenders == 0 then
        state.holdProgress = (state.holdProgress or 0) + 1
        if state.holdProgress >= Config.War.raid.holdSeconds then
            finish(state, state.attackerId, 'hold')
            return
        end
    elseif defenders > 0 then
        -- Contested ground bleeds the hold back down rather than resetting
        -- it outright — defenders have to actually push, not just touch it.
        state.holdProgress = math.max(0, (state.holdProgress or 0) - 2)
    end

    pushState(state)
end

local function warTick(state)
    if now() >= state.endsAt then
        local lead = (state.scoreAttack or 0) - (state.scoreDefend or 0)
        if lead == 0 then finish(state, nil, 'draw')
        else finish(state, lead > 0 and state.attackerId or state.defenderId, 'time') end
    end
end

CreateThread(function()
    Wait(6000)
    while true do
        Wait(1000)
        for _, state in pairs(active) do
            local ok, err = pcall(state.kind == 'raid' and raidTick or warTick, state)
            if not ok and Config.Debug then
                print(('^1[XS-CriminalTablet]^0 war tick error: %s'):format(err))
            end
        end
    end
end)

-- Anything left 'prep'/'active' in the DB across a restart is dead — the
-- in-memory state it depended on is gone.
CreateThread(function()
    Wait(3000)
    MySQL.update("UPDATE xs_gang_wars SET state = 'finished', finished_at = ? WHERE state IN ('prep','active')", { now() })
end)

-- ── stash raid ──────────────────────────────────────────────
function War.StashFor(gangId)
    local row = MySQL.single.await(
        'SELECT * FROM xs_gang_stash_windows WHERE winner_id = ? AND looted_at = 0 AND expires_at > ? ORDER BY id DESC LIMIT 1',
        { gangId, now() })
    if not row then return nil end

    local safe = Placeables.CoordsFor(row.loser_id, 'safe')
    if not safe then return nil end
    local loser = Gangs.Get(row.loser_id)

    return {
        id = row.id,
        loserId = row.loser_id,
        loserLabel = loser and loser.label or '?',
        expiresAt = row.expires_at,
        coords = { x = safe.x, y = safe.y, z = safe.z },
        lootRadius = Config.War.stash.lootRadius,
        lootSeconds = Config.War.stash.lootSeconds,
    }
end

function War.LootStash(src)
    if not Config.War.stash.enabled then return false, 'disabled' end
    if not Gangs.HasPerm(src, 'stash_raid') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local window = War.StashFor(gang.id)
    if not window then return false, 'no stash is open to you' end

    local pos = GetEntityCoords(GetPlayerPed(src))
    if #(pos - vec3(window.coords.x, window.coords.y, window.coords.z)) > Config.War.stash.lootRadius + 1.5 then
        return false, 'you are not at their safe'
    end

    -- Claim the window first: two members racing must not double-loot.
    local claimed = MySQL.update.await(
        'UPDATE xs_gang_stash_windows SET looted_at = ? WHERE id = ? AND looted_at = 0',
        { now(), window.id })
    if not claimed or claimed < 1 then return false, 'someone already cracked it' end

    local loser = Gangs.Get(window.loserId)
    local cash = 0
    if loser then
        cash = math.floor(math.min(loser.bank * (Config.War.stash.cashPct / 100), Config.War.stash.cashMax))
        if cash > 0 then
            local affected = MySQL.update.await('UPDATE xs_gangs SET bank = bank - ? WHERE id = ? AND bank >= ?',
                { cash, loser.id, cash })
            if affected and affected > 0 then
                loser.bank = loser.bank - cash
                MySQL.update('UPDATE xs_gangs SET bank = bank + ? WHERE id = ?', { cash, gang.id })
                gang.bank = gang.bank + cash
                MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
                    { gang.id, '', 'Stash raid', 'stash', cash })
                MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
                    { loser.id, '', 'Safe cracked', 'stash', -cash })
            else
                cash = 0
            end
        end
    end

    local taken = {}
    if Config.War.stash.lootItems then
        local pulled = Vault.LootStacks(window.loserId, Config.War.stash.maxItemStacks)
        -- LootStacks has already removed these from the loser's vault, so a
        -- stack the looter has no room for would simply cease to exist. Put
        -- anything that will not fit back where it came from, and only report
        -- what actually landed.
        for _, item in ipairs(pulled) do
            local ok = exports.ox_inventory:AddItem(src, item.name, item.count, item.metadata)
            if ok then
                taken[#taken + 1] = item
            else
                Vault.ReturnStack(window.loserId, item)
            end
        end
        if #taken < #pulled then
            Framework.Notify(src, ('You could not carry %d stack(s) -- they were left behind.')
                :format(#pulled - #taken), 'error')
        end
    end

    local detail = ('$%d and %d item stack%s'):format(cash, #taken, #taken == 1 and '' or 's')
    Gangs.Log(gang.id, ('%s cracked %s\'s safe — %s'):format(
        Framework.GetName(src) or 'Someone', window.loserLabel, detail), 'war')
    Gangs.Log(window.loserId, ('%s cracked our safe — lost %s'):format(gang.label, detail), 'war')
    Gangs.NotifyGang(window.loserId, ('%s cracked your safe.'):format(gang.label), 'error')
    Discord.Send('war', 'Stash raided', ('%s took %s from %s'):format(gang.label, detail, window.loserLabel), Discord.Color.bad)

    Gangs.Broadcast(gang.id, 'stash', nil)
    Gangs.Broadcast(window.loserId, 'treasury', {})
    return true, { cash = cash, items = taken }
end

-- ── UI reads ────────────────────────────────────────────────
function War.Overview(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return {} end

    -- Every other gang, with just enough intel to pick a target.
    local rivals = {}
    for _, row in ipairs(MySQL.query.await(
        'SELECT id, label, color, notoriety, bank, war_wins, war_losses, raid_immune FROM xs_gangs WHERE id != ?',
        { gang.id }) or {}) do
        local hq = Placeables.CoordsFor(row.id, 'hq')
        rivals[#rivals + 1] = {
            id = row.id,
            label = row.label,
            color = row.color,
            tier = Rep.Tier(row.notoriety),
            rep = row.notoriety,
            zones = Territory.CountHeldBy(row.id),
            online = onlineCount(row.id),
            members = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_members WHERE gang_id = ?', { row.id }) or 0,
            warWins = row.war_wins or 0,
            warLosses = row.war_losses or 0,
            hasHq = hq ~= nil,
            immune = (row.raid_immune or 0) > now(),
        }
    end
    table.sort(rivals, function(a, b) return a.rep > b.rep end)

    local history = MySQL.query.await(
        'SELECT w.id, w.kind, w.attacker_id, w.defender_id, w.winner_id, w.finished_at, ' ..
        'a.label AS attacker_label, d.label AS defender_label ' ..
        'FROM xs_gang_wars w ' ..
        'LEFT JOIN xs_gangs a ON a.id = w.attacker_id LEFT JOIN xs_gangs d ON d.id = w.defender_id ' ..
        "WHERE w.state = 'finished' AND (w.attacker_id = ? OR w.defender_id = ?) ORDER BY w.id DESC LIMIT 10",
        { gang.id, gang.id }) or {}

    return {
        rivals = rivals,
        history = history,
        active = War.PublicState(War.ActiveFor(gang.id)),
        stash = War.StashFor(gang.id),
        warWins = gang.war_wins or 0,
        warLosses = gang.war_losses or 0,
        bank = gang.bank,
        raidCost = Config.War.raid.cost,
        warCost = Config.War.war.declareCost,
        raidCooldown = gang.raid_cooldown or 0,
        raidImmune = gang.raid_immune or 0,
        hasHq = Placeables.FindFor(gang.id, 'hq') ~= nil,
        hasSafe = Placeables.FindFor(gang.id, 'safe') ~= nil,
        canRaid = Gangs.HasPerm(src, 'start_raid'),
        canDeclare = Gangs.HasPerm(src, 'declare_war'),
        canLoot = Gangs.HasPerm(src, 'stash_raid'),
        now = now(),
    }
end

-- ── admin ───────────────────────────────────────────────────
function War.AdminList()
    local out = {}
    for _, state in pairs(active) do out[#out + 1] = War.PublicState(state) end
    return out
end

function War.AdminStop(warId)
    local state = active[tonumber(warId)]
    if not state then return false, 'not running' end
    finish(state, nil, 'cancelled by staff')
    return true
end

-- ── callbacks ───────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:war:getOverview', function(src)
    return War.Overview(src)
end)

lib.callback.register('XS-CriminalTablet:war:startRaid', function(src, gangId)
    local ok, err = War.StartRaid(src, gangId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:war:declare', function(src, gangId)
    local ok, err = War.Declare(src, gangId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:war:lootStash', function(src)
    local ok, res = War.LootStash(src)
    return { ok = ok, error = not ok and res or nil, loot = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:war:getState', function(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return nil end
    return { war = War.PublicState(War.ActiveFor(gang.id)), stash = War.StashFor(gang.id) }
end)
