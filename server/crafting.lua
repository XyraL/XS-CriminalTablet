-- ─────────────────────────────────────────────────────────────
-- Crafting: simple item conversions available at any placed bench. Open
-- to any gang member (not permission-gated) — the bench itself is the
-- gate for being there at all, and a recipe's `tier` requirement (if any)
-- gates which recipes that bench can actually make right now. Server is
-- the sole authority on both the tier check and whether the player
-- actually has the inputs.
-- ─────────────────────────────────────────────────────────────
Crafting = {}

local byId = {}
for _, r in ipairs(Config.Recipes) do byId[r.id] = r end

local function tierIndex(tierName)
    for i, t in ipairs(Config.Notoriety.tiers) do
        if t.name == tierName then return i end
    end
    return 1
end

local function hasItems(src, inputs)
    for _, inp in ipairs(inputs) do
        local count = exports.ox_inventory:Search(src, 'count', inp.item)
        if (count or 0) < inp.count then return false, inp end
    end
    return true
end

-- Every recipe, with a `locked` flag for ones the gang's tier doesn't
-- reach yet — same pattern as the Unlocks tab's placeables list. The
-- Master Workshop perk (tierBoost) makes the bench treat the gang as one
-- tier higher than it really is, purely for which recipes unlock here.
function Crafting.GetRecipes(src)
    local cid = Framework.GetCitizenId(src)
    local gang = cid and Gangs.GetByCitizen(cid)
    local mods = gang and GangPerks.ModifiersFor(gang.id) or { craftTimePct = 0 }
    local myTierIdx = gang and (tierIndex(Notoriety.Tier(gang.notoriety)) + mods.tierBoost) or 0
    local timeMult = 1 + (mods.craftTimePct or 0) / 100

    local list = {}
    for _, r in ipairs(Config.Recipes) do
        local reqTier = r.tier or Config.Notoriety.tiers[1].name
        local reqIdx = tierIndex(reqTier)
        list[#list + 1] = {
            id = r.id, label = r.label, inputs = r.inputs, output = r.output,
            time = math.max(500, math.floor((r.time or 0) * timeMult)),
            locked = reqIdx > myTierIdx, tierName = reqTier,
        }
    end
    return list
end

function Crafting.Craft(src, recipeId)
    local recipe = byId[recipeId]
    if not recipe then return false, 'unknown recipe' end

    local cid = Framework.GetCitizenId(src)
    local gang = cid and Gangs.GetByCitizen(cid)
    if not gang then return false, 'no gang' end

    local mods = GangPerks.ModifiersFor(gang.id)
    local reqTier = recipe.tier or Config.Notoriety.tiers[1].name
    if (tierIndex(Notoriety.Tier(gang.notoriety)) + mods.tierBoost) < tierIndex(reqTier) then
        return false, ('requires %s tier'):format(reqTier)
    end

    local ok, missing = hasItems(src, recipe.inputs)
    if not ok then return false, ('missing %s'):format(missing.item) end

    for _, inp in ipairs(recipe.inputs) do
        exports.ox_inventory:RemoveItem(src, inp.item, inp.count)
    end

    local outputCount = recipe.output.count
    local bonus = math.random() * 100 < mods.bonusOutputChance
    if bonus then outputCount = outputCount * 2 end

    exports.ox_inventory:AddItem(src, recipe.output.item, outputCount)
    Gangs.Log(gang.id, ('%s crafted %dx %s%s'):format(
        Framework.GetName(src) or cid, outputCount, recipe.output.item, bonus and ' (bonus output!)' or ''))
    return true, bonus
end

lib.callback.register('XS-CriminalTablet:crafting:getRecipes', function(src)
    return Crafting.GetRecipes(src)
end)

lib.callback.register('XS-CriminalTablet:crafting:craft', function(src, recipeId)
    local ok, errOrBonus = Crafting.Craft(src, recipeId)
    return { ok = ok, error = not ok and errOrBonus or nil, bonus = ok and errOrBonus or nil }
end)
