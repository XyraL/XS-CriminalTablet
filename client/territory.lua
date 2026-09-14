-- ─────────────────────────────────────────────────────────────
-- Territory client: gang-coloured zone blips, the contest HUD, and the
-- optional barrier walls along a held zone's edge.
--
-- Zones are polygons. Blips are still radius blips (GTA has no polygon
-- blip) sized to the polygon's own footprint, so the map reads roughly
-- right while the actual in/out test stays the real shape, server-side.
-- ─────────────────────────────────────────────────────────────
local blips = {}
local wallProps = {}
local contests = {}
Territories = {}        -- shared read-only snapshot for other client files

local myGangId = nil
local lastSignature = nil

-- ── colour helpers ──────────────────────────────────────────
local function hexToRgb(hex)
    if type(hex) ~= 'string' then return 245, 165, 36 end
    hex = hex:gsub('#', '')
    if #hex ~= 6 then return 245, 165, 36 end
    return tonumber(hex:sub(1, 2), 16) or 245,
           tonumber(hex:sub(3, 4), 16) or 165,
           tonumber(hex:sub(5, 6), 16) or 36
end

-- Radius of the circle blip that best stands in for a polygon: the
-- furthest corner from its centre.
local function footprintRadius(t)
    if not t.points or #t.points < 3 then return t.radius or Config.Territory.defaultRadius end
    local cx = t.center and t.center.x or t.coords.x
    local cy = t.center and t.center.y or t.coords.y
    local far = 0.0
    for _, p in ipairs(t.points) do
        local d = #(vec2(p.x, p.y) - vec2(cx, cy))
        if d > far then far = d end
    end
    return math.max(15.0, far)
end

-- ── blips + walls ───────────────────────────────────────────
local function clearWalls()
    for _, obj in ipairs(wallProps) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
    wallProps = {}
end

-- Walk the polygon perimeter dropping props at a fixed spacing. Purely
-- decorative cover — they never block anyone from entering.
local function buildWalls(t)
    local cfg = Config.Territory.walls
    if not cfg.enabled or not t.points or #t.points < 3 then return end
    if not IsModelValid(cfg.model) then return end
    lib.requestModel(cfg.model)

    local placed = 0
    for i = 1, #t.points do
        if placed >= cfg.maxProps then break end
        local a = t.points[i]
        local b = t.points[(i % #t.points) + 1]
        local seg = vec2(b.x - a.x, b.y - a.y)
        local len = #seg
        local steps = math.max(1, math.floor(len / cfg.spacing))
        local heading = math.deg(math.atan(seg.y, seg.x))

        for s = 0, steps - 1 do
            if placed >= cfg.maxProps then break end
            local frac = s / steps
            local x = a.x + (b.x - a.x) * frac
            local y = a.y + (b.y - a.y) * frac
            local found, z = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, (t.coords and t.coords.z or 30.0) + 10.0, false)
            local obj = CreateObject(cfg.model, x, y, (found and z or (t.coords and t.coords.z or 30.0)), false, false, false)
            SetEntityHeading(obj, heading)
            FreezeEntityPosition(obj, true)
            wallProps[#wallProps + 1] = obj
            placed = placed + 1
        end
    end
end

local function refresh(list)
    list = list or {}
    Territories = list

    -- Only redraw when something actually changed — the server pushes
    -- this on every influence tick.
    local sig = {}
    for _, t in ipairs(list) do
        sig[#sig + 1] = ('%s:%s:%s:%s'):format(t.zone, t.holderId or '', t.holderColor or '', t.points and #t.points or 0)
    end
    sig = table.concat(sig, '|') .. '|' .. tostring(myGangId)
    if sig == lastSignature then return end
    lastSignature = sig

    for _, b in pairs(blips) do RemoveBlip(b) end
    blips = {}
    clearWalls()

    -- Walls still go up on your own turf when they're enabled: that is a
    -- thing you built, not a readout of everyone else's holdings.
    if not Config.Territory.worldBlips then
        for _, t in ipairs(list) do
            if t.holderId and t.holderId == myGangId then buildWalls(t) end
        end
        TriggerEvent('XS-CriminalTablet:client:territoriesChanged', list)
        return
    end

    -- Every zone gets a blip, rival turf included: you need to know whose
    -- block you're walking onto. Gang-locked detail (contest state) is
    -- stripped server-side before it ever reaches this client.
    for _, t in ipairs(list) do
        if t.coords then
            local mine = t.holderId and t.holderId == myGangId
            local radius = footprintRadius(t)

            local blip = AddBlipForRadius(t.coords.x, t.coords.y, t.coords.z, radius)
            if t.holderColor then
                local r, g, b = hexToRgb(t.holderColor)
                SetBlipSecondaryColour(blip, r, g, b)
            else
                SetBlipColour(blip, t.color or 0)
            end
            SetBlipAlpha(blip, mine and 120 or 90)
            blips[#blips + 1] = blip

            -- A named marker in the middle so the zone reads on the map
            -- legend, not just as an unlabelled circle.
            local marker = AddBlipForCoord(t.coords.x, t.coords.y, t.coords.z)
            SetBlipSprite(marker, mine and 84 or 437)
            SetBlipScale(marker, 0.7)
            SetBlipAsShortRange(marker, true)
            SetBlipColour(marker, mine and 2 or (t.holderId and 1 or 4))
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(t.holder and ('%s — %s'):format(t.label, t.holder) or t.label)
            EndTextCommandSetBlipName(marker)
            blips[#blips + 1] = marker

            if mine then buildWalls(t) end
        end
    end

    TriggerEvent('XS-CriminalTablet:client:territoriesChanged', list)
end

RegisterNetEvent('XS-CriminalTablet:client:territoryUpdate', refresh)

RegisterNetEvent('XS-CriminalTablet:client:captureUpdate', function(state)
    contests = state or {}
end)

RegisterNetEvent('XS-CriminalTablet:client:gangIdChanged', function(gangId)
    myGangId = gangId
    lastSignature = nil
    refresh(Territories)
end)

CreateThread(function()
    Wait(1500)
    local list = lib.callback.await('XS-CriminalTablet:territory:getAll', false)
    refresh(list)
    contests = lib.callback.await('XS-CriminalTablet:capture:getState', false) or {}
end)

-- ── in/out test, mirrored from the server so the HUD can react instantly ──
local function pointInPolygon(pts, x, y)
    local inside, j = false, #pts
    for i = 1, #pts do
        local xi, yi = pts[i].x, pts[i].y
        local xj, yj = pts[j].x, pts[j].y
        if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then inside = not inside end
        j = i
    end
    return inside
end

function ZoneAtCoords(coords)
    for _, t in ipairs(Territories) do
        if t.points and #t.points >= 3 then
            if pointInPolygon(t.points, coords.x, coords.y) then return t end
        elseif t.coords then
            if #(vec2(coords.x, coords.y) - vec2(t.coords.x, t.coords.y)) <= (t.radius or Config.Territory.defaultRadius) then
                return t
            end
        end
    end
    return nil
end

-- ── influence HUD ───────────────────────────────────────────
-- One stacked bar per zone: every crew with a stake gets a segment in its
-- own colour, sized to its share. Whoever is winning the block is obvious
-- without reading a single number.
local function drawInfluenceBar(zone, shares)
    local w, h = 0.24, 0.016
    local x, y = 0.5, 0.92
    local left = x - w / 2

    DrawRect(x, y, w + 0.008, h + 0.008, 0, 0, 0, 175)
    DrawRect(x, y, w, h, 40, 44, 52, 220)

    local cursor = left
    local labels = {}
    for _, s in ipairs(shares) do
        local frac = math.max(0, math.min(100, s.influence)) / 100
        local segW = w * frac
        if segW > 0.0005 then
            local r, g, b = hexToRgb(s.gangColor)
            DrawRect(cursor + segW / 2, y, segW, h, r, g, b, 235)
            cursor = cursor + segW
        end
        labels[#labels + 1] = ('%s %d%%'):format(s.gangLabel, s.influence)
    end

    SetTextFont(4)
    SetTextScale(0.0, 0.34)
    SetTextColour(235, 237, 240, 235)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(zone.holder
        and ('%s  ·  held by %s'):format(zone.label, zone.holder)
        or ('%s  ·  unassigned'):format(zone.label))
    EndTextCommandDisplayText(x, y - 0.032)

    SetTextFont(4)
    SetTextScale(0.0, 0.28)
    SetTextColour(150, 156, 166, 225)
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(table.concat(labels, '   ·   '))
    EndTextCommandDisplayText(x, y + 0.014)
end

local currentZone = nil
CreateThread(function()
    while true do
        local sleep = 500
        local zone = ZoneAtCoords(GetEntityCoords(PlayerPedId()))

        if zone ~= currentZone then
            currentZone = zone
            TriggerEvent('XS-CriminalTablet:client:zoneChanged', zone)
        end

        if zone then
            local shares = contests[zone.zone]
            if shares and #shares > 0 then
                sleep = 0
                drawInfluenceBar(zone, shares)
            end
        end

        Wait(sleep)
    end
end)

-- Other client files ask "what am I standing on?" a lot.
function CurrentZone() return currentZone end
