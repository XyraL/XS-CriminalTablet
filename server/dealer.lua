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

local function rollStock()
    stock = {}
    local pool = Config.Dealer.pool
    if #pool == 0 then return end

    local indices = {}
    for i = 1, #pool do indices[i] = i end
    for i = #indices, 2, -1 do -- shuffle
        local j = math.random(i)
        indices[i], indices[j] = indices[j], indices[i]
    end

    local count = math.min(Config.Dealer.stockSize, #pool)
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

function Dealer.ClearCooldown()
    lastContactAt = 0
end

function Dealer.Buy(src, item)
    local entry = nil
    for _, s in ipairs(stock) do if s.item == item then entry = s break end end
    if not entry then return false, 'not in stock' end

    if Framework.GetMoney(src, Config.Dealer.account) < entry.price then return false, 'not enough funds' end
    Framework.RemoveMoney(src, Config.Dealer.account, entry.price, 'xs-dealer')
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
    local cooldownMs = math.max(0, (lastContactAt + Config.Dealer.cooldownHours * 60 * 60 * 1000) - os.time() * 1000)
    return { cooldownMs = cooldownMs, spawn = activeSpawn and activeSpawn.coords or nil }
end

function Dealer.Contact(src)
    local now = os.time() * 1000
    if now - lastContactAt < Config.Dealer.cooldownHours * 60 * 60 * 1000 then
        return false, 'the dealer was just called — try again later'
    end

    local points = Config.Dealer.spawnPoints
    if #points == 0 then return false, 'no spawn points configured' end

    lastContactAt = now
    local coords = points[math.random(#points)]
    activeSpawn = { coords = coords, expiresAt = now + Config.Dealer.timeoutMinutes * 60 * 1000 }

    local cid = Framework.GetCitizenId(src)
    local gang = cid and Gangs.GetByCitizen(cid)
    if gang then
        Gangs.Log(gang.id, ('%s called the dealer'):format(Framework.GetName(src) or cid))
    end

    TriggerClientEvent('XS-CriminalTablet:client:dealerSpawn', -1, coords, Config.Dealer.pedModel)
    SetTimeout(Config.Dealer.timeoutMinutes * 60 * 1000, function()
        if activeSpawn and activeSpawn.expiresAt <= os.time() * 1000 then despawn() end
    end)
    return true
end

CreateThread(function()
    rollStock()
    while true do
        Wait(Config.Dealer.rotateMinutes * 60 * 1000)
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
