-- One-shot repair for coordinates saved through the old, miscalibrated map.
--
-- Anything created by CLICKING the map editor was stored through a world
-- rectangle that was the wrong shape, so those rows sit up to 300m from where
-- the click actually landed. Correcting the rectangle fixed how coordinates are
-- drawn; it could not fix rows already written. This rewrites them.
--
-- Rows that came from a real in-game position -- props the crew placed
-- themselves, graffiti, vehicles, zones walked out with the in-world creator --
-- were always correct and are left alone.
--
-- Server console only:
--   xsmapfix                 report what would change, touch nothing
--   xsmapfix apply           fix blips, staff placements and map-drawn zones
--   xsmapfix apply all       treat every zone as map-drawn
--   xsmapfix apply none      skip zones entirely
--   xsmapfix apply rancho,grove   only these zones
--
-- Safe to delete once every server has run it.

local MIGRATION = 'map-calibration-2026-09'

-- The rectangle the render was WRONGLY believed to cover, and the one it
-- actually covers. Going through pixels is what makes this correct: a stored
-- coordinate is whatever the old rectangle turned the click into, so map it
-- back to that pixel and forward through the real rectangle.
local OLD = { minX = -4508, maxX = 5086, minY = -4891, maxY = 8317 }
local NEW = { minX = -4140, maxX = 4860, minY = -5100, maxY = 8400 }

local function fixX(x)
    return NEW.minX + (x - OLD.minX) * ((NEW.maxX - NEW.minX) / (OLD.maxX - OLD.minX))
end

local function fixY(y)
    return NEW.maxY - (OLD.maxY - y) * ((NEW.maxY - NEW.minY) / (OLD.maxY - OLD.minY))
end

local function drift(x, y)
    local dx, dy = fixX(x) - x, fixY(y) - y
    return math.sqrt(dx * dx + dy * dy)
end

local function ensureMarkerTable()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `xs_migrations` (
            `id`         VARCHAR(64) NOT NULL,
            `applied_at` BIGINT      NOT NULL,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

local function alreadyApplied()
    return MySQL.scalar.await('SELECT applied_at FROM xs_migrations WHERE id = ?', { MIGRATION })
end

-- The map editor's height box is a whole-number input and its "height from
-- where I'm stood" button rounds, so a zone drawn on the map lands with an
-- integer coord_z. The in-world creator averages the ped's Z as it walks, so a
-- walked zone is virtually always fractional. Good enough to propose a list,
-- not good enough to act on without the admin looking at it.
local function looksMapDrawn(row)
    local z = tonumber(row.coord_z)
    if not z then return true end
    return math.abs(z - math.floor(z + 0.5)) < 0.0001
end

local function parseZoneArg(arg, rows)
    if arg == 'none' then return {} end

    local wanted = {}
    if arg == nil or arg == 'auto' then
        for _, r in ipairs(rows) do
            if looksMapDrawn(r) then wanted[r.zone] = true end
        end
    elseif arg == 'all' then
        for _, r in ipairs(rows) do wanted[r.zone] = true end
    else
        for name in string.gmatch(arg, '[^,]+') do
            wanted[(name:gsub('^%s*(.-)%s*$', '%1'))] = true
        end
    end
    return wanted
end

local function zoneRows()
    return MySQL.query.await('SELECT zone, label, points, coord_x, coord_y, coord_z FROM xs_territories') or {}
end

local function report(zoneArg)
    local zones = zoneRows()
    local wanted = parseZoneArg(zoneArg, zones)

    local blips = MySQL.query.await('SELECT id, label, x, y FROM xs_gang_blips') or {}
    local places = MySQL.query.await(
        "SELECT gang_id, kind, label, x, y FROM xs_gang_placements WHERE placed_by = 'staff'") or {}

    print('[XS-CriminalTablet] map calibration repair -- DRY RUN, nothing written')
    print(('  crew blips           %d row(s)'):format(#blips))
    print(('  staff placements     %d row(s)'):format(#places))

    local worst = 0.0
    for _, b in ipairs(blips) do worst = math.max(worst, drift(b.x, b.y)) end
    for _, p in ipairs(places) do worst = math.max(worst, drift(p.x, p.y)) end

    print('  zones:')
    local picked = 0
    for _, z in ipairs(zones) do
        local n = 0
        if z.points then
            local ok, pts = pcall(json.decode, z.points)
            if ok and type(pts) == 'table' then n = #pts end
        end
        local take = wanted[z.zone] == true
        if take then
            picked = picked + 1
            if z.coord_x then worst = math.max(worst, drift(z.coord_x, z.coord_y)) end
        end
        print(('    %-5s %-22s z=%-9s %2d corner(s)  %s'):format(
            take and 'FIX' or 'skip',
            z.zone,
            z.coord_z and ('%.2f'):format(z.coord_z) or '?',
            n,
            looksMapDrawn(z) and 'looks map-drawn' or 'looks walked in-world'))
    end

    print(('  %d zone(s) selected. Worst correction in this set: %.0fm'):format(picked, worst))
    if alreadyApplied() then
        print('  NOTE: this migration has already been applied once. Running it again would')
        print('        move everything a second time. Only re-run with a fresh backup.')
    end
    print('  Back up your database, then run: xsmapfix apply')
end

local function apply(zoneArg)
    if alreadyApplied() and zoneArg ~= 'force' then
        print('[XS-CriminalTablet] already applied on ' .. tostring(alreadyApplied()) .. '.')
        print('  Re-running would shift everything a second time. If you are certain,')
        print('  restore a backup first or delete the row from xs_migrations.')
        return
    end

    local blips = MySQL.query.await('SELECT id, x, y FROM xs_gang_blips') or {}
    for _, b in ipairs(blips) do
        MySQL.update.await('UPDATE xs_gang_blips SET x = ?, y = ? WHERE id = ?',
            { fixX(b.x), fixY(b.y), b.id })
    end

    -- Placeables.Place stamps the placer's citizenid and validates against the
    -- player's real position, so only the literal 'staff' rows came off a map
    -- click.
    local places = MySQL.query.await(
        "SELECT id, x, y FROM xs_gang_placements WHERE placed_by = 'staff'") or {}
    for _, p in ipairs(places) do
        MySQL.update.await('UPDATE xs_gang_placements SET x = ?, y = ? WHERE id = ?',
            { fixX(p.x), fixY(p.y), p.id })
    end

    local zones = zoneRows()
    local wanted = parseZoneArg(zoneArg, zones)
    local zoneCount = 0
    for _, z in ipairs(zones) do
        if wanted[z.zone] then
            local pts = nil
            if z.points then
                local ok, decoded = pcall(json.decode, z.points)
                if ok and type(decoded) == 'table' then pts = decoded end
            end

            -- The centroid has to be rebuilt from the corrected corners, not
            -- corrected on its own, or the blip drifts off its own polygon.
            local cx, cy = z.coord_x, z.coord_y
            if pts and #pts > 0 then
                local sx, sy = 0.0, 0.0
                for _, p in ipairs(pts) do
                    p.x, p.y = fixX(p.x), fixY(p.y)
                    sx, sy = sx + p.x, sy + p.y
                end
                cx, cy = sx / #pts, sy / #pts
                MySQL.update.await(
                    'UPDATE xs_territories SET points = ?, coord_x = ?, coord_y = ? WHERE zone = ?',
                    { json.encode(pts), cx, cy, z.zone })
            elseif cx and cy then
                MySQL.update.await('UPDATE xs_territories SET coord_x = ?, coord_y = ? WHERE zone = ?',
                    { fixX(cx), fixY(cy), z.zone })
            end
            zoneCount = zoneCount + 1
        end
    end

    MySQL.insert.await(
        'INSERT INTO xs_migrations (id, applied_at) VALUES (?, ?) ON DUPLICATE KEY UPDATE applied_at = VALUES(applied_at)',
        { MIGRATION, os.time() * 1000 })

    print('[XS-CriminalTablet] map calibration repair applied')
    print(('  %d blip(s), %d staff placement(s), %d zone(s)'):format(#blips, #places, zoneCount))
    print('  Restart the resource so the cached copies reload.')
end

RegisterCommand('xsmapfix', function(src, args)
    if src ~= 0 then return end
    ensureMarkerTable()
    if args[1] == 'apply' then
        apply(args[2])
    else
        report(args[1])
    end
end, true)
