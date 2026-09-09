-- ─────────────────────────────────────────────────────────────
-- Gang perk tree: three branches (vault/members/bench), each a chain of
-- tiers. Tier N in a branch requires tier N-1 in that SAME branch already
-- owned — that's what makes it a tree instead of a flat shopping list.
-- Effects stack additively across every owned tier.
-- ─────────────────────────────────────────────────────────────
GangPerks = {}

local function ownedPerkIds(gangId)
    local rows = MySQL.query.await('SELECT perk_id FROM xs_gang_perks WHERE gang_id = ?', { gangId }) or {}
    local owned = {}
    for _, r in ipairs(rows) do owned[r.perk_id] = true end
    return owned
end

-- Aggregates every owned tier into one set of numbers the rest of the
-- codebase can just apply — nothing else needs to know the tree shape.
function GangPerks.ModifiersFor(gangId)
    local owned = ownedPerkIds(gangId)
    local mods = {
        vaultSlotsBonus = 0, vaultWeightBonusPct = 0, maxMembersBonus = 0,
        craftTimePct = 0, bonusOutputChance = 0, tierBoost = 0,
    }
    for _, branch in pairs(Config.GangPerks) do
        for _, t in ipairs(branch.tiers) do
            if owned[t.id] then
                mods.vaultSlotsBonus = mods.vaultSlotsBonus + (t.slotsBonus or 0)
                mods.vaultWeightBonusPct = mods.vaultWeightBonusPct + (t.weightBonusPct or 0)
                mods.maxMembersBonus = mods.maxMembersBonus + (t.maxMembersBonus or 0)
                mods.craftTimePct = mods.craftTimePct + (t.craftTimePct or 0)
                mods.bonusOutputChance = mods.bonusOutputChance + (t.bonusOutputChance or 0)
                mods.tierBoost = mods.tierBoost + (t.tierBoost or 0)
            end
        end
    end
    mods.craftTimePct = math.max(-80, mods.craftTimePct) -- never less than 20% of base time
    mods.bonusOutputChance = math.min(100, mods.bonusOutputChance)
    return mods, owned
end

-- Tree view for the UI: every branch, every tier, with owned/locked/
-- affordable state. A tier is locked if the previous tier in its branch
-- isn't owned yet (tier 1 is never locked).
function GangPerks.GetTree(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return {}, 0 end
    local _, owned = GangPerks.ModifiersFor(gang.id)
    local points = gang.perk_points or 0

    local branches = {}
    for branchId, branch in pairs(Config.GangPerks) do
        local tiers = {}
        local prevOwned = true
        for i, t in ipairs(branch.tiers) do
            tiers[#tiers + 1] = {
                id = t.id, label = t.label, description = t.description, cost = t.cost,
                tier = i, owned = owned[t.id] == true,
                locked = not prevOwned and not owned[t.id],
                affordable = points >= t.cost,
            }
            prevOwned = owned[t.id] == true
        end
        branches[#branches + 1] = { id = branchId, label = branch.label, icon = branch.icon, tiers = tiers }
    end
    table.sort(branches, function(a, b) return a.id < b.id end)
    return branches, points
end

function GangPerks.BuyPerk(src, perkId)
    if not Gangs.HasPerm(src, 'manage_perks') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local def, branchTiers, tierIdx
    for _, branch in pairs(Config.GangPerks) do
        for i, t in ipairs(branch.tiers) do
            if t.id == perkId then def = t; branchTiers = branch.tiers; tierIdx = i; break end
        end
        if def then break end
    end
    if not def then return false, 'unknown perk' end

    local _, owned = GangPerks.ModifiersFor(gang.id)
    if owned[perkId] then return false, 'already owned' end
    if tierIdx > 1 and not owned[branchTiers[tierIdx - 1].id] then
        return false, 'buy the previous tier in this branch first'
    end
    if (gang.perk_points or 0) < def.cost then return false, 'not enough perk points' end

    local ok = pcall(function()
        MySQL.insert.await('INSERT INTO xs_gang_perks (gang_id, perk_id) VALUES (?, ?)', { gang.id, perkId })
    end)
    if not ok then return false, 'already owned' end

    gang.perk_points = gang.perk_points - def.cost
    MySQL.update('UPDATE xs_gangs SET perk_points = perk_points - ? WHERE id = ?', { def.cost, gang.id })
    Gangs.Log(gang.id, ('%s bought the "%s" perk'):format(Framework.GetName(src) or 'Someone', def.label))
    return true
end

lib.callback.register('XS-CriminalTablet:gangperks:getTree', function(src)
    local branches, points = GangPerks.GetTree(src)
    return { branches = branches, perkPoints = points }
end)

lib.callback.register('XS-CriminalTablet:gangperks:buyPerk', function(src, perkId)
    local ok, err = GangPerks.BuyPerk(src, perkId)
    return { ok = ok, error = err }
end)
