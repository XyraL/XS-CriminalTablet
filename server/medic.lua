-- ─────────────────────────────────────────────────────────────
-- Street doc. One doctor the whole server shares, standing where staff
-- put him in the builder. A crew buys access (the 'medic' unlock): only
-- then do its members see him, find him on the Live Map and get treated.
-- ─────────────────────────────────────────────────────────────
Medic = {}

local visits = {}     -- [src] = { kind, target, price, doneAt }
local cooldowns = {}  -- [citizenid] = ms
local placed = nil    -- where staff put him; nil means config.lua

local function now() return os.time() * 1000 end

-- Where he stands. A spot dropped on the map has no height; the client
-- finds the ground there.
function Medic.Location()
    local l = placed or Config.Medic.location
    if not l or not tonumber(l.x) or not tonumber(l.y) then return nil end
    return { x = l.x + 0.0, y = l.y + 0.0, z = tonumber(l.z) and (l.z + 0.0) or nil, h = (tonumber(l.h) or tonumber(l.w) or 0.0) + 0.0 }
end

-- What a crew is shown: him, if they have bought him.
function Medic.ForCrew(gangId)
    if not Config.Medic.enabled or not gangId or not Placeables.Owns(gangId, 'medic') then return nil end
    local l = Medic.Location()
    if not l then return nil end
    l.label = Config.Medic.label or 'Street Doc'
    return l
end

local function docUpdate(target)
    TriggerClientEvent('XS-CriminalTablet:client:docUpdate', target or -1)
end
Medic.Refresh = docUpdate

function Medic.Place(pos, heading)
    placed = { x = pos.x + 0.0, y = pos.y + 0.0, z = tonumber(pos.z) and (pos.z + 0.0) or nil, h = (tonumber(heading) or 0.0) + 0.0 }
    MySQL.query.await('INSERT INTO `xs_tablet_settings` (`name`, `data`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `data` = VALUES(`data`)',
        { 'doc', json.encode(placed) })
    docUpdate()
    return true
end

function Medic.Reset()
    placed = nil
    MySQL.update.await('DELETE FROM `xs_tablet_settings` WHERE `name` = ?', { 'doc' })
    docUpdate()
    return true
end

function Medic.AdminState()
    local crews = {}
    for _, g in ipairs(MySQL.query.await('SELECT id, label, color FROM xs_gangs') or {}) do
        if Placeables.Owns(g.id, 'medic') then crews[#crews + 1] = { id = g.id, label = g.label, color = g.color } end
    end
    table.sort(crews, function(a, b) return a.label < b.label end)
    return { location = Medic.Location(), fromConfig = placed == nil, enabled = Config.Medic.enabled, crews = crews,
        healPrice = Config.Medic.healPrice or 0, revivePrice = Config.Medic.revivePrice or 0 }
end

CreateThread(function()
    for _ = 1, 120 do
        if Settings.loaded then break end
        Wait(250)
    end
    local row = MySQL.single.await('SELECT `data` FROM `xs_tablet_settings` WHERE `name` = ?', { 'doc' })
    local ok, data = pcall(json.decode, row and row.data or 'null')
    if ok and type(data) == 'table' and tonumber(data.x) and tonumber(data.y) then placed = data end
    docUpdate()
end)

local function nearDoc(src, doc, range)
    local p = GetEntityCoords(GetPlayerPed(src))
    local dx, dy = p.x - doc.x, p.y - doc.y
    return math.sqrt(dx * dx + dy * dy) <= (range or 3.5)
end

-- Downed, by whichever medical resource is running.
function Medic.IsDown(src)
    local st = Player(src).state
    if st and (st.isDead or st.dead or st.inLastStand or st.down) then return true end
    local p = Framework.GetPlayer(src)
    local md = p and p.PlayerData and p.PlayerData.metadata
    if md and (md.isdead or md.inlaststand) then return true end
    return GetEntityHealth(GetPlayerPed(src)) <= 0
end

-- The downed member nearest the doc, within reach of him.
local function downedNear(doc, gangId, except)
    local best, bestDist = nil, (Config.Medic.reviveRange or 4.0) + 0.0
    for _, s in ipairs(Gangs.OnlineSources(gangId)) do
        if s ~= except and Medic.IsDown(s) then
            local p = GetEntityCoords(GetPlayerPed(s))
            local dx, dy = p.x - doc.x, p.y - doc.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d <= bestDist then best, bestDist = s, d end
        end
    end
    return best
end

local function charge(src, gang, price, why)
    if price <= 0 then return true end
    local from = Config.Medic.payFrom or 'cash'
    if from == 'crew' then
        local affected = MySQL.update.await('UPDATE xs_gangs SET bank = bank - ? WHERE id = ? AND bank >= ?', { price, gang.id, price })
        if not affected or affected < 1 then return false, ('the treasury is short of $%d'):format(price) end
        gang.bank = gang.bank - price
        MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
            { gang.id, Framework.GetCitizenId(src) or '', why, 'withdraw', price })
        return true
    end
    if (Framework.GetMoney(src, from) or 0) < price then
        return false, ('he wants $%d %s'):format(price, from == 'bank' and 'from your bank' or 'in cash')
    end
    return Framework.RemoveMoney(src, from, price, 'street-doc') and true or false, 'payment failed'
end

local function check(src, kind)
    if not Config.Medic.enabled then return false, 'the street doc is off' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    if not Placeables.Owns(gang.id, 'medic') then return false, 'your crew has not paid for the street doc' end
    local doc = Medic.Location()
    if not doc then return false, 'the street doc is not set up on this server' end
    if not nearDoc(src, doc) then return false, 'go to the street doc' end
    local cid = Framework.GetCitizenId(src)
    if (cooldowns[cid] or 0) > now() then
        return false, ('he is busy for another %ds'):format(math.ceil((cooldowns[cid] - now()) / 1000))
    end

    local target = src
    if kind == 'revive' then
        target = downedNear(doc, gang.id, src)
        if not target then return false, 'nobody downed is with him' end
    elseif Medic.IsDown(src) then
        return false, 'you need someone to bring you in'
    end
    local price = kind == 'revive' and (Config.Medic.revivePrice or 0) or (Config.Medic.healPrice or 0)
    return true, nil, gang, target, math.max(0, math.floor(price))
end

-- Asking the doc. Nothing is paid yet; the work takes treatSeconds and the
-- payment and the effect both land when it is done.
function Medic.Begin(src, kind)
    kind = kind == 'revive' and 'revive' or 'heal'
    local ok, err, _, target, price = check(src, kind)
    if not ok then return false, err end
    local ms = math.max(1, tonumber(Config.Medic.treatSeconds) or 5) * 1000
    visits[src] = { kind = kind, target = target, price = price, doneAt = now() + ms - 1000 }
    return true, { time = ms, price = price, name = target ~= src and (Framework.GetName(target) or 'them') or nil }
end

function Medic.Finish(src)
    local v = visits[src]
    if not v then return false, 'ask the doc first' end
    if now() < v.doneAt then return false, 'he is not done yet' end
    visits[src] = nil

    local ok, err, gang, target, price = check(src, v.kind)
    if not ok then return false, err end
    if v.kind == 'revive' and target ~= v.target then return false, 'they are not with him any more' end

    local paid, why = charge(src, gang, price, v.kind == 'revive' and 'Street doc revive' or 'Street doc')
    if not paid then return false, why end
    cooldowns[Framework.GetCitizenId(src)] = now() + (tonumber(Config.Medic.cooldownSeconds) or 0) * 1000

    if v.kind == 'revive' then
        TriggerClientEvent('XS-CriminalTablet:client:docRevive', target)
        Framework.Notify(target, ('The doc brought you back. %s paid.'):format(Framework.GetName(src) or 'Your crew'), 'success')
        Gangs.Log(gang.id, ('%s had the doc bring back %s'):format(Framework.GetName(src) or 'Someone', Framework.GetName(target) or 'a member'), 'medic')
    else
        TriggerClientEvent('XS-CriminalTablet:client:docHeal', src)
        Gangs.Log(gang.id, ('%s got patched up by the doc'):format(Framework.GetName(src) or 'Someone'), 'medic')
    end
    return true, { kind = v.kind, price = price }
end

AddEventHandler('playerDropped', function() visits[source] = nil end)

lib.callback.register('XS-CriminalTablet:medic:where', function(src)
    local gang = Gangs.GetBySource(src)
    return gang and Medic.ForCrew(gang.id) or nil
end)

lib.callback.register('XS-CriminalTablet:medic:begin', function(src, kind)
    local ok, res = Medic.Begin(src, kind)
    if not ok then return { ok = false, error = res } end
    return { ok = true, time = res.time, price = res.price, name = res.name }
end)

lib.callback.register('XS-CriminalTablet:medic:finish', function(src)
    local ok, res = Medic.Finish(src)
    if not ok then return { ok = false, error = res } end
    return { ok = true, kind = res.kind, price = res.price }
end)

lib.callback.register('XS-CriminalTablet:medic:cancel', function(src)
    visits[src] = nil
    return { ok = true }
end)
