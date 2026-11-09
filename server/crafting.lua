-- ─────────────────────────────────────────────────────────────
-- Crafting: item conversions at a placed bench. Open to any gang member
-- standing at one of their crew's benches, and a recipe's `tier` gates
-- which recipes that bench can make right now. The server owns the tier
-- check, the items, and how long a build takes.
-- ─────────────────────────────────────────────────────────────
Crafting = {}

local byId = {}
local working = {}   -- [src] = { id, qty, doneAt }
local MAX_BATCH = 10
local BENCH_RANGE = 6.0

-- Rebuilt when staff save recipes in the builder.
function Crafting.Index()
    byId = {}
    for _, r in ipairs(Config.Recipes) do byId[r.id] = r end
end
Crafting.Index()

local function tierIndex(tierName)
    for i, t in ipairs(Config.Rep.tiers) do
        if t.name == tierName then return i end
    end
    return 1
end

local function countOf(src, item)
    local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
    return ok and tonumber(n) or 0
end

local imagePath
local function itemInfo(name)
    if GetResourceState('ox_inventory') == 'started' then
        local ok, it = pcall(function() return exports.ox_inventory:Items(name) end)
        if ok and type(it) == 'table' then
            local custom = it.client and it.client.image
            if type(custom) == 'string' and custom:find('://', 1, true) then return it.label or name, custom end
            imagePath = imagePath or GetConvar('inventory:imagepath', 'nui://ox_inventory/web/images')
            return it.label or name, ('%s/%s.png'):format(imagePath, it.name or name)
        end
    elseif Framework.core and Framework.core.Shared and Framework.core.Shared.Items then
        local it = Framework.core.Shared.Items[name]
        if it then return it.label or name, it.image and ('nui://qb-inventory/html/images/' .. it.image) or nil end
    end
    return name, nil
end

local function crewOf(src)
    local cid = Framework.GetCitizenId(src)
    return cid and Gangs.GetByCitizen(cid) or nil
end

local function atBench(src, gangId)
    local pos = GetEntityCoords(GetPlayerPed(src))
    for _, p in ipairs(Placeables.GetAll()) do
        if p.gang_id == gangId and p.kind == 'bench' and #(pos - vec3(p.x, p.y, p.z)) <= BENCH_RANGE then return true end
    end
    return false
end

local function canMake(src, gang, recipe)
    local mods = GangPerks.ModifiersFor(gang.id)
    local reqTier = recipe.tier or Config.Rep.tiers[1].name
    if (tierIndex(Rep.Tier(gang.notoriety)) + mods.tierBoost) < tierIndex(reqTier) then
        return false, ('needs %s tier'):format(reqTier)
    end
    return true, nil, mods
end

local function shortOf(src, inputs, qty)
    for _, inp in ipairs(inputs) do
        if countOf(src, inp.item) < inp.count * qty then return inp end
    end
    return nil
end

-- Every recipe with what it needs, what you are carrying and how many you
-- could make right now. Locked ones come too, so the crew can see what the
-- next tier brings. The Master Workshop perk (tierBoost) makes the bench
-- treat the crew as one tier higher, purely for which recipes unlock.
function Crafting.GetRecipes(src)
    local gang = crewOf(src)
    local mods = gang and GangPerks.ModifiersFor(gang.id) or { craftTimePct = 0, bonusOutputChance = 0, tierBoost = 0 }
    local myTierIdx = gang and (tierIndex(Rep.Tier(gang.notoriety)) + mods.tierBoost) or 0
    local timeMult = 1 + (mods.craftTimePct or 0) / 100

    local have = {}
    local function held(item)
        if have[item] == nil then have[item] = countOf(src, item) end
        return have[item]
    end

    local list = {}
    for _, r in ipairs(Config.Recipes) do
        local reqTier = r.tier or Config.Rep.tiers[1].name
        local inputs, max = {}, MAX_BATCH
        for _, inp in ipairs(r.inputs or {}) do
            local label, image = itemInfo(inp.item)
            local n = held(inp.item)
            inputs[#inputs + 1] = { item = inp.item, label = label, image = image, count = inp.count, have = n }
            max = math.min(max, math.floor(n / math.max(1, inp.count)))
        end
        local outLabel, outImage = itemInfo(r.output.item)
        list[#list + 1] = {
            id = r.id, label = r.label, tierName = reqTier,
            locked = tierIndex(reqTier) > myTierIdx,
            time = math.max(500, math.floor((r.time or 0) * timeMult)),
            inputs = inputs,
            output = { item = r.output.item, label = outLabel, image = outImage, count = r.output.count },
            max = max,
        }
    end

    return {
        recipes = list,
        maxBatch = MAX_BATCH,
        perks = { timePct = mods.craftTimePct or 0, bonusChance = mods.bonusOutputChance or 0, tierBoost = mods.tierBoost or 0 },
        crew = gang and gang.label or nil,
        color = gang and gang.color or nil,
        logo = gang and gang.logo or nil,
    }
end

-- Starting a build. Items are checked now and again when it finishes; the
-- clock runs here, so a build cannot finish faster than it should.
function Crafting.Begin(src, recipeId, qty)
    local recipe = byId[recipeId]
    if not recipe then return false, 'unknown recipe' end
    local gang = crewOf(src)
    if not gang then return false, 'no gang' end
    if not atBench(src, gang.id) then return false, 'stand at your crew\'s bench' end
    qty = math.floor(tonumber(qty) or 1)
    if qty < 1 or qty > MAX_BATCH then return false, ('make 1 to %d at a time'):format(MAX_BATCH) end

    local ok, err, mods = canMake(src, gang, recipe)
    if not ok then return false, err end
    local short = shortOf(src, recipe.inputs, qty)
    if short then return false, ('not enough %s'):format(itemInfo(short.item)) end

    local each = math.max(500, math.floor((recipe.time or 0) * (1 + (mods.craftTimePct or 0) / 100)))
    working[src] = { id = recipe.id, qty = qty, doneAt = os.time() * 1000 + each * qty - 1000 }
    return true, each * qty
end

function Crafting.Finish(src)
    local job = working[src]
    if not job then return false, 'start it at the bench first' end
    if os.time() * 1000 < job.doneAt then return false, 'not finished yet' end
    working[src] = nil

    local recipe = byId[job.id]
    local gang = crewOf(src)
    if not recipe or not gang then return false, 'that build is gone' end
    local ok, err, mods = canMake(src, gang, recipe)
    if not ok then return false, err end
    local short = shortOf(src, recipe.inputs, job.qty)
    if short then return false, ('not enough %s'):format(itemInfo(short.item)) end

    for _, inp in ipairs(recipe.inputs) do
        exports.ox_inventory:RemoveItem(src, inp.item, inp.count * job.qty)
    end

    local made, doubled = 0, 0
    for _ = 1, job.qty do
        local n = recipe.output.count
        if math.random() * 100 < mods.bonusOutputChance then
            n = n * 2
            doubled = doubled + 1
        end
        made = made + n
    end

    exports.ox_inventory:AddItem(src, recipe.output.item, made)
    Gangs.Log(gang.id, ('%s crafted %dx %s%s'):format(
        Framework.GetName(src) or '?', made, itemInfo(recipe.output.item), doubled > 0 and ' (bonus output)' or ''))
    return true, { made = made, doubled = doubled }
end

function Crafting.Cancel(src) working[src] = nil end

AddEventHandler('playerDropped', function() working[source] = nil end)

lib.callback.register('XS-CriminalTablet:crafting:getRecipes', function(src)
    return Crafting.GetRecipes(src)
end)

lib.callback.register('XS-CriminalTablet:crafting:begin', function(src, recipeId, qty)
    local ok, res = Crafting.Begin(src, recipeId, qty)
    return { ok = ok, error = not ok and res or nil, time = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:crafting:finish', function(src)
    local ok, res = Crafting.Finish(src)
    if not ok then return { ok = false, error = res } end
    return { ok = true, made = res.made, doubled = res.doubled, data = Crafting.GetRecipes(src) }
end)

lib.callback.register('XS-CriminalTablet:crafting:cancel', function(src)
    Crafting.Cancel(src)
    return { ok = true }
end)
