-- ─────────────────────────────────────────────────────────────
-- Live settings, server side. config.lua stays the default; anything
-- staff change in the builder is stored as an override and wins over it.
-- ─────────────────────────────────────────────────────────────
Settings.defaults = {}
Settings.overrides = {}
Settings.boot = {}

local function snapshot()
    if Settings.snapped then return end
    for _, def in ipairs(Settings.fields) do Settings.defaults[def.key] = Settings.Copy(Settings.Read(def.key)) end
    Settings.snapped = true
end

local function applyAll()
    for _, def in ipairs(Settings.fields) do
        local value = Settings.overrides[def.key]
        if value == nil then value = Settings.defaults[def.key] end
        Settings.Write(def.key, Settings.Copy(value))
    end
end

function Settings.Values()
    local out = {}
    for _, def in ipairs(Settings.fields) do out[def.key] = Settings.Read(def.key) end
    return out
end

local function broadcast(target)
    TriggerClientEvent('XS-CriminalTablet:client:settings', target or -1, Settings.Values())
end

function Settings.Load()
    snapshot()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `xs_tablet_settings` (
            `name` VARCHAR(32) NOT NULL,
            `data` LONGTEXT    NOT NULL,
            PRIMARY KEY (`name`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    local row = MySQL.single.await('SELECT `data` FROM `xs_tablet_settings` WHERE `name` = ?', { 'config' })
    local ok, raw = pcall(json.decode, row and row.data or '{}')
    Settings.overrides = {}
    for key, value in pairs(ok and type(raw) == 'table' and raw or {}) do
        local def = Settings.byKey[key]
        if def then
            local clean = Settings.Clean(def, value)
            if clean ~= nil and not Settings.Same(clean, Settings.defaults[key]) then Settings.overrides[key] = clean end
        end
    end
    applyAll()
    for _, def in ipairs(Settings.fields) do
        if def.restart then Settings.boot[def.key] = Settings.Copy(Settings.Read(def.key)) end
    end
    Settings.loaded = true
    broadcast()
end

function Settings.Save(changes, resets)
    for key, value in pairs(type(changes) == 'table' and changes or {}) do
        local def = Settings.byKey[key]
        if def then
            local clean = Settings.Clean(def, value)
            if clean ~= nil then
                if Settings.Same(clean, Settings.defaults[key]) then Settings.overrides[key] = nil else Settings.overrides[key] = clean end
            end
        end
    end
    for _, key in ipairs(type(resets) == 'table' and resets or {}) do
        if Settings.byKey[key] then Settings.overrides[key] = nil end
    end
    MySQL.query.await('INSERT INTO `xs_tablet_settings` (`name`, `data`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `data` = VALUES(`data`)',
        { 'config', json.encode(Settings.overrides) })
    applyAll()
    broadcast()
    return Settings.Values()
end

local function itemList()
    local out = {}
    if GetResourceState('ox_inventory') == 'started' then
        local ok, items = pcall(function() return exports.ox_inventory:Items() end)
        if ok and type(items) == 'table' then
            local path = GetConvar('inventory:imagepath', 'nui://ox_inventory/web/images')
            for name, it in pairs(items) do
                local custom = type(it.client) == 'table' and it.client.image
                local image = type(custom) == 'string' and custom:find('://', 1, true) and custom or ('%s/%s.png'):format(path, it.name or name)
                out[#out + 1] = { name = name, label = it.label or name, image = image }
            end
        end
    elseif Framework.core and Framework.core.Shared and Framework.core.Shared.Items then
        for name, it in pairs(Framework.core.Shared.Items) do
            out[#out + 1] = { name = name, label = it.label or name, image = it.image and ('nui://qb-inventory/html/images/' .. it.image) or nil }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

Settings.Items = itemList

function Settings.Builder()
    local radialIcons = {}
    for id, a in pairs(Config.Radial.actions) do radialIcons[id] = a.icon end
    return {
        radialIcons = radialIcons,
        sections = Settings.Public(), values = Settings.Values(), defaults = Settings.defaults, boot = Settings.boot,
        perms = XSTablet.PermissionGroups, items = itemList(),
    }
end

CreateThread(function()
    local ok, err = pcall(Settings.Load)
    if not ok then print('^1[XS-CriminalTablet]^0 settings could not load, using config.lua: ' .. tostring(err)) end
end)

lib.callback.register('XS-CriminalTablet:settings:values', function()
    return Settings.Values()
end)

lib.callback.register('XS-CriminalTablet:admin:settings', function(src)
    if not IsPlayerAceAllowed(src, Config.AdminAce) then return { ok = false, error = 'not authorized' } end
    return { ok = true, data = Settings.Builder() }
end)

lib.callback.register('XS-CriminalTablet:admin:saveSettings', function(src, changes, resets)
    if not IsPlayerAceAllowed(src, Config.AdminAce) then return { ok = false, error = 'not authorized' } end
    local values = Settings.Save(changes, resets)
    local count = 0
    for _ in pairs(Settings.overrides) do count = count + 1 end
    print(('^2[XS-CriminalTablet]^0 %s saved the settings (%d changed from config.lua).'):format(GetPlayerName(src) or src, count))
    return { ok = true, data = { values = values, boot = Settings.boot } }
end)
