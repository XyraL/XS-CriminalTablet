-- Patching the registrar rather than each call site gives every NUI callback
-- in the resource two guarantees, including any added later:
--
-- 1. Each handler runs in its own thread. FiveM will not dispatch the next
--    NUI callback while the current one is still yielding.
-- 2. A nil payload is sent as `false`. cb(nil) sends no response body at all,
--    leaving the page's fetch pending forever.
if not IsDuplicityVersion() and type(RegisterNUICallback) == 'function' then
    local _registerNUI = RegisterNUICallback

    RegisterNUICallback = function(name, handler)
        return _registerNUI(name, function(data, cb)
            CreateThread(function()
                handler(data, function(payload, ...)
                    if payload == nil then payload = false end
                    cb(payload, ...)
                end)
            end)
        end)
    end
end

-- ─────────────────────────────────────────────────────────────
-- Framework bridge
-- Auto-detects QBox (qbx_core) or QBCore (qb-core) and exposes ONE API
-- so the rest of the resource never branches on framework. ox_lib and
-- oxmysql are used directly elsewhere since both frameworks ship with them.
--
-- If a function behaves differently on your build, this file is the only
-- place you need to touch.
-- ─────────────────────────────────────────────────────────────
Framework = { name = nil, core = nil }

if GetResourceState('qbx_core') == 'started' then
    Framework.name = 'qbox'
elseif GetResourceState('qb-core') == 'started' then
    Framework.name = 'qbcore'
    Framework.core = exports['qb-core']:GetCoreObject()
else
    -- Defer the error so the resource still loads its UI; log loudly.
    print('^1[XS-CriminalTablet]^0 No supported framework found. Start qbx_core or qb-core before XS-CriminalTablet.')
end

local IS_SERVER = IsDuplicityVersion()

-- ── Player lookups ──────────────────────────────────────────
if IS_SERVER then
    -- Returns the framework player object for a server id, or nil.
    function Framework.GetPlayer(src)
        if Framework.name == 'qbox' then
            return exports.qbx_core:GetPlayer(src)
        else
            return Framework.core.Functions.GetPlayer(src)
        end
    end

    -- Returns the stable character identifier (citizenid) for a source.
    function Framework.GetCitizenId(src)
        local player = Framework.GetPlayer(src)
        return player and player.PlayerData.citizenid or nil
    end

    -- Returns { firstname, lastname } for a source.
    function Framework.GetName(src)
        local player = Framework.GetPlayer(src)
        if not player then return nil end
        local ci = player.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname, ci.lastname)
    end

    -- Same, but for a citizenid that may be offline (DB lookup). Both
    -- qbx_core and qb-core store charinfo as JSON on the `players` table.
    function Framework.GetNameByCitizenId(citizenid)
        local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        if not row or not row.charinfo then return nil end
        local ci = type(row.charinfo) == 'string' and json.decode(row.charinfo) or row.charinfo
        if not ci or not ci.firstname then return nil end
        return ('%s %s'):format(ci.firstname, ci.lastname)
    end

    -- A typed citizenid as the framework actually stored it, or nil. MySQL
    -- ignores case here, so "abc12345" finds "ABC12345" in the database but
    -- never matches the player in Lua. Save what this returns, not the input.
    function Framework.ResolveCitizenId(citizenid)
        local typed = tostring(citizenid or ''):gsub('%s', '')
        if typed == '' then return nil end
        local row = MySQL.single.await('SELECT citizenid FROM players WHERE citizenid = ?', { typed })
        return row and row.citizenid or nil
    end

    -- The framework's own gang list as { name, label, grades = { [level] = name } }.
    function Framework.GetGangs()
        local raw
        if Framework.name == 'qbox' then
            local ok, gangs = pcall(function() return exports.qbx_core:GetGangs() end)
            raw = ok and gangs or nil
        elseif Framework.core and Framework.core.Shared then
            raw = Framework.core.Shared.Gangs
        end
        local out = {}
        for name, g in pairs(type(raw) == 'table' and raw or {}) do
            if name ~= 'none' then
                local grades = {}
                for level, grade in pairs(g.grades or {}) do grades[tonumber(level) or level] = grade.name or tostring(level) end
                out[#out + 1] = { name = name, label = g.label or name, grades = grades }
            end
        end
        table.sort(out, function(a, b) return a.label < b.label end)
        return out
    end

    -- Put an online player in a framework gang ('none' takes them out).
    -- Offline players can only be changed on QBox.
    function Framework.SetGang(src, citizenid, name, grade)
        local player = src and Framework.GetPlayer(src)
        if player and player.Functions and player.Functions.SetGang then
            return pcall(player.Functions.SetGang, name, grade or 0)
        end
        if Framework.name == 'qbox' and citizenid then
            return pcall(function()
                if name == 'none' then
                    local row = MySQL.single.await('SELECT gang FROM players WHERE citizenid = ?', { citizenid })
                    local g = row and (type(row.gang) == 'string' and json.decode(row.gang) or row.gang)
                    if g and g.name and g.name ~= 'none' then exports.qbx_core:RemovePlayerFromGang(citizenid, g.name) end
                else
                    exports.qbx_core:AddPlayerToGang(citizenid, name, grade or 0)
                end
            end)
        end
        return false
    end

    -- Money: account is 'cash' | 'bank'. Both frameworks share this API
    -- surface via the player object's Functions table.
    function Framework.AddMoney(src, account, amount, reason)
        local player = Framework.GetPlayer(src)
        if not player then return false end
        return player.Functions.AddMoney(account, amount, reason or 'xs-criminaltablet')
    end

    function Framework.RemoveMoney(src, account, amount, reason)
        local player = Framework.GetPlayer(src)
        if not player then return false end
        return player.Functions.RemoveMoney(account, amount, reason or 'xs-criminaltablet')
    end

    function Framework.GetMoney(src, account)
        local player = Framework.GetPlayer(src)
        if not player then return 0 end
        return player.PlayerData.money[account] or 0
    end

    -- Server-side notify (wraps ox_lib so the UI/notify look is uniform).
    function Framework.Notify(src, msg, type)
        if not src then return end
        TriggerClientEvent('ox_lib:notify', src, { description = msg, type = type or 'inform' })
    end
else
    -- ── Client ──────────────────────────────────────────────
    function Framework.GetPlayerData()
        if Framework.name == 'qbox' then
            return exports.qbx_core:GetPlayerData()
        else
            return Framework.core.Functions.GetPlayerData()
        end
    end

    function Framework.Notify(msg, type)
        lib.notify({ description = msg, type = type or 'inform' })
    end
end

if Config and Config.Debug then
    print(('^2[XS-CriminalTablet]^0 bridge loaded (%s) on %s'):format(
        Framework.name or 'none', IS_SERVER and 'server' or 'client'))
end
