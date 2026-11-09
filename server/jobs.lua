-- ─────────────────────────────────────────────────────────────
-- Job builder. Jobs made in the builder live in xs_jobs and are merged
-- into Config.Tasks on top of the ones in config.lua. Saving a config job
-- in the builder stores an override under the same id; deleting one hides
-- it until staff put it back.
-- ─────────────────────────────────────────────────────────────
Jobs = {}

local TYPES = {
    courier = { points = { vanSpawns = 'many', dropoffs = 'many' } },
    kill    = { points = { spawnPoints = 'many' } },
    escort  = { points = { spawn = 'one', destination = 'one' } },
    heist   = { points = { infiltrate = 'one', grab = 'one', escape = 'one' } },
}
Jobs.Types = TYPES

local configJobs = {}
local rows = {}         -- [id] = { def = table, deleted = bool }

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local function plain(p)
    if p == nil then return nil end
    return { x = p.x + 0.0, y = p.y + 0.0, z = p.z + 0.0, w = (p.w or 0.0) + 0.0 }
end

-- Points cross JSON as plain tables; the job code does vector maths on them,
-- so they become vec3 (single places) or vec4 (spawns with a heading).
local function toGame(def)
    local out = copy(def)
    for field, kind in pairs((TYPES[def.type] or {}).points or {}) do
        if kind == 'many' then
            local list = {}
            for _, p in ipairs(def[field] or {}) do list[#list + 1] = vec4(p.x + 0.0, p.y + 0.0, p.z + 0.0, (p.w or 0.0) + 0.0) end
            out[field] = list
        elseif def[field] then
            local p = def[field]
            out[field] = vec3(p.x + 0.0, p.y + 0.0, p.z + 0.0)
        end
    end
    return out
end

local function toPlain(def)
    local out = copy(def)
    for field, kind in pairs((TYPES[def.type] or {}).points or {}) do
        if kind == 'many' then
            local list = {}
            for _, p in ipairs(def[field] or {}) do list[#list + 1] = plain(p) end
            out[field] = list
        else
            out[field] = plain(def[field])
        end
    end
    return out
end

-- What a job still needs before it can go on the board.
function Jobs.Missing(def)
    local missing = {}
    for field, kind in pairs((TYPES[def.type] or {}).points or {}) do
        local v = def[field]
        if kind == 'many' and (type(v) ~= 'table' or #v == 0) then missing[#missing + 1] = field end
        if kind == 'one' and v == nil then missing[#missing + 1] = field end
    end
    table.sort(missing)
    return missing
end

local function num(v, lo, hi, fallback)
    local n = tonumber(v)
    if not n or n ~= n then return fallback end
    return math.max(lo, math.min(hi, n))
end

local function int(v, lo, hi, fallback)
    local n = num(v, lo, hi, nil)
    return n and math.floor(n + 0.5) or fallback
end

local function model(v, fallback, upper)
    local s = tostring(v or ''):gsub('[^%w_]', ''):sub(1, 64)
    if s == '' then return fallback end
    return upper and s:upper() or s:lower()
end

local function cleanPoints(list, many, max)
    if many then
        local out = {}
        for _, p in ipairs(type(list) == 'table' and list or {}) do
            if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) and #out < (max or 20) then
                out[#out + 1] = { x = tonumber(p.x) + 0.0, y = tonumber(p.y) + 0.0, z = tonumber(p.z) + 0.0, w = (tonumber(p.w) or 0.0) + 0.0 }
            end
        end
        return out
    end
    if type(list) == 'table' and tonumber(list.x) and tonumber(list.y) and tonumber(list.z) then
        return { x = tonumber(list.x) + 0.0, y = tonumber(list.y) + 0.0, z = tonumber(list.z) + 0.0 }
    end
    return nil
end

function Jobs.Clean(input)
    if type(input) ~= 'table' then return nil, 'nothing to save' end
    local kind = tostring(input.type or '')
    if not TYPES[kind] then return nil, 'pick what kind of job it is' end
    local label = tostring(input.label or ''):gsub('[%c]', ''):match('^%s*(.-)%s*$'):sub(1, 48)
    if #label < 2 then return nil, 'give the job a name' end
    local cats = {}
    for _, c in ipairs(Config.Contracts.categories) do cats[c.id] = true end
    local id = tostring(input.id or ''):lower():gsub('[^%w_]', ''):sub(1, 48)
    if id == '' then
        id = label:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', ''):sub(1, 36) .. '_' .. tostring(math.random(1000, 9999))
    end
    local def = {
        id = id, type = kind, label = label,
        category = cats[input.category] and input.category or Config.Contracts.categories[1].id,
        difficulty = int(input.difficulty, 1, 5, 1),
        minLevel = int(input.minLevel, 1, #Config.TaskLevels, 1),
        reward = int(input.reward, 0, 100000, 0),
        cash = int(input.cash, 0, 10000000, 0),
        xp = int(input.xp, 0, 100000, 0),
        cooldownMinutes = int(input.cooldownMinutes, 0, 1440, 30),
        timeLimitSeconds = int(input.timeLimitSeconds, 60, 7200, 600),
        coopOnly = input.coopOnly == true,
        disabled = input.disabled == true,
    }
    if kind == 'courier' then
        def.vanModel = model(input.vanModel, 'speedo')
        def.carryProp = model(input.carryProp, 'prop_box_ammo04a')
        def.dropoffPedModel = model(input.dropoffPedModel, 'g_m_y_lost_01')
        def.quartermasterModel = model(input.quartermasterModel, 'g_m_y_lost_01')
        def.ambushChance = int(input.ambushChance, 0, 100, 0)
        def.radius = num(input.radius, 1, 50, 6.0)
    elseif kind == 'kill' then
        def.pedModel = model(input.pedModel, 'g_m_y_lost_01')
        def.weapon = model(input.weapon, 'WEAPON_PISTOL', true)
        def.minKillSeconds = int(input.minKillSeconds, 0, 120, 5)
    elseif kind == 'escort' then
        def.pedModel = model(input.pedModel, 'g_m_y_lost_01')
        def.radius = num(input.radius, 1, 50, 5.0)
    elseif kind == 'heist' then
        def.holdSeconds = int(input.holdSeconds, 1, 120, 6)
        def.radius = num(input.radius, 1, 50, 2.5)
    end
    for field, many in pairs(TYPES[kind].points) do
        def[field] = cleanPoints(input[field], many == 'many')
    end
    return def
end

-- Rebuild Config.Tasks: config.lua's jobs in their order (with any
-- builder override in place), then the builder's own jobs.
function Jobs.Apply()
    local list, seen = {}, {}
    for _, def in ipairs(configJobs) do
        seen[def.id] = true
        local row = rows[def.id]
        if not row then list[#list + 1] = copy(def)
        elseif not row.deleted and not row.def.disabled and #Jobs.Missing(row.def) == 0 then list[#list + 1] = toGame(row.def) end
    end
    local custom = {}
    for id, row in pairs(rows) do
        if not seen[id] and not row.deleted and not row.def.disabled and #Jobs.Missing(row.def) == 0 then custom[#custom + 1] = row.def end
    end
    table.sort(custom, function(a, b) return a.label < b.label end)
    for _, def in ipairs(custom) do list[#list + 1] = toGame(def) end
    Config.Tasks = list
    if Tasks and Tasks.Index then Tasks.Index() end
    if Contracts and Contracts.Reroll then pcall(Contracts.Reroll) end
end

function Jobs.Load()
    -- config.lua's own list, taken once before any builder job is merged in.
    if not configJobs.snapped then
        configJobs = { snapped = true }
        for _, def in ipairs(Config.Tasks) do configJobs[#configJobs + 1] = copy(def) end
    end
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `xs_jobs` (
            `id`         VARCHAR(48) NOT NULL,
            `data`       LONGTEXT    NOT NULL,
            `updated_at` BIGINT      NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    rows = {}
    for _, r in ipairs(MySQL.query.await('SELECT `id`, `data` FROM `xs_jobs`') or {}) do
        local ok, data = pcall(json.decode, r.data)
        if ok and type(data) == 'table' then
            if data.deleted then rows[r.id] = { deleted = true, def = {} }
            else
                local def = Jobs.Clean(data)
                if def then def.id = r.id; rows[r.id] = { def = def } end
            end
        end
    end
    Jobs.Apply()
end

local function store(id, data)
    MySQL.query.await('INSERT INTO `xs_jobs` (`id`, `data`, `updated_at`) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE `data` = VALUES(`data`), `updated_at` = VALUES(`updated_at`)',
        { id, json.encode(data), os.time() })
end

local function isConfigJob(id)
    for _, def in ipairs(configJobs) do if def.id == id then return def end end
    return nil
end

-- Everything the builder's Jobs page shows.
function Jobs.List()
    local out = {}
    local function add(def, source, extra)
        local plainDef = toPlain(def)
        plainDef.source = source
        plainDef.missing = Jobs.Missing(def)
        for k, v in pairs(extra or {}) do plainDef[k] = v end
        out[#out + 1] = plainDef
    end
    for _, def in ipairs(configJobs) do
        local row = rows[def.id]
        if row and row.deleted then add(def, 'config', { deleted = true })
        elseif row then add(row.def, 'config', { edited = true })
        else add(def, 'config') end
    end
    for id, row in pairs(rows) do
        if not isConfigJob(id) and not row.deleted then add(row.def, 'builder') end
    end
    return out
end

function Jobs.Save(input)
    local def, err = Jobs.Clean(input)
    if not def then return false, err end
    rows[def.id] = { def = def }
    store(def.id, def)
    Jobs.Apply()
    return true, def.id
end

function Jobs.Delete(id)
    id = tostring(id or '')
    if isConfigJob(id) then
        rows[id] = { deleted = true, def = {} }
        store(id, { deleted = true })
    elseif rows[id] then
        rows[id] = nil
        MySQL.query.await('DELETE FROM `xs_jobs` WHERE `id` = ?', { id })
    else
        return false, 'unknown job'
    end
    Jobs.Apply()
    return true
end

-- A config.lua job goes back to exactly what config.lua says.
function Jobs.Restore(id)
    id = tostring(id or '')
    if not isConfigJob(id) then return false, 'only jobs from config.lua can be put back' end
    rows[id] = nil
    MySQL.query.await('DELETE FROM `xs_jobs` WHERE `id` = ?', { id })
    Jobs.Apply()
    return true
end

CreateThread(function()
    local ok, err = pcall(Jobs.Load)
    if not ok then print('^1[XS-CriminalTablet]^0 builder jobs could not load, using config.lua: ' .. tostring(err)) end
end)

local function staff(src) return IsPlayerAceAllowed(src, Config.AdminAce) end

lib.callback.register('XS-CriminalTablet:admin:jobs', function(src)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    local levels = {}
    for _, l in ipairs(Config.TaskLevels) do levels[#levels + 1] = { level = l.level, title = l.title } end
    return { ok = true, data = { jobs = Jobs.List(), categories = Config.Contracts.categories, levels = levels } }
end)

lib.callback.register('XS-CriminalTablet:admin:saveJob', function(src, def)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    local ok, res = Jobs.Save(def)
    if ok then print(('^2[XS-CriminalTablet]^0 %s saved the job %s'):format(GetPlayerName(src) or src, res)) end
    return { ok = ok, error = not ok and res or nil, id = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:admin:deleteJob', function(src, id)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    local ok, err = Jobs.Delete(id)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:admin:restoreJob', function(src, id)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    local ok, err = Jobs.Restore(id)
    return { ok = ok, error = err }
end)
