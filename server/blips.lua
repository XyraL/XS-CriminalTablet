-- ─────────────────────────────────────────────────────────────
-- Gang blips: staff-made map markers attached to a crew.
--
-- A blip is either crew-only (their meet spot, their lockup) or public
-- (a landmark everyone should know is theirs). The client decides what
-- to draw from `visibility` plus its own gang id, so one broadcast
-- serves every player.
-- ─────────────────────────────────────────────────────────────
Blips = {}

local rows = {}

local function loadAll()
    rows = MySQL.query.await('SELECT * FROM xs_gang_blips') or {}
end

local function broadcast()
    TriggerClientEvent('XS-CriminalTablet:client:blipsUpdate', -1, Blips.GetAll())
end
Blips.Broadcast = broadcast

function Blips.GetAll()
    local list = {}
    for _, r in ipairs(rows) do
        local gang = Gangs.Get(r.gang_id)
        list[#list + 1] = {
            id = r.id,
            gangId = r.gang_id,
            gangLabel = gang and gang.label or '?',
            gangColor = gang and gang.color or '#6b7280',
            label = r.label ~= '' and r.label or (gang and gang.label or 'Crew'),
            sprite = r.sprite,
            color = r.color,
            scale = r.scale,
            coords = { x = r.x, y = r.y, z = r.z },
            visibility = r.visibility,
            shortRange = r.short_range == 1,
        }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function Blips.ForGang(gangId)
    local list = {}
    for _, b in ipairs(Blips.GetAll()) do
        if b.gangId == gangId then list[#list + 1] = b end
    end
    return list
end

local function clampNumber(v, lo, hi, fallback)
    local n = tonumber(v)
    if not n then return fallback end
    return math.max(lo, math.min(hi, n))
end

function Blips.Create(gangId, opts)
    gangId = tonumber(gangId)
    if not gangId or not Gangs.Get(gangId) then return false, 'unknown gang' end
    opts = opts or {}

    local coords = opts.coords
    if type(coords) ~= 'table' or not tonumber(coords.x) or not tonumber(coords.y) then
        return false, 'needs a position'
    end

    local id = MySQL.insert.await(
        'INSERT INTO xs_gang_blips (gang_id, label, sprite, color, scale, x, y, z, visibility, short_range) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        {
            gangId,
            tostring(opts.label or ''):sub(1, 64),
            clampNumber(opts.sprite, 1, 826, 84),
            clampNumber(opts.color, 0, 85, 0),
            clampNumber(opts.scale, 0.2, 2.0, 0.8),
            tonumber(coords.x), tonumber(coords.y), tonumber(coords.z) or 30.0,
            opts.visibility == 'all' and 'all' or 'gang',
            opts.shortRange == false and 0 or 1,
        })

    loadAll()
    broadcast()
    return true, id
end

function Blips.Update(id, fields)
    id = tonumber(id)
    if not id then return false, 'unknown blip' end
    fields = fields or {}

    local sets, args = {}, {}
    local function set(col, value)
        sets[#sets + 1] = ('%s = ?'):format(col)
        args[#args + 1] = value
    end

    if fields.label ~= nil then set('label', tostring(fields.label):sub(1, 64)) end
    if fields.sprite ~= nil then set('sprite', clampNumber(fields.sprite, 1, 826, 84)) end
    if fields.color ~= nil then set('color', clampNumber(fields.color, 0, 85, 0)) end
    if fields.scale ~= nil then set('scale', clampNumber(fields.scale, 0.2, 2.0, 0.8)) end
    if fields.visibility ~= nil then set('visibility', fields.visibility == 'all' and 'all' or 'gang') end
    if fields.shortRange ~= nil then set('short_range', fields.shortRange and 1 or 0) end
    if type(fields.coords) == 'table' and tonumber(fields.coords.x) then
        set('x', tonumber(fields.coords.x))
        set('y', tonumber(fields.coords.y))
        set('z', tonumber(fields.coords.z) or 30.0)
    end
    if #sets == 0 then return true end

    args[#args + 1] = id
    MySQL.update(('UPDATE xs_gang_blips SET %s WHERE id = ?'):format(table.concat(sets, ', ')), args)
    loadAll()
    broadcast()
    return true
end

function Blips.Delete(id)
    id = tonumber(id)
    if not id then return false, 'unknown blip' end
    MySQL.update('DELETE FROM xs_gang_blips WHERE id = ?', { id })
    loadAll()
    broadcast()
    return true
end

function Blips.ClearForGang(gangId)
    gangId = tonumber(gangId)
    if not gangId then return false, 'unknown gang' end
    MySQL.update('DELETE FROM xs_gang_blips WHERE gang_id = ?', { gangId })
    loadAll()
    broadcast()
    return true
end

CreateThread(function()
    Wait(1500)
    loadAll()
    broadcast()
end)

AddEventHandler('playerJoining', function()
    local src = source
    SetTimeout(4000, function()
        if GetPlayerName(src) then
            TriggerClientEvent('XS-CriminalTablet:client:blipsUpdate', src, Blips.GetAll())
        end
    end)
end)
