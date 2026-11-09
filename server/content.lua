-- ─────────────────────────────────────────────────────────────
-- Crafting and perks, editable in the builder: bench recipes, the perk
-- tree and treasury upgrades. config.lua stays the default; a saved
-- version replaces it whole, and Back to config.lua puts it back.
-- Perk, upgrade and recipe ids are kept as they are, so what a crew
-- already owns carries on counting after an edit.
-- ─────────────────────────────────────────────────────────────
Content = {}

local KINDS = { recipes = 'Recipes', perks = 'GangPerks', upgrades = 'Upgrades' }
Content.PerkEffects = { 'slotsBonus', 'weightBonusPct', 'maxMembersBonus', 'craftTimePct', 'bonusOutputChance', 'tierBoost', 'captureSpeedPct', 'defenceWeightPct', 'raidCutPct' }
Content.UpgradeEffects = { 'maxMembersBonus', 'vaultSlotsBonus', 'vaultWeightBonusPct', 'garageSlotsBonus', 'raidRewardPct', 'captureSpeedPct' }

local defaults = {}
local saved = {}

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local function text(v, max) return (tostring(v or ''):gsub('[%c]', ''):match('^%s*(.-)%s*$')):sub(1, max) end
local function slug(v, max) return (tostring(v or ''):lower():gsub('[^%w_]', '')):sub(1, max or 48) end
-- An id for something new, from its name: "Night Crew" becomes night_crew.
local function idFrom(given, label, max)
    if given and given ~= '' then return slug(given, max) end
    return (tostring(label or ''):lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')):sub(1, max or 48)
end
local function int(v, lo, hi) local n = tonumber(v); if not n or n ~= n then return nil end return math.max(lo, math.min(hi, math.floor(n + 0.5))) end
local function icon(v) local s = tostring(v or ''); return s:match('^fa%-[%w%-]+$') and s or 'fa-star' end

local function tierNames()
    local names = {}
    for _, t in ipairs(Config.Rep.tiers) do names[t.name] = true end
    return names
end

local function effects(input, keys, out)
    local n = 0
    for _, k in ipairs(keys) do
        local v = tonumber(type(input) == 'table' and input[k])
        if v and v ~= 0 and n < 3 then out[k] = math.max(-100, math.min(1000, v)); n = n + 1 end
    end
end

local CLEAN = {}

function CLEAN.recipes(list)
    if type(list) ~= 'table' then return nil, 'nothing to save' end
    local out, seen, tiers = {}, {}, tierNames()
    for _, r in ipairs(list) do
        local label = text(r.label, 48)
        if #label < 2 then return nil, 'every recipe needs a name' end
        local id = idFrom(r.id, label, 48)
        if id == '' or seen[id] then id = slug(label, 40) .. '_' .. (#out + 1) end
        seen[id] = true
        local inputs = {}
        for _, i in ipairs(type(r.inputs) == 'table' and r.inputs or {}) do
            local item = slug(i.item, 64)
            if item ~= '' and #inputs < 8 then inputs[#inputs + 1] = { item = item, count = int(i.count, 1, 1000) or 1 } end
        end
        if #inputs == 0 then return nil, ('%s needs at least one ingredient'):format(label) end
        local outItem = slug(r.output and r.output.item, 64)
        if outItem == '' then return nil, ('%s needs something to make'):format(label) end
        out[#out + 1] = {
            id = id, label = label, tier = tiers[r.tier] and r.tier or Config.Rep.tiers[1].name,
            inputs = inputs, output = { item = outItem, count = int(r.output.count, 1, 1000) or 1 },
            time = int(r.time, 500, 120000) or 5000,
        }
        if #out >= 60 then break end
    end
    return out
end

function CLEAN.perks(list)
    if type(list) ~= 'table' then return nil, 'nothing to save' end
    local out, seenBranch, seenTier = {}, {}, {}
    for i, b in ipairs(list) do
        local label = text(b.label, 32)
        if #label < 2 then return nil, 'every branch needs a name' end
        local id = idFrom(b.id, label, 32)
        if id == '' or seenBranch[id] then id = slug(label, 24) .. '_' .. i end
        seenBranch[id] = true
        local tiers = {}
        for j, t in ipairs(type(b.tiers) == 'table' and b.tiers or {}) do
            local tl = text(t.label, 40)
            if #tl < 2 then return nil, ('every perk in %s needs a name'):format(label) end
            local tid = idFrom(t.id, id .. '_' .. j, 48)
            if tid == '' or seenTier[tid] then tid = id .. '_' .. j .. '_' .. math.random(100, 999) end
            seenTier[tid] = true
            local tier = { id = tid, label = tl, description = text(t.description, 120), cost = int(t.cost, 1, 20) or 1 }
            effects(t, Content.PerkEffects, tier)
            if #tiers < 6 then tiers[#tiers + 1] = tier end
        end
        if #tiers == 0 then return nil, ('%s needs at least one perk'):format(label) end
        out[id] = { label = label, icon = icon(b.icon), order = i, tiers = tiers }
        if i >= 8 then break end
    end
    return out
end

function CLEAN.upgrades(list)
    if type(list) ~= 'table' then return nil, 'nothing to save' end
    local out, seen = {}, {}
    for i, u in ipairs(list) do
        local label = text(u.label, 40)
        if #label < 2 then return nil, 'every upgrade needs a name' end
        local id = idFrom(u.id, label, 32)
        if id == '' or seen[id] then id = slug(label, 24) .. '_' .. i end
        seen[id] = true
        local levels = {}
        for _, l in ipairs(type(u.levels) == 'table' and u.levels or {}) do
            local level = { cost = int(l.cost, 0, 100000000) or 0 }
            effects(l, Content.UpgradeEffects, level)
            if #levels < 8 then levels[#levels + 1] = level end
        end
        if #levels == 0 then return nil, ('%s needs at least one level'):format(label) end
        out[#out + 1] = { id = id, label = label, icon = icon(u.icon), description = text(u.description, 120), levels = levels }
        if #out >= 12 then break end
    end
    return out
end

-- The perk tree is a map in config.lua; the builder edits it as a list.
local function perksAsList(map)
    local list = {}
    for id, b in pairs(map or {}) do
        local tiers = {}
        for _, t in ipairs(b.tiers or {}) do tiers[#tiers + 1] = copy(t) end
        list[#list + 1] = { id = id, label = b.label, icon = b.icon, order = b.order or 99, tiers = tiers }
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
end

function Content.Apply()
    for kind, key in pairs(KINDS) do
        Config[key] = copy(saved[kind] or defaults[kind])
    end
    if Crafting and Crafting.Index then Crafting.Index() end
    if Gangs and Gangs.InvalidateModifiers then Gangs.InvalidateModifiers() end
end

function Content.Load()
    if not defaults.snapped then
        for kind, key in pairs(KINDS) do defaults[kind] = copy(Config[key]) end
        defaults.snapped = true
    end
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `xs_content` (
            `name` VARCHAR(32) NOT NULL,
            `data` LONGTEXT    NOT NULL,
            PRIMARY KEY (`name`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    saved = {}
    for _, row in ipairs(MySQL.query.await('SELECT `name`, `data` FROM `xs_content`') or {}) do
        local ok, data = pcall(json.decode, row.data)
        if ok and KINDS[row.name] and type(data) == 'table' then
            local clean = CLEAN[row.name](row.name == 'perks' and data.list or data)
            if clean then saved[row.name] = clean end
        end
    end
    Content.Apply()
end

function Content.Save(kind, data)
    if not KINDS[kind] then return false, 'unknown kind' end
    local clean, err = CLEAN[kind](data)
    if not clean then return false, err end
    saved[kind] = clean
    local stored = kind == 'perks' and { list = data } or clean
    MySQL.query.await('INSERT INTO `xs_content` (`name`, `data`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `data` = VALUES(`data`)', { kind, json.encode(stored) })
    Content.Apply()
    return true
end

function Content.Reset(kind)
    if not KINDS[kind] then return false, 'unknown kind' end
    saved[kind] = nil
    MySQL.query.await('DELETE FROM `xs_content` WHERE `name` = ?', { kind })
    Content.Apply()
    return true
end

function Content.Builder()
    local tiers = {}
    for _, t in ipairs(Config.Rep.tiers) do tiers[#tiers + 1] = t.name end
    return {
        recipes = copy(Config.Recipes), perks = perksAsList(Config.GangPerks), upgrades = copy(Config.Upgrades),
        edited = { recipes = saved.recipes ~= nil, perks = saved.perks ~= nil, upgrades = saved.upgrades ~= nil },
        tiers = tiers, perkEffects = Content.PerkEffects, upgradeEffects = Content.UpgradeEffects,
        items = Settings.Items and Settings.Items() or {},
    }
end

CreateThread(function()
    local ok, err = pcall(Content.Load)
    if not ok then print('^1[XS-CriminalTablet]^0 crafting and perks could not load, using config.lua: ' .. tostring(err)) end
end)

local function staff(src) return IsPlayerAceAllowed(src, Config.AdminAce) end

lib.callback.register('XS-CriminalTablet:admin:content', function(src)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    return { ok = true, data = Content.Builder() }
end)

lib.callback.register('XS-CriminalTablet:admin:saveContent', function(src, kind, data)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    local ok, err = Content.Save(kind, data)
    if ok then print(('^2[XS-CriminalTablet]^0 %s saved the %s'):format(GetPlayerName(src) or src, kind)) end
    return { ok = ok, error = err, data = ok and Content.Builder() or nil }
end)

lib.callback.register('XS-CriminalTablet:admin:resetContent', function(src, kind)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    local ok, err = Content.Reset(kind)
    return { ok = ok, error = err, data = ok and Content.Builder() or nil }
end)
