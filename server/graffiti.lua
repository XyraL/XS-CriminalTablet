-- ─────────────────────────────────────────────────────────────
-- Gang graffiti.
--
-- Art comes in four shapes, and where each one is allowed to come from
-- is the whole security model here:
--   preset:<id>  — a built-in catalogue design, drawn client-side
--   text:<json>  — a studio text composition (font, colours, outline)
--   draw:<data>  — a studio freehand drawing, stored as a data URL
--   url:<link>   — a custom image. ADMIN-ADDED ONLY. Members can spray
--                  whatever their gang has been given, but they can never
--                  introduce an arbitrary remote URL themselves, because
--                  that URL loads inside every nearby player's game.
--
-- Anything a member composes (text/draw) is generated in their own studio
-- and capped in size, so it can't be used to point the client at a third
-- party. Everything else has to already exist in the gang's library.
-- ─────────────────────────────────────────────────────────────
Graffiti = {}

local tags = {}       -- cached world tags

local MAX_ART_BYTES = 160000    -- roughly a 512x512 PNG data URL
local MAX_TEXT_BYTES = 2000

local function now() return os.time() * 1000 end

local function loadTags()
    tags = MySQL.query.await(
        'SELECT id, gang_id, art, x, y, z, rx, ry, rz, scale, tint, sprayed_name, created_at FROM xs_gang_graffiti') or {}
    -- Attach the owning gang's colour so clients can tint a tag without
    -- needing the whole gang table.
    for _, t in ipairs(tags) do
        local gang = Gangs.Get(t.gang_id)
        t.gangLabel = gang and gang.label or '?'
        t.gangColor = gang and gang.color or '#f5a524'
    end
end

function Graffiti.GetAll() return tags end

local function broadcast()
    TriggerClientEvent('XS-CriminalTablet:client:graffitiUpdate', -1, tags)
end

-- ── art validation ──────────────────────────────────────────
local function catalogueEntry(artId)
    for _, c in ipairs(Config.Graffiti.catalogue) do
        if c.id == artId then return c end
    end
    return nil
end

local function gangOwnsArt(gangId, artId)
    return MySQL.single.await('SELECT id, art, label FROM xs_gang_art WHERE id = ? AND gang_id = ?',
        { tonumber(artId), gangId })
end

-- Turn whatever the UI sent into a stored art string, or refuse it.
-- Returns art, artId, error.
local function resolveArt(gang, payload)
    payload = payload or {}
    local kind = tostring(payload.kind or '')

    if kind == 'library' then
        local row = gangOwnsArt(gang.id, payload.artId)
        if not row then return nil, nil, 'that art is not in your crew library' end
        return row.art, row.id, nil
    end

    if kind == 'catalogue' then
        local entry = catalogueEntry(payload.artId)
        if not entry then return nil, nil, 'unknown catalogue design' end
        return entry.art, nil, nil
    end

    if kind == 'text' then
        local function clamp(v, lo, hi, fallback)
            local n = tonumber(v)
            if not n then return fallback end
            return math.max(lo, math.min(hi, math.floor(n)))
        end
        local function oneOf(v, allowed, fallback)
            v = tostring(v or '')
            for _, a in ipairs(allowed) do if v == a then return v end end
            return fallback
        end

        local encoded = json.encode({
            text = tostring(payload.text or ''):sub(1, 24),
            font = tostring(payload.font or 'marker'):sub(1, 16),
            fill = tostring(payload.fill or '#ffffff'):sub(1, 9),
            outline = tostring(payload.outline or '#000000'):sub(1, 9),
            stroke = clamp(payload.stroke, 0, 20, 8),
            spacing = clamp(payload.spacing, -10, 24, 0),
            skew = clamp(payload.skew, -25, 25, 0),
            rotate = clamp(payload.rotate, -20, 20, 0),
            textCase = oneOf(payload.textCase, { 'as', 'upper', 'lower' }, 'as'),
            glow = oneOf(payload.glow, { 'none', 'soft', 'neon', 'hard' }, 'none'),
        })
        if #encoded > MAX_TEXT_BYTES then return nil, nil, 'text is too long' end
        if (payload.text or '') == '' then return nil, nil, 'type something first' end
        return 'text:' .. encoded, nil, nil
    end

    if kind == 'draw' then
        local data = tostring(payload.data or '')
        if not data:match('^data:image/png;base64,') then return nil, nil, 'bad drawing data' end
        if #data > MAX_ART_BYTES then return nil, nil, 'drawing is too large — simplify it' end
        return 'draw:' .. data, nil, nil
    end

    return nil, nil, 'pick something to spray'
end

-- ── library ─────────────────────────────────────────────────
function Graffiti.GetLibrary(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return { catalogue = {}, library = {} } end

    local library = MySQL.query.await(
        'SELECT id, label, art, source, created_at FROM xs_gang_art WHERE gang_id = ? ORDER BY id DESC',
        { gang.id }) or {}

    local mine = {}
    for _, t in ipairs(tags) do
        if t.gang_id == gang.id then mine[#mine + 1] = t end
    end

    return {
        catalogue = Config.Graffiti.catalogue,
        library = library,
        fonts = Config.Graffiti.fonts,
        tags = mine,
        maxPerGang = Config.Graffiti.maxPerGang,
        color = gang.color,
        canSpray = Gangs.HasPerm(src, 'spray_graffiti'),
        canManage = Gangs.HasPerm(src, 'manage_graffiti'),
        minScale = Config.Graffiti.minScale,
        maxScale = Config.Graffiti.maxScale,
        requiredItem = Config.Graffiti.requiredItem,
    }
end

-- Members can save their own studio compositions into the gang library —
-- but only text/drawings, never a URL (see the header).
function Graffiti.SaveStudioArt(src, label, payload)
    if not Gangs.HasPerm(src, 'spray_graffiti') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local kind = tostring((payload or {}).kind or '')
    if kind ~= 'text' and kind ~= 'draw' then
        return false, 'only your own text or drawings can be saved — ask staff for custom images'
    end

    local art, _, err = resolveArt(gang, payload)
    if not art then return false, err end

    local count = MySQL.scalar.await('SELECT COUNT(*) FROM xs_gang_art WHERE gang_id = ?', { gang.id }) or 0
    if count >= 40 then return false, 'your crew library is full — clear something out' end

    local id = MySQL.insert.await(
        'INSERT INTO xs_gang_art (gang_id, label, art, source, added_by) VALUES (?, ?, ?, ?, ?)',
        { gang.id, tostring(label or 'Untitled'):sub(1, 64), art, 'studio', Framework.GetCitizenId(src) or '' })

    Gangs.Log(gang.id, ('%s added art to the crew library'):format(Framework.GetName(src) or 'Someone'), 'graffiti')
    Gangs.Broadcast(gang.id, 'graffiti', {})
    return true, id
end

function Graffiti.DeleteArt(src, artId)
    if not Gangs.HasPerm(src, 'manage_graffiti') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local row = gangOwnsArt(gang.id, artId)
    if not row then return false, 'not in your library' end
    -- Staff-issued art is the gang's to use, not to throw away.
    local source = MySQL.scalar.await('SELECT source FROM xs_gang_art WHERE id = ?', { tonumber(artId) })
    if source == 'admin' then return false, 'staff added that one — only staff can remove it' end

    MySQL.update('DELETE FROM xs_gang_art WHERE id = ?', { tonumber(artId) })
    Gangs.Broadcast(gang.id, 'graffiti', {})
    return true
end

-- ── spraying ────────────────────────────────────────────────
function Graffiti.Spray(src, payload)
    if not Config.Graffiti.enabled then return false, 'graffiti is disabled' end
    if not Gangs.HasPerm(src, 'spray_graffiti') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    payload = payload or {}
    local coords = payload.coords
    if type(coords) ~= 'table' or not coords.x then return false, 'bad position' end
    coords = vec3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)

    -- The wall has to be in front of the player who claims to be painting it.
    local pos = GetEntityCoords(GetPlayerPed(src))
    if #(pos - coords) > 4.0 then return false, 'too far from the wall' end

    if Config.Graffiti.heldZonesOnly and not Territory.IsWithinHeldZone(gang.id, coords) then
        return false, 'you can only tag turf your crew holds'
    end

    local art, artId, err = resolveArt(gang, payload)
    if not art then return false, err end

    if Config.Graffiti.requiredItem and Config.Graffiti.requiredItem ~= '' then
        local count = exports.ox_inventory:GetItemCount(src, Config.Graffiti.requiredItem)
        if (count or 0) < 1 then return false, ('you need a %s'):format(Config.Graffiti.requiredItem) end
    end

    -- Covering: spraying over a rival's tag removes it and pays more.
    local covered = nil
    if Config.Graffiti.allowCovering then
        for _, t in ipairs(tags) do
            if t.gang_id ~= gang.id and #(coords - vec3(t.x, t.y, t.z)) <= Config.Graffiti.coverRadius then
                covered = t
                break
            end
        end
    end

    if #tags >= Config.Graffiti.maxTotal and not covered then
        -- World is full: drop the oldest tag anywhere rather than refusing.
        local oldest = MySQL.single.await('SELECT id FROM xs_gang_graffiti ORDER BY id ASC LIMIT 1')
        if oldest then MySQL.update('DELETE FROM xs_gang_graffiti WHERE id = ?', { oldest.id }) end
    end

    local mineCount = 0
    for _, t in ipairs(tags) do if t.gang_id == gang.id then mineCount = mineCount + 1 end end
    if mineCount >= Config.Graffiti.maxPerGang then
        local oldest = MySQL.single.await(
            'SELECT id FROM xs_gang_graffiti WHERE gang_id = ? ORDER BY id ASC LIMIT 1', { gang.id })
        if oldest then MySQL.update('DELETE FROM xs_gang_graffiti WHERE id = ?', { oldest.id }) end
    end

    if covered then
        MySQL.update('DELETE FROM xs_gang_graffiti WHERE id = ?', { covered.id })
        Gangs.NotifyGang(covered.gang_id, ('%s painted over one of your tags.'):format(gang.label), 'error')
        Gangs.Log(covered.gang_id, ('%s covered one of our tags'):format(gang.label), 'graffiti')
    end

    if Config.Graffiti.requiredItem and Config.Graffiti.requiredItem ~= '' and Config.Graffiti.consumeItem then
        exports.ox_inventory:RemoveItem(src, Config.Graffiti.requiredItem, 1)
    end

    local scale = math.max(Config.Graffiti.minScale,
        math.min(Config.Graffiti.maxScale, tonumber(payload.scale) or 1.0))
    local tint = tostring(payload.tint or ''):sub(1, 9)

    MySQL.insert.await(
        'INSERT INTO xs_gang_graffiti (gang_id, art_id, art, x, y, z, rx, ry, rz, scale, tint, sprayed_by, sprayed_name) ' ..
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { gang.id, artId, art, coords.x, coords.y, coords.z,
          tonumber(payload.rx) or 0.0, tonumber(payload.ry) or 0.0, tonumber(payload.rz) or 0.0,
          scale, tint, Framework.GetCitizenId(src) or '', Framework.GetName(src) or '' })

    loadTags()
    broadcast()

    local reward = covered and Config.Rep.rewards.graffiti_covered or Config.Rep.rewards.graffiti_sprayed
    Gangs.AddMemberRep(Framework.GetCitizenId(src), reward, 'graffiti')
    Gangs.Log(gang.id, ('%s put up a tag%s'):format(
        Framework.GetName(src) or 'Someone', covered and (' over ' .. (covered.gangLabel or 'a rival')) or ''), 'graffiti')
    return true
end

-- Remove one of your own gang's tags (or any tag, for staff).
function Graffiti.Remove(src, tagId)
    local gang = Gangs.GetBySource(src)
    local isAdmin = IsPlayerAceAllowed(src, Config.AdminAce)
    if not gang and not isAdmin then return false, 'no gang' end

    local row = MySQL.single.await('SELECT id, gang_id FROM xs_gang_graffiti WHERE id = ?', { tonumber(tagId) })
    if not row then return false, 'unknown tag' end

    if not isAdmin then
        if row.gang_id ~= gang.id then return false, 'not your tag' end
        if not Gangs.HasPerm(src, 'manage_graffiti') then return false, 'no permission' end
    end

    MySQL.update('DELETE FROM xs_gang_graffiti WHERE id = ?', { row.id })
    loadTags()
    broadcast()
    return true
end

-- ── admin ───────────────────────────────────────────────────
-- Staff are the only ones who can put a remote image URL into a gang's
-- library, which is what makes "custom images" safe to offer at all.
function Graffiti.AdminAddArt(gangId, label, art, kind)
    local gang = Gangs.Get(tonumber(gangId))
    if not gang then return false, 'unknown gang' end

    art = tostring(art or '')
    kind = tostring(kind or 'url')

    if kind == 'url' then
        if not art:match('^https?://') then return false, 'that has to be a direct http(s) image link' end
        if #art > 500 then return false, 'link is too long' end
        art = 'url:' .. art
    elseif kind == 'preset' then
        if not catalogueEntry(art) then return false, 'unknown catalogue design' end
        art = (catalogueEntry(art)).art
    else
        return false, 'unknown art kind'
    end

    local id = MySQL.insert.await(
        'INSERT INTO xs_gang_art (gang_id, label, art, source, added_by) VALUES (?, ?, ?, ?, ?)',
        { gang.id, tostring(label or 'Custom'):sub(1, 64), art, 'admin', 'admin' })

    Gangs.Log(gang.id, ('Staff added "%s" to the crew graffiti library'):format(label or 'Custom'), 'graffiti')
    Gangs.NotifyGang(gang.id, 'New graffiti was added to your crew library.', 'success')
    Gangs.Broadcast(gang.id, 'graffiti', {})
    return true, id
end

function Graffiti.AdminListArt(gangId)
    return MySQL.query.await(
        'SELECT id, label, art, source, created_at FROM xs_gang_art WHERE gang_id = ? ORDER BY id DESC',
        { tonumber(gangId) }) or {}
end

function Graffiti.AdminDeleteArt(artId)
    local row = MySQL.single.await('SELECT gang_id, label FROM xs_gang_art WHERE id = ?', { tonumber(artId) })
    if not row then return false, 'unknown art' end
    MySQL.update('DELETE FROM xs_gang_art WHERE id = ?', { tonumber(artId) })
    Gangs.Broadcast(row.gang_id, 'graffiti', {})
    return true
end

function Graffiti.AdminListTags(limit)
    return MySQL.query.await(
        'SELECT g.id, g.gang_id, g.x, g.y, g.z, g.sprayed_name, g.created_at, gg.label AS gang_label ' ..
        'FROM xs_gang_graffiti g LEFT JOIN xs_gangs gg ON gg.id = g.gang_id ORDER BY g.id DESC LIMIT ?',
        { tonumber(limit) or 50 }) or {}
end

function Graffiti.AdminWipeGang(gangId)
    MySQL.update('DELETE FROM xs_gang_graffiti WHERE gang_id = ?', { tonumber(gangId) })
    loadTags()
    broadcast()
    return true
end

-- ── lifecycle ───────────────────────────────────────────────
CreateThread(function()
    Wait(3000)
    loadTags()

    if (Config.Graffiti.expiryDays or 0) > 0 then
        local cutoffMs = Config.Graffiti.expiryDays * 86400000
        while true do
            local cutoff = os.date('%Y-%m-%d %H:%M:%S', math.floor((now() - cutoffMs) / 1000))
            MySQL.update('DELETE FROM xs_gang_graffiti WHERE created_at < ?', { cutoff })
            loadTags()
            broadcast()
            Wait(3600000)
        end
    end
end)

lib.callback.register('XS-CriminalTablet:graffiti:getAll', function()
    return Graffiti.GetAll()
end)

lib.callback.register('XS-CriminalTablet:graffiti:getLibrary', function(src)
    return Graffiti.GetLibrary(src)
end)

lib.callback.register('XS-CriminalTablet:graffiti:spray', function(src, payload)
    local ok, err = Graffiti.Spray(src, payload)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:graffiti:saveArt', function(src, label, payload)
    local ok, res = Graffiti.SaveStudioArt(src, label, payload)
    return { ok = ok, error = not ok and res or nil, id = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:graffiti:deleteArt', function(src, artId)
    local ok, err = Graffiti.DeleteArt(src, artId)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:graffiti:remove', function(src, tagId)
    local ok, err = Graffiti.Remove(src, tagId)
    return { ok = ok, error = err }
end)
