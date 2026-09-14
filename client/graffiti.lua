-- ─────────────────────────────────────────────────────────────
-- Graffiti rendering + spraying.
--
-- Each tag is drawn as two textured triangles (DrawSpritePoly) laid flat
-- against the wall it was sprayed on, using a runtime texture fed by a
-- DUI. That's what lets a tag be an arbitrary image — a catalogue preset,
-- a studio drawing, or a staff-supplied URL — instead of being limited to
-- whatever textures already ship with the game.
--
-- DUIs are not free, so only the nearest few tags hold one at a time; the
-- rest are simply not drawn until you get closer.
-- ─────────────────────────────────────────────────────────────
Graffiti = {}

local tags = {}
local live = {}          -- [tagId] = { dui, txd, tex, art }
local liveOrder = {}     -- most-recently-used first, for eviction
local nextTxd = 0

local MAX_LIVE = 10      -- concurrent DUI surfaces
local DUI_SIZE = 512

-- ── DUI pool ────────────────────────────────────────────────
local function destroySurface(tagId)
    -- Drop it from the order FIRST and unconditionally. Returning early
    -- on a missing surface used to leave the id in liveOrder forever, and
    -- createSurface's eviction loop then span on it without end.
    for i, id in ipairs(liveOrder) do
        if id == tagId then table.remove(liveOrder, i) break end
    end

    local s = live[tagId]
    if not s then return end
    if s.dui then
        SetDuiUrl(s.dui, 'about:blank')
        DestroyDui(s.dui)
    end
    live[tagId] = nil
end

-- Hand a payload to a DUI page, repeatedly, for a couple of seconds.
--
-- IsDuiAvailable goes true as soon as the SURFACE exists, which is before
-- the page's own script has parsed and attached its message listener. A
-- single send at that moment lands on nothing, the page never paints, and
-- the texture stays blank forever with every other check reporting fine.
-- The page cannot acknowledge, so the answer is to keep saying it.
local function pushRender(dui, payload, forMs)
    CreateThread(function()
        local until_ = GetGameTimer() + (forMs or 3000)
        while GetGameTimer() < until_ do
            if not dui then return end
            SendDuiMessage(dui, payload)
            Wait(250)
        end
    end)
end

local function touch(tagId)
    for i, id in ipairs(liveOrder) do
        if id == tagId then table.remove(liveOrder, i) break end
    end
    table.insert(liveOrder, 1, tagId)
end

-- The draw loop walks nearest-first and touches each tag as it goes, so
-- by the end of a frame the NEAREST tag sits last in the MRU list. Left
-- alone, the next frame evicts exactly the surface you are standing in
-- front of, and with MAX_LIVE tags in range nothing is ever on screen
-- long enough to finish loading. Re-stamp the order once per frame,
-- furthest-first, so "most recently touched" means what it says.
local function touchAll(ordered)
    for i = #ordered, 1, -1 do touch(ordered[i]) end
end

local function createSurface(tag)
    if live[tag.id] then touch(tag.id) return live[tag.id] end

    while #liveOrder >= MAX_LIVE do
        destroySurface(liveOrder[#liveOrder])
    end

    nextTxd = nextTxd + 1
    local txdName = ('xs_tag_txd_%d'):format(nextTxd)
    local texName = ('xs_tag_tex_%d'):format(nextTxd)

    local dui = CreateDui(('nui://%s/web/tag.html'):format(GetCurrentResourceName()), DUI_SIZE, DUI_SIZE)
    if not dui then
        print('^1[XS-CriminalTablet]^0 CreateDui returned nothing - web/tag.html is not being served')
        return nil
    end

    local surface = { dui = dui, txd = txdName, tex = texName, art = tag.art, ready = false }
    live[tag.id] = surface
    touch(tag.id)

    CreateThread(function()
        -- Wait for the page BEFORE binding a texture to its handle.
        -- Binding against a DUI that has not come up yet gives you a
        -- texture that never resolves, and a quad that draws nothing
        -- with no error anywhere.
        local waited = 0
        while not IsDuiAvailable(dui) and waited < 5000 do
            Wait(50)
            waited = waited + 50
        end
        if not live[tag.id] then return end
        if not IsDuiAvailable(dui) then
            print(('^3[XS-CriminalTablet]^0 tag surface %s never came up - run /xstagdebug')
                :format(tostring(tag.id)))
            return
        end

        local bound = pcall(function()
            local txd = CreateRuntimeTxd(txdName)
            CreateRuntimeTextureFromDuiHandle(txd, texName, GetDuiHandle(dui))
        end)
        if not bound then
            print(('^1[XS-CriminalTablet]^0 could not bind a texture for tag %s'):format(tostring(tag.id)))
            return
        end

        local payload = json.encode({
            action = 'render',
            art = tag.art,
            tint = tag.tint ~= '' and tag.tint or (tag.gangColor or '#3d7dff'),
            label = tag.gangLabel,
        })
        if #payload > 220000 then
            print(('^3[XS-CriminalTablet]^0 tag %s is %d KB - too big to hand to the surface, simplify the drawing')
                :format(tostring(tag.id), math.floor(#payload / 1024)))
            return
        end
        pushRender(dui, payload)
        surface.ready = true
    end)

    return surface
end

-- ── geometry ────────────────────────────────────────────────
local function hexToRgb(hex)
    hex = tostring(hex or ''):gsub('#', '')
    if #hex ~= 6 then return 255, 255, 255 end
    return tonumber(hex:sub(1, 2), 16) or 255,
           tonumber(hex:sub(3, 4), 16) or 255,
           tonumber(hex:sub(5, 6), 16) or 255
end

local function normalize(v)
    local len = #v
    if len < 0.0001 then return vec3(0.0, 1.0, 0.0) end
    return v / len
end

-- Build the four corners of the quad from the tag's position and the
-- surface normal captured when it was sprayed.
local function cornersOf(tag)
    local pos = vec3(tag.x, tag.y, tag.z)
    local normal = normalize(vec3(tag.rx, tag.ry, tag.rz))

    -- A near-vertical normal (floor or ceiling) needs a different "up"
    -- reference or the cross product collapses.
    local worldUp = math.abs(normal.z) > 0.95 and vec3(0.0, 1.0, 0.0) or vec3(0.0, 0.0, 1.0)

    -- worldUp x normal, NOT normal x worldUp. The other way round points
    -- along the viewer's left when they're stood facing the wall, which
    -- mirrored every tag — text came out backwards.
    local right = normalize(vec3(
        worldUp.y * normal.z - worldUp.z * normal.y,
        worldUp.z * normal.x - worldUp.x * normal.z,
        worldUp.x * normal.y - worldUp.y * normal.x))

    -- normal x right keeps "up" pointing up once right has flipped.
    local up = normalize(vec3(
        normal.y * right.z - normal.z * right.y,
        normal.z * right.x - normal.x * right.z,
        normal.x * right.y - normal.y * right.x))

    local hw = (Config.Graffiti.defaultWidth * (tag.scale or 1.0)) / 2
    local hh = (Config.Graffiti.defaultHeight * (tag.scale or 1.0)) / 2

    -- Lift it off the surface so it doesn't z-fight with the wall, or
    -- end up buried in it when the ray hit slightly inside the geometry.
    local base = pos + normal * (Config.Graffiti.surfaceOffset or 0.05)

    return
        base - right * hw + up * hh,   -- top-left
        base + right * hw + up * hh,   -- top-right
        base + right * hw - up * hh,   -- bottom-right
        base - right * hw - up * hh    -- bottom-left
end

-- DrawSpritePoly takes a UVW triplet per vertex, not a UV pair. The third
-- number is the homogeneous W and has to be 1.0 — at 0.0 the u/w divide is
-- degenerate, so the triangle renders perfectly and samples nothing at all.
-- Everything else looks healthy while the wall stays blank.
local UVW = {
    tl = { 0.0, 0.0, 1.0 },
    tr = { 1.0, 0.0, 1.0 },
    br = { 1.0, 1.0, 1.0 },
    bl = { 0.0, 1.0, 1.0 },
}

local function poly(surface, a, b, c, ua, ub, uc)
    DrawSpritePoly(
        a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z,
        255, 255, 255, 255, surface.txd, surface.tex,
        ua[1], ua[2], ua[3],
        ub[1], ub[2], ub[3],
        uc[1], uc[2], uc[3])
end

local function drawTag(tag, surface)
    local tl, tr, br, bl = cornersOf(tag)

    -- Two triangles, wound so the quad is visible from the painted side.
    poly(surface, tl, tr, bl, UVW.tl, UVW.tr, UVW.bl)
    poly(surface, tr, br, bl, UVW.tr, UVW.br, UVW.bl)

    -- Both faces, so a tag is never invisible from the "wrong" side when
    -- a wall turns out to be a thin fence or a billboard.
    poly(surface, bl, tr, tl, UVW.bl, UVW.tr, UVW.tl)
    poly(surface, bl, br, tr, UVW.bl, UVW.br, UVW.tr)
end

-- ── render loop ─────────────────────────────────────────────
RegisterNetEvent('XS-CriminalTablet:client:graffitiUpdate', function(list)
    local incoming = {}
    for _, t in ipairs(list or {}) do incoming[t.id] = true end
    -- Drop surfaces for tags that no longer exist (painted over, wiped).
    for id in pairs(live) do
        if not incoming[id] then destroySurface(id) end
    end
    tags = list or {}
end)

CreateThread(function()
    Wait(3500)
    tags = lib.callback.await('XS-CriminalTablet:graffiti:getAll', false) or {}
end)

CreateThread(function()
    if not Config.Graffiti.enabled then return end
    local dist2 = Config.Graffiti.renderDistance * Config.Graffiti.renderDistance

    while true do
        local sleep = 500
        local pos = GetEntityCoords(PlayerPedId())

        -- Nearest-first, so the DUI pool is always spent on what you can
        -- actually see rather than whatever happened to load first.
        local nearby = {}
        for _, tag in ipairs(tags) do
            local dx, dy, dz = tag.x - pos.x, tag.y - pos.y, tag.z - pos.z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 <= dist2 then nearby[#nearby + 1] = { tag = tag, d2 = d2 } end
        end

        if #nearby > 0 then
            sleep = 0
            table.sort(nearby, function(a, b) return a.d2 < b.d2 end)

            local shown = {}
            for i = 1, math.min(#nearby, MAX_LIVE) do
                local tag = nearby[i].tag
                local surface = createSurface(tag)
                if surface and surface.ready then drawTag(tag, surface) end
                if surface then shown[#shown + 1] = tag.id end
            end

            -- Furthest-first, so the tag you are stood in front of ends up
            -- most-recently-used and survives the next eviction.
            touchAll(shown)
        end

        Wait(sleep)
    end
end)

-- ── spraying ────────────────────────────────────────────────
-- Raycast straight out of the camera to find the wall being aimed at.
local function aimedSurface()
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local dir = vec3(-math.sin(rz) * math.abs(math.cos(rx)), math.cos(rz) * math.abs(math.cos(rx)), math.sin(rx))
    local dest = cam + dir * Config.Graffiti.aimDistance

    local ray = StartShapeTestRay(cam.x, cam.y, cam.z, dest.x, dest.y, dest.z, 1 | 16 | 32 | 64, PlayerPedId(), 4)
    -- GetShapeTestResult's `hit` comes back as a Lua boolean here, not a
    -- number — comparing it to 1 would mean no wall is ever found.
    local _, hit, endCoords, normal = GetShapeTestResult(ray)
    if not hit or not endCoords or not normal then return nil end
    return endCoords, normal
end

-- ── live preview ────────────────────────────────────────────
-- One reusable surface that renders whatever is about to be sprayed, so
-- the preview is the real artwork on the real wall rather than an empty
-- outline you have to imagine the tag inside.
local preview = nil

local function previewSurface(payload)
    if not preview then
        local url = ('nui://%s/web/tag.html'):format(GetCurrentResourceName())
        local ok, dui = pcall(CreateDui, url, DUI_SIZE, DUI_SIZE)
        if not ok or not dui then
            print(('^1[XS-CriminalTablet]^0 CreateDui failed for %s - %s'):format(url, tostring(dui)))
            return nil
        end
        preview = { dui = dui, txd = 'xs_tag_preview_txd', tex = 'xs_tag_preview_tex',
                    ready = false, bound = false }
    end

    -- Re-send on every open: the studio may have composed something new
    -- since the last time this surface was used.
    preview.ready = false
    CreateThread(function()
        local waited = 0
        while not IsDuiAvailable(preview.dui) and waited < 5000 do
            Wait(50)
            waited = waited + 50
        end
        if not IsDuiAvailable(preview.dui) then
            print('^1[XS-CriminalTablet]^0 the preview surface never came up - run /xstagdebug')
            return
        end

        -- Bind once, and only once the page is actually up.
        if not preview.bound then
            local bound = pcall(function()
                local txd = CreateRuntimeTxd(preview.txd)
                CreateRuntimeTextureFromDuiHandle(txd, preview.tex, GetDuiHandle(preview.dui))
            end)
            if not bound then
                print('^1[XS-CriminalTablet]^0 could not bind the preview texture')
                return
            end
            preview.bound = true
        end

        pushRender(preview.dui, json.encode({
            action = 'render',
            art = payload.previewArt or '',
            tint = payload.tint or (payload.fill or '#3d7dff'),
            label = payload.label or '',
        }))
        preview.ready = true
    end)

    return preview
end

local function previewQuad(coords, normal, scale, ok)
    local fake = {
        x = coords.x, y = coords.y, z = coords.z,
        rx = normal.x, ry = normal.y, rz = normal.z,
        scale = scale,
    }

    if preview and preview.ready then
        -- The artwork itself shows you where it is going. Anything drawn
        -- around it is just in the way.
        drawTag(fake, preview)
        return
    end

    -- Only before the surface has painted, so there is still something to
    -- aim with in the first moment.
    local tl, tr, br, bl = cornersOf(fake)
    local r, g, b = 61, 125, 255
    if not ok then r, g, b = 255, 77, 90 end
    DrawLine(tl.x, tl.y, tl.z, tr.x, tr.y, tr.z, r, g, b, 120)
    DrawLine(tr.x, tr.y, tr.z, br.x, br.y, br.z, r, g, b, 120)
    DrawLine(br.x, br.y, br.z, bl.x, bl.y, bl.z, r, g, b, 120)
    DrawLine(bl.x, bl.y, bl.z, tl.x, tl.y, tl.z, r, g, b, 120)
end

local spraying = false

local function stopSpraying()
    spraying = false
    lib.hideTextUI()
    ClearPedTasks(PlayerPedId())
end

-- Whatever the studio composed, reduced to something tag.html can draw.
-- The preview has to show the same artwork the server will end up
-- storing, so the two are derived from the one payload here.
local function previewArtFor(payload)
    payload = payload or {}
    if payload.kind == 'draw' and payload.data then return 'draw:' .. payload.data end
    if payload.kind == 'text' then
        return 'text:' .. json.encode({
            text = payload.text or 'TAG', font = payload.font,
            fill = payload.fill, outline = payload.outline,
        })
    end
    if payload.previewArt then return payload.previewArt end
    if payload.art then return payload.art end
    return ''
end

-- The tagging animation. Kept in config because anim dictionaries are the
-- first thing a server owner wants to swap, and because a dict that fails
-- to stream should degrade to "no animation" rather than to a stuck spray.
-- Anim dictionaries vary by build, so try each candidate in turn and use
-- the first that actually streams instead of betting the whole animation
-- on one name being right.
-- Config's own entry first, then the fallbacks, flattened for the
-- progress bar to pick from.
local function sprayAnimCandidates()
    local cfg = Config.Graffiti.anim or {}
    local out = {}
    if cfg.dict and cfg.dict ~= '' and cfg.clip then
        out[#out + 1] = { dict = cfg.dict, clip = cfg.clip }
    end
    for _, c in ipairs(cfg.candidates or {}) do out[#out + 1] = c end
    return out
end

-- Visible spray coming out of the can.
--
-- GTA ships no paint effect, so this is a small puff tinted to whatever
-- colour is going on the wall — an approximation, not the real thing.
-- Swap the asset in config for anything you prefer, or set enabled=false.
--
-- Returns a stop function: the puffing has to end WITH the progress bar,
-- not on its own timer, or it carries on after the player has finished.
local function sprayParticles(coords, normal, hex)
    local fx = Config.Graffiti.anim and Config.Graffiti.anim.ptfx
    if not fx or fx.enabled == false or not fx.asset or fx.asset == '' then return function() end end

    local running = true
    CreateThread(function()
        RequestNamedPtfxAsset(fx.asset)
        local waited = 0
        while not HasNamedPtfxAssetLoaded(fx.asset) and waited < 1500 do
            Wait(50)
            waited = waited + 50
        end
        if not HasNamedPtfxAssetLoaded(fx.asset) then return end

        local r, g, b = hexToRgb(hex or '#3d7dff')
        local at = coords + normal * 0.15
        while running do
            UseParticleFxAssetNextCall(fx.asset)
            SetParticleFxNonLoopedColour(r / 255, g / 255, b / 255)
            SetParticleFxNonLoopedAlpha(fx.alpha or 0.7)
            StartParticleFxNonLoopedAtCoord(fx.name, at.x, at.y, at.z, 0.0, 0.0, 0.0, fx.scale or 0.35)
            Wait(fx.intervalMs or 130)
        end
    end)

    return function() running = false end
end

local function sprayProp()
    local model = Config.Graffiti.anim and Config.Graffiti.anim.prop
    if not model or model == '' then return nil end
    if not IsModelValid(model) then return nil end
    lib.requestModel(model)

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local obj = CreateObject(model, coords.x, coords.y, coords.z, true, true, false)
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, 28422),
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
    return obj
end

-- `payload` is whatever the studio composed: a library/catalogue pick, a
-- text composition, or a freehand drawing.
function Graffiti.StartSpray(payload)
    if spraying then
        -- A previous run that died mid-way would otherwise lock spraying
        -- out entirely until the resource restarted, which reads exactly
        -- like "the spray button does nothing".
        stopSpraying()
        Wait(0)
    end
    if not Config.Graffiti.enabled then
        lib.notify({ description = 'Graffiti is switched off on this server.', type = 'error' })
        return
    end

    spraying = true
    local scale = 1.0
    previewSurface({
        previewArt = previewArtFor(payload),
        tint = (payload and payload.tint) or nil,
        label = (payload and payload.label) or nil,
    })
    lib.showTextUI('[Scroll] Size   [E] Spray   [Backspace] Cancel')

    CreateThread(function()
        -- Any error below must still release the lock, or the next spray
        -- silently does nothing at all.
        local ok, err = pcall(function()
            while spraying do
                Wait(0)
                local coords, normal = aimedSurface()

                DisableControlAction(0, 14, true)
                DisableControlAction(0, 15, true)
                DisableControlAction(0, 38, true)
                DisableControlAction(0, 194, true)

                if IsDisabledControlJustPressed(0, 14) then
                    scale = math.min(Config.Graffiti.maxScale, scale + 0.1)
                end
                if IsDisabledControlJustPressed(0, 15) then
                    scale = math.max(Config.Graffiti.minScale, scale - 0.1)
                end

                if coords then
                    previewQuad(coords, normal, scale, true)

                    if IsDisabledControlJustPressed(0, 38) then
                        spraying = false
                        lib.hideTextUI()

                        local prop = sprayProp()
                        local stopFx = sprayParticles(coords, normal,
                            (payload and (payload.tint or payload.fill)) or nil)

                        -- Let the progress bar own the animation, the same
                        -- way the medic and the stash do. Playing it by
                        -- hand alongside meant two things fighting over
                        -- the ped and neither cleaning up.
                        local finished = XSAnim.Progress({
                            duration = Config.Graffiti.sprayDuration * 1000,
                            label = 'Tagging...',
                            useWhileDead = false,
                            canCancel = true,
                            disable = { move = true, combat = true },
                            anims = sprayAnimCandidates(),
                        })

                        stopFx()
                        ClearPedTasks(PlayerPedId())
                        if prop and DoesEntityExist(prop) then DeleteEntity(prop) end

                        if finished then
                            local body = {}
                            for k, v in pairs(payload or {}) do body[k] = v end
                            body.coords = { x = coords.x, y = coords.y, z = coords.z }
                            body.rx, body.ry, body.rz = normal.x, normal.y, normal.z
                            body.scale = scale

                            local res = lib.callback.await('XS-CriminalTablet:graffiti:spray', false, body)
                            lib.notify({
                                description = (res and res.ok) and 'Tag is up.' or ((res and res.error) or 'Could not spray that'),
                                type = (res and res.ok) and 'success' or 'error',
                            })
                        end
                    end
                else
                    -- Nothing in range: say so rather than letting the player
                    -- press E at thin air and wonder why nothing happens.
                    SetTextFont(4)
                    SetTextScale(0.0, 0.36)
                    SetTextColour(255, 77, 90, 230)
                    SetTextCentre(true)
                    SetTextOutline()
                    BeginTextCommandDisplayText('STRING')
                    AddTextComponentSubstringPlayerName('Aim at a wall')
                    EndTextCommandDisplayText(0.5, 0.86)
                end

                if IsDisabledControlJustPressed(0, 194) then
                    spraying = false
                    lib.hideTextUI()
                    lib.notify({ description = 'Cancelled.', type = 'inform' })
                end
            end
        end)

        stopSpraying()
        if not ok then
            print('^1[XS-CriminalTablet]^0 spray loop error: ' .. tostring(err))
            lib.notify({ description = 'Spraying broke — try again.', type = 'error' })
        end
    end)
end

-- Dying mid-spray used to leave the lock set forever.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end
    if not spraying then return end
    if args[1] ~= PlayerPedId() or args[6] ~= 1 then return end
    stopSpraying()
end)

RegisterNetEvent('XS-CriminalTablet:client:startSpray', function(payload)
    Graffiti.StartSpray(payload)
end)

-- "The tag doesn't show up" has half a dozen possible causes and none of
-- them print anything on their own. This says which one it is.
local DEBUG_BUILD = 'tagdebug-8'

RegisterCommand('xstagdebug', function()
    print(('^5[XS-CriminalTablet]^0 %s (if this is not the newest build, restart the resource)'):format(DEBUG_BUILD))
    local pos = GetEntityCoords(PlayerPedId())
    local dist2 = Config.Graffiti.renderDistance * Config.Graffiti.renderDistance

    local inRange, ready, pending = 0, 0, 0
    local nearestD, nearestId = 9e9, nil
    for _, t in ipairs(tags) do
        local dx, dy, dz = t.x - pos.x, t.y - pos.y, t.z - pos.z
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 < nearestD then nearestD, nearestId = d2, t.id end
        if d2 <= dist2 then
            inRange = inRange + 1
            local s = live[t.id]
            if s and s.ready then ready = ready + 1
            elseif s then pending = pending + 1 end
        end
    end

    print(('^5[XS-CriminalTablet]^0 graffiti: enabled=%s  known=%d  inRange=%d  surfacesReady=%d  surfacesPending=%d')
        :format(tostring(Config.Graffiti.enabled), #tags, inRange, ready, pending))
    print(('^5[XS-CriminalTablet]^0 render distance %.0fm, nearest tag %s at %.1fm')
        :format(Config.Graffiti.renderDistance, tostring(nearestId), nearestId and math.sqrt(nearestD) or -1))

    if #tags == 0 then
        print('^3  -> the client has no tags at all: the server never sent any, or nothing is in xs_gang_graffiti^0')
    elseif inRange == 0 then
        print('^3  -> there are tags, none within render distance of you^0')
    elseif ready == 0 then
        print('^3  -> tags are in range but no surface finished loading^0')
    else
        print('^2  -> surfaces are live and drawing; if you still see nothing the quad is facing away or inside geometry^0')
    end

    -- Probe the DUI pipeline directly. Everything on a wall depends on
    -- it, and nothing above can tell you whether it works.
    CreateThread(function()
        local url = ('nui://%s/web/tag.html'):format(GetCurrentResourceName())
        print(('^5[XS-CriminalTablet]^0 probing %s'):format(url))

        local ok, dui = pcall(CreateDui, url, 256, 256)
        if not ok or not dui then
            print(('^1  CreateDui FAILED: %s^0'):format(tostring(dui)))
            print('^1  -> web/tag.html is not being served. Check it is listed in fxmanifest files{}.^0')
            return
        end
        print('^2  CreateDui ok^0')

        local waited = 0
        while not IsDuiAvailable(dui) and waited < 6000 do
            Wait(100)
            waited = waited + 100
        end

        if IsDuiAvailable(dui) then
            print(('^2  IsDuiAvailable true after %dms^0'):format(waited))
            local h = GetDuiHandle(dui)
            print(('^2  DUI handle: %s^0'):format(tostring(h)))
            local txdOk = pcall(function()
                local txd = CreateRuntimeTxd('xs_tag_probe_txd')
                CreateRuntimeTextureFromDuiHandle(txd, 'xs_tag_probe_tex', h)
            end)
            print((txdOk and '^2  runtime texture ok - the pipeline is fine^0')
                or '^1  CreateRuntimeTextureFromDuiHandle FAILED^0')
        else
            print(('^1  IsDuiAvailable never went true (waited %dms)^0'):format(waited))
            print('^1  -> the page exists but will not load. Anything blocking NUI here?^0')
        end

        SetDuiUrl(dui, 'about:blank')
        DestroyDui(dui)
    end)

    -- Two visual tests for ten seconds, which between them decide what is
    -- left. There are only three possibilities and each shows differently:
    --
    --   no blue box            -> the quad is not where you think it is
    --   box but no thumbnail   -> the DUI texture is genuinely empty
    --   box AND thumbnail      -> the texture is fine and DrawSpritePoly
    --                             is what will not draw it
    if nearestId then
        local target = nil
        for _, t in ipairs(tags) do if t.id == nearestId then target = t break end end
        local surface = live[nearestId]

        if target then
            print('^5[XS-CriminalTablet]^0 10s: blue outline on the wall, and a BIG MAGENTA SQUARE in the centre of your screen')
            if surface and surface.ready then
                print(('^5  the texture %s/%s is being drawn on top of it^0'):format(
                    tostring(surface.txd), tostring(surface.tex)))
                print('^5  -> magenta with artwork = texture fine; plain magenta = texture blank^0')
            else
                print('^3  no ready surface for this tag, so the square will be plain magenta^0')
            end
            if math.sqrt(nearestD) > 8.0 then
                print(('^3  you are %.0fm away - walk up to the tag or the outline is a hairline^0'):format(math.sqrt(nearestD)))
            end
            if not surface or not surface.ready then
                print('^3  (no surface for it, so no thumbnail)^0')
            end

            CreateThread(function()
                local until_ = GetGameTimer() + 10000
                while GetGameTimer() < until_ do
                    Wait(0)

                    -- 1. where the quad is, and which way it faces
                    local tl, tr, br, bl = cornersOf(target)
                    DrawLine(tl.x, tl.y, tl.z, tr.x, tr.y, tr.z, 61, 125, 255, 255)
                    DrawLine(tr.x, tr.y, tr.z, br.x, br.y, br.z, 61, 125, 255, 255)
                    DrawLine(br.x, br.y, br.z, bl.x, bl.y, bl.z, 61, 125, 255, 255)
                    DrawLine(bl.x, bl.y, bl.z, tl.x, tl.y, tl.z, 61, 125, 255, 255)

                    local n = vec3(target.rx, target.ry, target.rz)
                    local c = vec3(target.x, target.y, target.z)
                    DrawLine(c.x, c.y, c.z, c.x + n.x, c.y + n.y, c.z + n.z, 47, 224, 138, 255)

                    -- 2. the runtime texture itself, flat on the HUD.
                    -- DrawSprite and DrawSpritePoly read the same texture;
                    -- if this shows and the wall does not, the texture is
                    -- not the problem.
                    -- Dead centre and large, because "I did not see it"
                    -- and "it was off the edge of my screenshot" are not
                    -- the same answer.
                    DrawRect(0.5, 0.5, 0.42, 0.42, 255, 0, 255, 220)
                    if surface and surface.ready then
                        DrawSprite(surface.txd, surface.tex, 0.5, 0.5, 0.40, 0.40, 0.0, 255, 255, 255, 255)
                    end
                end
            end)
        end
    end
end, false)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for id in pairs(live) do destroySurface(id) end
end)
