-- ─────────────────────────────────────────────────────────────
-- Treasury upgrades: permanent gang-wide bonuses bought with the gang's
-- MONEY rather than perk points. Each upgrade is a ladder — level 2 costs
-- more than level 1 and you buy them in order.
--
-- Deliberately a second currency: perk points come from levelling (time
-- and activity), upgrades come from actually banking cash. A gang that
-- only grinds rep and a gang that only earns money end up in different
-- places.
-- ─────────────────────────────────────────────────────────────
Upgrades = {}

local EFFECT_KEYS = {
    'maxMembersBonus', 'vaultSlotsBonus', 'vaultWeightBonusPct',
    'garageSlotsBonus', 'raidRewardPct', 'captureSpeedPct',
}

local function defOf(id)
    for _, u in ipairs(Config.Upgrades) do
        if u.id == id then return u end
    end
    return nil
end

local function levelsOwned(gangId)
    local rows = MySQL.query.await('SELECT upgrade_id, level FROM xs_gang_upgrades WHERE gang_id = ?', { gangId }) or {}
    local owned = {}
    for _, r in ipairs(rows) do owned[r.upgrade_id] = r.level or 0 end
    return owned
end

-- Sum every bought level's effects into one flat table. Callers never
-- need to know which upgrade contributed what.
function Upgrades.ModifiersFor(gangId)
    local mods = {}
    for _, k in ipairs(EFFECT_KEYS) do mods[k] = 0 end
    if not gangId then return mods end

    local owned = levelsOwned(gangId)
    for _, u in ipairs(Config.Upgrades) do
        local lvl = owned[u.id] or 0
        for i = 1, math.min(lvl, #u.levels) do
            local step = u.levels[i]
            for _, k in ipairs(EFFECT_KEYS) do
                if step[k] then mods[k] = mods[k] + step[k] end
            end
        end
    end
    return mods, owned
end

-- What the UI renders: every track, where the gang is on it, what the
-- next step costs and whether the treasury can cover it.
function Upgrades.GetTracks(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return { tracks = {}, bank = 0 } end
    local _, owned = Upgrades.ModifiersFor(gang.id)

    local tracks = {}
    for _, u in ipairs(Config.Upgrades) do
        local lvl = owned[u.id] or 0
        local nextStep = u.levels[lvl + 1]

        local steps = {}
        for i, s in ipairs(u.levels) do
            local effects = {}
            for _, k in ipairs(EFFECT_KEYS) do
                if s[k] then effects[#effects + 1] = { key = k, value = s[k] } end
            end
            steps[#steps + 1] = { level = i, cost = Prices.UpgradeCost(u.id, i), owned = i <= lvl, effects = effects }
        end

        tracks[#tracks + 1] = {
            id = u.id, label = u.label, icon = u.icon, description = u.description,
            level = lvl, maxLevel = #u.levels,
            nextCost = nextStep and Prices.UpgradeCost(u.id, lvl + 1) or nil,
            affordable = nextStep and gang.bank >= Prices.UpgradeCost(u.id, lvl + 1) or false,
            steps = steps,
        }
    end

    return { tracks = tracks, bank = gang.bank, canBuy = Gangs.HasPerm(src, 'manage_upgrades') }
end

function Upgrades.Buy(src, upgradeId)
    if not Gangs.HasPerm(src, 'manage_upgrades') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local def = defOf(upgradeId)
    if not def then return false, 'unknown upgrade' end

    local _, owned = Upgrades.ModifiersFor(gang.id)
    local lvl = owned[upgradeId] or 0
    local step = def.levels[lvl + 1]
    if not step then return false, 'already fully upgraded' end

    -- Staff-set price wins over the config default.
    local cost = Prices.UpgradeCost(upgradeId, lvl + 1)
    if gang.bank < cost then return false, 'not enough in the treasury' end

    -- Spend first, then record — a failed write must never leave the gang
    -- paid-up with no upgrade, and the reverse is worse.
    local affected = MySQL.update.await('UPDATE xs_gangs SET bank = bank - ? WHERE id = ? AND bank >= ?',
        { cost, gang.id, cost })
    if not affected or affected < 1 then return false, 'not enough in the treasury' end
    gang.bank = gang.bank - cost

    MySQL.query.await(
        'INSERT INTO xs_gang_upgrades (gang_id, upgrade_id, level) VALUES (?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE level = ?',
        { gang.id, upgradeId, lvl + 1, lvl + 1 })

    MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
        { gang.id, Framework.GetCitizenId(src) or '', Framework.GetName(src) or 'Someone', 'upgrade', cost })

    Gangs.Log(gang.id, ('%s bought %s %d for $%d'):format(
        Framework.GetName(src) or 'Someone', def.label, lvl + 1, cost), 'economy')
    Discord.Send('economy', 'Upgrade bought',
        ('%s — %s level %d ($%d)'):format(gang.label, def.label, lvl + 1, cost), Discord.Color.info)

    Gangs.InvalidateModifiers(gang.id)
    -- The vault's registered size depends on these, so re-register it.
    if Vault and Vault.Refresh then Vault.Refresh(gang.id) end
    -- ...and a bigger vault is a bigger prop.
    if upgradeId == 'vault' and Placeables and Placeables.RefreshVaultModel then
        Placeables.RefreshVaultModel(gang.id, lvl + 1)
    end
    Gangs.Broadcast(gang.id, 'upgrades', {})
    return true
end

lib.callback.register('XS-CriminalTablet:upgrades:getTracks', function(src)
    return Upgrades.GetTracks(src)
end)

lib.callback.register('XS-CriminalTablet:upgrades:buy', function(src, upgradeId)
    local ok, err = Upgrades.Buy(src, upgradeId)
    return { ok = ok, error = err }
end)
