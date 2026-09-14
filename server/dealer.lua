-- ─────────────────────────────────────────────────────────────
-- Dealer: on-demand contact, not a placed fixture. Any gang member hits
-- "Call Dealer" on the tablet; one call at a time server-wide on a global
-- cooldown (not per-player) — whoever calls it first after the cooldown
-- clears is the one who gets it. The ped spawns at a random configured
-- point and despawns after a timeout if nobody reaches it. Stock rotates
-- independently of contact calls.
-- ─────────────────────────────────────────────────────────────
Dealer = {}

local stock = {}
local lastContactAt = 0
local activeSpawn = nil -- { coords = vec4, expiresAt = ms }

-- Everything below is editable from the staff tablet and lives in the
-- database. config.lua is the seed and the fallback: whatever is in the
-- DB wins, and an empty DB falls back to the config so a fresh install
-- still behaves.
local pool = {}       -- [{ id, item, label, priceMin, priceMax }]
local spawns = {}     -- [{ id, label, coords = vec4 }]
local settings = {}   -- scalar overrides, keyed like Config.Dealer

local SETTING_KEYS = {
    cooldownHours = 'number', timeoutMinutes = 'number', rotateMinutes = 'number',
    stockSize = 'number', pedModel = 'string', account = 'string',
}

-- One accessor for every tunable, so nothing reads Config.Dealer directly
-- and then quietly ignores a staff override.
function Dealer.Setting(key)
    local v = settings[key]
    if v ~= nil then return v end
    return Config.Dealer[key]
end

local function loadPool()
    pool = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM xs_dealer_pool ORDER BY id') or {}) do
        pool[#pool + 1] = {
            id = r.id, item = r.item, label = r.label ~= '' and r.label or r.item,
            priceMin = r.price_min, priceMax = r.price_max,
        }
    end
    if #pool == 0 then
        for _, e in ipairs(Config.Dealer.pool or {}) do
            pool[#pool + 1] = { id = nil, item = e.item, label = e.label, priceMin = e.priceMin, priceMax = e.priceMax }
        end
    end
end

local function loadSpawns()
    spawns = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM xs_dealer_spawns ORDER BY id') or {}) do
        spawns[#spawns + 1] = { id = r.id, label = r.label, coords = vec4(r.x, r.y, r.z, r.heading) }
    end
    if #spawns == 0 then
        for i, c in ipairs(Config.Dealer.spawnPoints or {}) do
            spawns[#spawns + 1] = { id = nil, label = ('Spot %d'):format(i), coords = c }
        end
    end
end

local function loadSettings()
    settings = {}
    for _, r in ipairs(MySQL.query.await("SELECT skey, svalue FROM xs_settings WHERE scope = 'dealer'") or {}) do
        local kind = SETTING_KEYS[r.skey]
        if kind == 'number' then settings[r.skey] = tonumber(r.svalue)
        elseif kind == 'string' then settings[r.skey] = r.svalue end
    end
end

function Dealer.Reload()
    loadPool()
    loadSpawns()
    loadSettings()
end

local function rollStock()
    stock = {}
    if #pool == 0 then return end

    local indices = {}
    for i = 1, #pool do indices[i] = i end
    for i = #indices, 2, -1 do -- shuffle
        local j = math.random(i)
        indices[i], indices[j] = indices[j], indices[i]
    end

    local count = math.min(Dealer.Setting('stockSize') or 4, #pool)
    for i = 1, count do
        local entry = pool[indices[i]]
        stock[#stock + 1] = {
            item = entry.item,
            label = entry.label,
            price = math.random(entry.priceMin, entry.priceMax),
        }
    end

    if Config.Debug then print(('^3[XS-CriminalTablet]^0 dealer stock rolled (%d items)'):format(#stock)) end
end

function Dealer.GetStock()
    return stock
end

-- ── admin control ──
function Dealer.ForceReroll()
    rollStock()
end

function Dealer.AdminState()
    return {
        pool = pool,
        spawns = (function()
            local out = {}
            for _, s in ipairs(spawns) do
                out[#out + 1] = { id = s.id, label = s.label,
                    coords = { x = s.coords.x, y = s.coords.y, z = s.coords.z, w = s.coords.w } }
            end
            return out
        end)(),
        settings = {
            cooldownHours = Dealer.Setting('cooldownHours'),
            timeoutMinutes = Dealer.Setting('timeoutMinutes'),
            rotateMinutes = Dealer.Setting('rotateMinutes'),
            stockSize = Dealer.Setting('stockSize'),
            pedModel = Dealer.Setting('pedModel'),
            account = Dealer.Setting('account'),
        },
        stock = stock,
        -- True while the lists are still coming from config.lua rather
        -- than the database, so the panel can say so.
        poolFromConfig = #pool > 0 and pool[1].id == nil,
        spawnsFromConfig = #spawns > 0 and spawns[1].id == nil,
    }
end

function Dealer.AddPoolItem(item, label, priceMin, priceMax)
    item = tostring(item or ''):gsub('%s', '')
    if item == '' then return false, 'needs an item name' end
    local lo = math.max(0, math.floor(tonumber(priceMin) or 0))
    local hi = math.max(lo, math.floor(tonumber(priceMax) or lo))

    MySQL.query.await(
        'INSERT INTO xs_dealer_pool (item, label, price_min, price_max) VALUES (?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE label = VALUES(label), price_min = VALUES(price_min), price_max = VALUES(price_max)',
        { item, tostring(label or ''):sub(1, 64), lo, hi })
    loadPool()
    return true
end

function Dealer.RemovePoolItem(id)
    id = tonumber(id)
    if not id then return false, 'unknown row' end
    MySQL.update('DELETE FROM xs_dealer_pool WHERE id = ?', { id })
    loadPool()
    return true
end

function Dealer.AddSpawn(label, coords, heading)
    if type(coords) ~= 'table' or not tonumber(coords.x) then return false, 'needs a position' end
    MySQL.insert.await(
        'INSERT INTO xs_dealer_spawns (label, x, y, z, heading) VALUES (?, ?, ?, ?, ?)',
        { tostring(label or ''):sub(1, 64), tonumber(coords.x), tonumber(coords.y),
          tonumber(coords.z) or 30.0, tonumber(heading) or 0.0 })
    loadSpawns()
    return true
end

function Dealer.RemoveSpawn(id)
    id = tonumber(id)
    if not id then return false, 'unknown row' end
    MySQL.update('DELETE FROM xs_dealer_spawns WHERE id = ?', { id })
    loadSpawns()
    return true
end

function Dealer.SetSetting(key, value)
    local kind = SETTING_KEYS[key]
    if not kind then return false, 'unknown setting' end
    if kind == 'number' then
        local n = tonumber(value)
        if not n then return false, 'that needs to be a number' end
        value = tostring(math.max(0, n))
    else
        value = tostring(value or ''):sub(1, 64)
    end

    MySQL.query.await(
        "INSERT INTO xs_settings (scope, skey, svalue) VALUES ('dealer', ?, ?) " ..
        'ON DUPLICATE KEY UPDATE svalue = VALUES(svalue)', { key, value })
    loadSettings()
    return true
end

function Dealer.ResetSetting(key)
    MySQL.update("DELETE FROM xs_settings WHERE scope = 'dealer' AND skey = ?", { key })
    loadSettings()
    return true
end

function Dealer.ClearCooldown()
    lastContactAt = 0
end

function Dealer.Buy(src, item)
    local entry = nil
    for _, s in ipairs(stock) do if s.item == item then entry = s break end end
    if not entry then return false, 'not in stock' end

    local account = Dealer.Setting('account')
    if Framework.GetMoney(src, account) < entry.price then return false, 'not enough funds' end
    Framework.RemoveMoney(src, account, entry.price, 'xs-dealer')
    exports.ox_inventory:AddItem(src, entry.item, 1)

    local cid = Framework.GetCitizenId(src)
    local gang = cid and Gangs.GetByCitizen(cid)
    if gang then
        Gangs.Log(gang.id, ('%s bought %s from the dealer for $%d'):format(Framework.GetName(src) or cid, entry.label, entry.price))
    end
    Discord.Send('economy', 'Dealer purchase', ('%s bought %s for $%d'):format(Framework.GetName(src) or cid or src, entry.label, entry.price), Discord.Color.good)

    return true, entry.price
end

-- ── contact / spawn lifecycle ──
local function despawn()
    activeSpawn = nil
    TriggerClientEvent('XS-CriminalTablet:client:dealerDespawn', -1)
end

function Dealer.GetStatus()
    local cooldownMs = math.max(0, (lastContactAt + Dealer.Setting('cooldownHours') * 60 * 60 * 1000) - os.time() * 1000)
    return { cooldownMs = cooldownMs, spawn = activeSpawn and activeSpawn.coords or nil }
end

function Dealer.Contact(src)
    local now = os.time() * 1000
    if now - lastContactAt < Dealer.Setting('cooldownHours') * 60 * 60 * 1000 then
        return false, 'the dealer was just called — try again later'
    end

    if #spawns == 0 then return false, 'no spawn points set up' end

    lastContactAt = now
    local coords = spawns[math.random(#spawns)].coords
    activeSpawn = { coords = coords, expiresAt = now + Dealer.Setting('timeoutMinutes') * 60 * 1000 }

    local cid = Framework.GetCitizenId(src)
    local gang = cid and Gangs.GetByCitizen(cid)
    if gang then
        Gangs.Log(gang.id, ('%s called the dealer'):format(Framework.GetName(src) or cid))
    end

    TriggerClientEvent('XS-CriminalTablet:client:dealerSpawn', -1, coords, Dealer.Setting('pedModel'))
    SetTimeout(Dealer.Setting('timeoutMinutes') * 60 * 1000, function()
        if activeSpawn and activeSpawn.expiresAt <= os.time() * 1000 then despawn() end
    end)
    return true
end

CreateThread(function()
    -- After the DB is up, so the staff-edited pool and spawns are what
    -- the first roll actually uses.
    Wait(1500)
    Dealer.Reload()
    rollStock()
    while true do
        Wait(math.max(1, Dealer.Setting('rotateMinutes')) * 60 * 1000)
        rollStock()
    end
end)

lib.callback.register('XS-CriminalTablet:dealer:getStock', function()
    return Dealer.GetStock()
end)

lib.callback.register('XS-CriminalTablet:dealer:buy', function(src, item)
    local ok, res = Dealer.Buy(src, item)
    return { ok = ok, error = not ok and res or nil, price = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:dealer:getStatus', function()
    return Dealer.GetStatus()
end)

lib.callback.register('XS-CriminalTablet:dealer:contact', function(src)
    local ok, err = Dealer.Contact(src)
    return { ok = ok, error = err }
end)
