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
        pushes[s.dui] = nil
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
local pushes = {}

local function pushRender(dui, payload, forMs)
    if not dui then return end
    local token = (pushes[dui] or 0) + 1
    pushes[dui] = token
    CreateThread(function()
        local until_ = GetGameTimer() + (forMs or 3000)
        while GetGameTimer() < until_ and pushes[dui] == token do
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
        surface.readyAt = GetGameTimer()
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

local function poly(surface, a, b, c, ua, ub, uc, alpha)
    DrawSpritePoly(
        a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z,
        255, 255, 255, alpha or 255, surface.txd, surface.tex,
        ua[1], ua[2], ua[3],
        ub[1], ub[2], ub[3],
        uc[1], uc[2], uc[3])
end

local function drawTag(tag, surface, alpha)
    local tl, tr, br, bl = cornersOf(tag)

    -- Two triangles, wound so the quad is visible from the painted side.
    poly(surface, tl, tr, bl, UVW.tl, UVW.tr, UVW.bl, alpha)
    poly(surface, tr, br, bl, UVW.tr, UVW.br, UVW.bl, alpha)

    -- Both faces, so a tag is never invisible from the "wrong" side when
    -- a wall turns out to be a thin fence or a billboard.
    poly(surface, bl, tr, tl, UVW.bl, UVW.tr, UVW.tl, alpha)
    poly(surface, bl, br, tr, UVW.bl, UVW.br, UVW.tr, alpha)
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
    preview.base = {
        action = 'render',
        art = payload.previewArt or '',
        tint = payload.tint or (payload.fill or '#3d7dff'),
        label = payload.label or '',
    }
    preview.current = preview.base
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

        pushRender(preview.dui, json.encode(preview.current))
        preview.ready = true
    end)

    return preview
end

local function revealPreview(ms, delay)
    if not preview or not preview.base then return end
    local msg = {}
    for k, v in pairs(preview.base) do msg[k] = v end
    msg.reveal = { id = GetGameTimer(), ms = ms, delay = delay or 0 }
    preview.current = msg
    if preview.ready then pushRender(preview.dui, json.encode(msg), 1500) end
end

local function fakeTag(coords, normal, scale)
    return {
        x = coords.x, y = coords.y, z = coords.z,
        rx = normal.x, ry = normal.y, rz = normal.z,
        scale = scale,
    }
end

local function previewQuad(coords, normal, scale, ok, alpha)
    local fake = fakeTag(coords, normal, scale)

    if preview and preview.ready then
        drawTag(fake, preview, alpha)
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

local SETS = {
    male = {
        dict = 'anim@scripted@freemode@postertag@graffiti_spray@male@',
        shake = 'shake_can_male',
        spray = { 'spray_can_var_01_male', 'spray_can_male', 'spray_can_var_02_male' },
        suffix = '_male',
        face = { dict = 'anim@scripted@freemode@tagcoll_ig_postertag@male@', clip = 'postertag_facial' },
        grip = vec3(0.0, 0.0, 0.07),
    },
    female = {
        dict = 'anim@scripted@freemode@postertag@graffiti_spray@heeled@',
        shake = 'shake_can_female',
        spray = { 'spray_can_var_01_female', 'spray_can_var_02_female' },
        suffix = '_female',
        face = { dict = 'anim@scripted@freemode@tagcoll_ig_postertag@heeled@', clip = 'postertag_facial' },
        grip = vec3(0.0, 0.0, 0.07),
    },
    classic = {
        dict = 'switch@franklin@lamar_tagging_wall',
        spray = { 'lamar_tagging_wall_loop_lamar' },
        grip = vec3(0.0, 0.0, 0.0),
    },
}

local KITS = {
    lstags = {
        name = 'lstags',
        can = 'm24_1_prop_m41_spraycan_01a',
        asset = 'scr_ih_col',
        loop = 'scr_ih_col_poster_spraytag',
        stop = 'spray_tag_stop',
        at = vec3(0.0, 0.02, 0.2),
        rot = vec3(90.0, 0.0, 0.0),
    },
    classic = {
        name = 'classic',
        can = 'prop_cs_spray_can',
        asset = 'scr_playerlamgraff',
        loop = 'scr_lamgraff_paint_spray',
        at = vec3(0.0, 0.0, 0.0),
        rot = vec3(0.0, 0.0, 0.0),
    },
}

local HISS_NAME = 'Vent_Fizzing'
local HISS_SET = 'dlc_ch_maintenance_sounds'
local STAND_OFF = 0.8
local GHOST_ALPHA = 110
local HEAR_RANGE = 30.0

local spraying = false
local can = nil
local run = nil
local painting = nil
local watching = {}

local function sprayCfg()
    local s = Config.Graffiti.spray or {}
    return {
        prop = type(s.prop) == 'string' and s.prop or '',
        mist = s.mist ~= false,
        sound = s.sound ~= false,
        volume = math.max(0.0, math.min(1.0, tonumber(s.volume) or 0.5)),
        walkUp = s.walkUp ~= false,
        reach = tonumber(s.reach) or 3.0,
    }
end

local function hint(text)
    SetTextFont(4)
    SetTextScale(0.0, 0.36)
    SetTextColour(255, 77, 90, 230)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.5, 0.86)
end

local function paintColour(payload)
    payload = payload or {}
    for _, key in ipairs({ 'tint', 'fill', 'paint' }) do
        local v = payload[key]
        if type(v) == 'string' and v:match('^#%x%x%x%x%x%x$') then return v end
    end
    return '#3d7dff'
end

local function pickSet(ped)
    local set = IsPedMale(ped) and SETS.male or SETS.female
    if DoesAnimDictExist(set.dict) then return set end
    if DoesAnimDictExist(SETS.classic.dict) then return SETS.classic end
    return nil
end

local function pickKit()
    if (tonumber(GetGameBuildNumber()) or 0) >= 3258 and IsModelInCdimage(KITS.lstags.can) then
        return KITS.lstags
    end
    return KITS.classic
end

local function loadDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    return pcall(lib.requestAnimDict, dict, 3000) and HasAnimDictLoaded(dict)
end

local function clipMs(set, clip, fallback)
    local d = GetAnimDuration(set.dict, clip)
    if not d or d <= 0.1 then return fallback end
    return math.floor(d * 1000)
end

local function attachCan(obj, set)
    local ped = PlayerPedId()
    local grip = (set and set.grip) or SETS.male.grip
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, 28422),
        grip.x, grip.y, grip.z, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
end

local function takeCan(set, kit)
    if can and DoesEntityExist(can) then return can end
    local model = sprayCfg().prop
    if model == '' or not IsModelInCdimage(model) then model = kit.can end
    if not XSModel.Load(model) then
        model = KITS.classic.can
        if not XSModel.Load(model) then return nil end
    end
    local at = GetEntityCoords(PlayerPedId())
    local obj = CreateObject(model, at.x, at.y, at.z + 0.2, true, true, false)
    if not obj or obj == 0 then return nil end
    SetEntityCollision(obj, false, false)
    attachCan(obj, set)
    SetModelAsNoLongerNeeded(model)
    can = obj
    return obj
end

local function dropCan()
    if can and DoesEntityExist(can) then
        DetachEntity(can, true, false)
        DeleteEntity(can)
    end
    can = nil
end

local function loadMist(kit)
    if HasNamedPtfxAssetLoaded(kit.asset) then return true end
    RequestNamedPtfxAsset(kit.asset)
    local untilT = GetGameTimer() + 2000
    while not HasNamedPtfxAssetLoaded(kit.asset) and GetGameTimer() < untilT do Wait(0) end
    return HasNamedPtfxAssetLoaded(kit.asset)
end

local function mistOn(entity, hex, kit)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    if not HasNamedPtfxAssetLoaded(kit.asset) then return nil end
    UseParticleFxAssetNextCall(kit.asset)
    local fx = StartParticleFxLoopedOnEntity(kit.loop, entity,
        kit.at.x, kit.at.y, kit.at.z, kit.rot.x, kit.rot.y, kit.rot.z, 1.0, false, false, false)
    if not fx or fx == 0 then return nil end
    local r, g, b = hexToRgb(hex)
    SetParticleFxLoopedColour(fx, r / 255, g / 255, b / 255, false)
    return fx
end

local function mistOff(fx)
    if fx then StopParticleFxLooped(fx, false) end
end

local function mistPuff(entity, hex, kit)
    if not kit.stop or not entity or entity == 0 or not DoesEntityExist(entity) then return end
    if not HasNamedPtfxAssetLoaded(kit.asset) then return end
    local r, g, b = hexToRgb(hex)
    UseParticleFxAssetNextCall(kit.asset)
    SetParticleFxNonLoopedColour(r / 255, g / 255, b / 255)
    StartParticleFxNonLoopedOnEntity(kit.stop, entity, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, false, false, false)
end

local function hissOn(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    local id = GetSoundId()
    PlaySoundFromEntity(id, HISS_NAME, entity, HISS_SET, false, 0)
    return id
end

local function hissOff(id)
    if not id then return end
    StopSound(id)
    ReleaseSoundId(id)
end

local function keepHissing(holder, entity)
    if not holder.snd or not HasSoundFinished(holder.snd) then return end
    if GetGameTimer() - (holder.sndAt or 0) < 400 then return end
    ReleaseSoundId(holder.snd)
    holder.snd = hissOn(entity)
    holder.sndAt = GetGameTimer()
end

local function sound(id, kind, extra)
    local data = { id = id, kind = kind }
    for k, v in pairs(extra or {}) do data[k] = v end
    SendNUIMessage({ action = 'spraySound', data = data })
end

local function share(state)
    LocalPlayer.state:set('xsSpray', state, true)
end

local function hearVolume(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return 0.0 end
    local d = #(GetEntityCoords(ped) - GetEntityCoords(PlayerPedId()))
    if d >= HEAR_RANGE then return 0.0 end
    local v = 1.0 - d / HEAR_RANGE
    return v * v
end

local function stopWatching(sid)
    local w = watching[sid]
    if not w then return end
    mistOff(w.fx)
    hissOff(w.snd)
    w.snd = nil
    sound('p' .. sid, 'stop')
    watching[sid] = nil
end

AddStateBagChangeHandler('xsSpray', nil, function(bagName, _, value)
    local player = GetPlayerFromStateBagName(bagName)
    if not player or player == 0 or player == PlayerId() then return end
    local sid = GetPlayerServerId(player)
    if type(value) ~= 'table' then stopWatching(sid) return end

    local ped = GetPlayerPed(player)
    if ped == 0 or #(GetEntityCoords(ped) - GetEntityCoords(PlayerPedId())) > HEAR_RANGE + 15.0 then
        stopWatching(sid)
        return
    end

    local w = watching[sid] or { seq = 0 }
    watching[sid] = w
    w.seq = w.seq + 1
    w.seen = GetGameTimer()
    local seq = w.seq
    local cfg = sprayCfg()
    local kit = KITS[value.kit] or KITS.classic

    if value.shake and cfg.sound then
        sound('p' .. sid, 'shake', { ms = value.shake, vol = hearVolume(ped) * cfg.volume })
    end
    if not value.on then
        if w.fx then mistPuff(w.ent, value.color, kit) end
        mistOff(w.fx)
        w.fx = nil
        hissOff(w.snd)
        w.snd = nil
        return
    end
    if not value.net or (w.fx or not cfg.mist) and (w.snd or not cfg.sound) then return end

    CreateThread(function()
        local untilT = GetGameTimer() + 1500
        while not NetworkDoesNetworkIdExist(value.net) and GetGameTimer() < untilT do Wait(50) end
        if watching[sid] ~= w or w.seq ~= seq or not NetworkDoesNetworkIdExist(value.net) then return end
        w.ent = NetToObj(value.net)
        if cfg.sound and not w.snd then
            w.snd = hissOn(w.ent)
            w.sndAt = GetGameTimer()
        end
        if cfg.mist and not w.fx and loadMist(kit) and watching[sid] == w and w.seq == seq then
            w.fx = mistOn(w.ent, value.color, kit)
        end
        while watching[sid] == w and w.seq == seq and w.snd do
            Wait(100)
            keepHissing(w, w.ent)
        end
    end)
end)

CreateThread(function()
    while true do
        Wait(2000)
        local now = GetGameTimer()
        for sid, w in pairs(watching) do
            if now - (w.seen or 0) > 20000 then stopWatching(sid) end
        end
    end
end)

local function sceneAt(set, clip, heading)
    local turn = GetAnimInitialOffsetRotation(set.dict, clip, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2)
    local yaw = heading - ((turn and turn.z) or 0.0)
    local off = GetAnimInitialOffsetPosition(set.dict, clip, 0.0, 0.0, 0.0, 0.0, 0.0, yaw, 0.0, 2)
    if not off or #off > 3.0 then return nil end
    local pos = GetEntityCoords(PlayerPedId())
    return vec3(pos.x - off.x, pos.y - off.y, pos.z - off.z), yaw
end

local function playClip(r, clip, loop, first)
    local ped = PlayerPedId()
    r.clip = clip
    if r.synced and can and DoesEntityExist(can) then
        local origin, yaw = sceneAt(r.set, clip, r.heading)
        if origin then
            if IsEntityAttached(can) then DetachEntity(can, false, false) end
            local scene = NetworkCreateSynchronisedScene(origin.x, origin.y, origin.z, 0.0, 0.0, yaw, 2, true, false, 1.0, 0.0, 1.0)
            NetworkAddPedToSynchronisedScene(ped, scene, r.set.dict, clip, first and 8.0 or 4.0, -4.0, 262, 0, 1000.0, 0)
            NetworkAddEntityToSynchronisedScene(can, scene, r.set.dict, (clip:gsub(r.set.suffix .. '$', '_spraycan')), 1000.0, -1000.0, 4)
            NetworkStartSynchronisedScene(scene)
            if r.scene then NetworkStopSynchronisedScene(r.scene) end
            r.scene = scene
            return
        end
        r.synced = false
        if not IsEntityAttached(can) then attachCan(can, r.set) end
    end
    TaskPlayAnim(ped, r.set.dict, clip, first and 4.0 or 3.0, -3.0, -1, loop and 1 or 2, 0.0, false, false, false)
end

local function stopEffects()
    local r = run
    if not r then return end
    run = nil
    r.active = false
    if r.fx then mistPuff(can, r.hex, r.kit) end
    mistOff(r.fx)
    r.fx = nil
    hissOff(r.snd)
    r.snd = nil
    if r.shared then share(nil) end
    sound('self', 'stop')
    local ped = PlayerPedId()
    if r.scene then
        NetworkStopSynchronisedScene(r.scene)
        r.scene = nil
    elseif r.set and r.clip then
        StopAnimTask(ped, r.set.dict, r.clip, 2.0)
    end
    if can and DoesEntityExist(can) and not IsEntityAttached(can) then attachCan(can, r.set) end
end

local function stopSpraying(keepCan)
    spraying = false
    lib.hideTextUI()
    stopEffects()
    if not keepCan then
        dropCan()
        return
    end
    local held = can
    SetTimeout(700, function()
        if can == held and not spraying and not run then dropCan() end
    end)
end

local function reachable(coords)
    local feet = GetEntityCoords(PlayerPedId()).z - 1.0
    local up = coords.z - feet
    return up >= -1.5 and up <= sprayCfg().reach
end

local function wallHeading(ped, coords, normal)
    if #vec2(normal.x, normal.y) > 0.3 then
        return GetHeadingFromVector_2d(-normal.x, -normal.y)
    end
    local p = GetEntityCoords(ped)
    return GetHeadingFromVector_2d(coords.x - p.x, coords.y - p.y)
end

local function walkUp(ped, coords, normal)
    local flat = vec2(normal.x, normal.y)
    if #flat < 0.3 then return true end
    flat = flat / #flat
    local feet = GetEntityCoords(ped)
    local spot = vec2(coords.x + flat.x * STAND_OFF, coords.y + flat.y * STAND_OFF)
    local function away()
        local p = GetEntityCoords(ped)
        return #(vec2(p.x, p.y) - spot)
    end
    if away() <= 0.35 then return true end

    TaskGoStraightToCoord(ped, spot.x, spot.y, feet.z, 1.0, 5000, wallHeading(ped, coords, normal), 0.1)
    local untilT = GetGameTimer() + 5000
    local lastPos, lastCheck = GetEntityCoords(ped), GetGameTimer() + 500
    while GetGameTimer() < untilT and away() > 0.3 do
        Wait(0)
        DisableControlAction(0, 30, true)
        DisableControlAction(0, 31, true)
        DisableControlAction(0, 21, true)
        DisableControlAction(0, 22, true)
        if GetGameTimer() - lastCheck > 700 then
            local p = GetEntityCoords(ped)
            if #(p - lastPos) < 0.05 then break end
            lastPos, lastCheck = p, GetGameTimer()
        end
    end
    if away() > 1.0 then
        ClearPedTasks(ped)
        return false
    end
    return true
end

local function faceWall(ped, coords, normal)
    local heading = wallHeading(ped, coords, normal)
    TaskAchieveHeading(ped, heading, 1000)
    local untilT = GetGameTimer() + 1000
    while GetGameTimer() < untilT do
        Wait(50)
        local diff = math.abs(((GetEntityHeading(ped) - heading + 180.0) % 360.0) - 180.0)
        if diff < 12.0 then break end
    end
    return heading
end

local function realTagUp(paint)
    for _, t in ipairs(tags) do
        if not paint.before[t.id] then
            local dx, dy, dz = t.x - paint.fake.x, t.y - paint.fake.y, t.z - paint.fake.z
            if dx * dx + dy * dy + dz * dz < 0.25 then
                local s = live[t.id]
                return s and s.ready and s.readyAt and GetGameTimer() - s.readyAt > 700 or false
            end
        end
    end
    return false
end

local function startPainting(coords, normal, scale)
    local before = {}
    for _, t in ipairs(tags) do before[t.id] = true end
    local paint = { fake = fakeTag(coords, normal, scale), alpha = GHOST_ALPHA, before = before }
    painting = paint
    CreateThread(function()
        while painting == paint do
            Wait(0)
            if preview and preview.ready and GetGameTimer() >= (paint.hideUntil or 0) then
                drawTag(paint.fake, preview, paint.alpha)
            end
            if paint.untilT and (GetGameTimer() > paint.untilT or realTagUp(paint)) then
                painting = nil
            end
        end
    end)
    return paint
end

local function sprayAt(payload, coords, normal, scale, set, kit)
    local ped = PlayerPedId()
    local cfg = sprayCfg()
    local hex = paintColour(payload)
    local paint = startPainting(coords, normal, scale)

    if cfg.walkUp and not walkUp(ped, coords, normal) then
        painting = nil
        return false, "You can't get to that spot."
    end
    local heading = faceWall(ped, coords, normal)

    local dictOk = set and loadDict(set.dict) or false
    local shakeMs = (dictOk and set.shake) and math.max(1000, math.min(3000, clipMs(set, set.shake, 1600))) or 0
    local sprayMs = math.max(1, tonumber(Config.Graffiti.sprayDuration) or 6) * 1000
    local net = (can and DoesEntityExist(can) and NetworkGetEntityIsNetworked(can)) and ObjToNet(can) or nil
    local mistReady = cfg.mist and can and loadMist(kit)
    local face = dictOk and set.face and loadDict(set.face.dict) and set.face or nil

    local r = {
        active = true, set = dictOk and set or nil, kit = kit, hex = hex, heading = heading,
        synced = dictOk and set.suffix ~= nil and can ~= nil and net ~= nil,
        fx = nil, clip = nil, scene = nil, shared = false,
    }
    run = r

    paint.hideUntil = GetGameTimer() + 300
    paint.alpha = 255
    revealPreview(sprayMs, shakeMs)

    CreateThread(function()
        local function hold(ms)
            local untilT = GetGameTimer() + ms
            while r.active and GetGameTimer() < untilT do
                Wait(0)
                if r.active then keepHissing(r, can) end
            end
            return r.active
        end

        if not r.active then return end
        if shakeMs > 0 then
            playClip(r, r.set.shake, false, true)
            if cfg.sound then sound('self', 'shake', { ms = shakeMs, vol = cfg.volume }) end
            share({ net = net, color = hex, kit = kit.name, shake = shakeMs })
            r.shared = true
            if not hold(shakeMs) then return end
        end
        if face then PlayFacialAnim(PlayerPedId(), face.clip, face.dict) end

        local endsAt = GetGameTimer() + sprayMs
        local i = 0
        while r.active and GetGameTimer() < endsAt do
            i = i + 1
            local burst = 2400
            if r.set then
                local clip = r.set.spray[((i - 1) % #r.set.spray) + 1]
                playClip(r, clip, true, shakeMs == 0 and i == 1)
                burst = clipMs(r.set, clip, 2400)
            end
            burst = math.min(burst, endsAt - GetGameTimer())

            if mistReady and not r.fx then r.fx = mistOn(can, hex, kit) end
            if cfg.sound and not r.snd then
                r.snd = hissOn(can)
                r.sndAt = GetGameTimer()
            end
            share({ net = net, color = hex, kit = kit.name, on = true })
            r.shared = true
            if not hold(burst - 150) then return end

            if r.fx then mistPuff(can, hex, kit) end
            mistOff(r.fx)
            r.fx = nil
            hissOff(r.snd)
            r.snd = nil
            share({ net = net, color = hex, kit = kit.name, on = false })
            if not hold(150) then return end
        end
    end)

    local finished = XSAnim.Progress({
        duration = shakeMs + sprayMs,
        label = 'Tagging...',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
    })
    stopEffects()

    if finished then
        paint.untilT = GetGameTimer() + 6000
    else
        painting = nil
    end
    return finished
end

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

-- `payload` is whatever the studio composed: a library/catalogue pick, a
-- text composition, or a freehand drawing.
function Graffiti.StartSpray(payload)
    if spraying or run then
        stopSpraying()
        Wait(0)
    end
    if not Config.Graffiti.enabled then
        lib.notify({ description = 'Graffiti is switched off on this server.', type = 'error' })
        return
    end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then
        lib.notify({ description = 'Get out of the vehicle first.', type = 'error' })
        return
    end
    local ready = lib.callback.await('XS-CriminalTablet:graffiti:ready', false)
    if not (ready and ready.ok) then
        lib.notify({ description = (ready and ready.error) or 'You cannot spray right now.', type = 'error' })
        return
    end

    spraying = true
    local scale = 1.0
    local set = pickSet(ped)
    local kit = pickKit()
    SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)
    takeCan(set, kit)
    previewSurface({
        previewArt = previewArtFor(payload),
        tint = (payload and payload.tint) or nil,
        label = (payload and payload.label) or nil,
    })
    lib.showTextUI('[Scroll] Size   [E] Spray   [Backspace] Cancel')

    CreateThread(function()
        local sprayed = false
        local ok, err = pcall(function()
            while spraying do
                Wait(0)
                local me = PlayerPedId()
                if IsPedInAnyVehicle(me, false) or IsEntityDead(me) then
                    spraying = false
                    break
                end
                local coords, normal = aimedSurface()

                DisableControlAction(0, 14, true)
                DisableControlAction(0, 15, true)
                DisableControlAction(0, 38, true)
                DisableControlAction(0, 194, true)
                DisableControlAction(0, 24, true)
                DisableControlAction(0, 25, true)
                DisableControlAction(0, 140, true)
                DisableControlAction(0, 141, true)
                DisableControlAction(0, 142, true)

                if IsDisabledControlJustPressed(0, 14) then
                    scale = math.min(Config.Graffiti.maxScale, scale + 0.1)
                end
                if IsDisabledControlJustPressed(0, 15) then
                    scale = math.max(Config.Graffiti.minScale, scale - 0.1)
                end

                if coords then
                    local inReach = reachable(coords)
                    previewQuad(coords, normal, scale, inReach, GHOST_ALPHA)

                    if not inReach then
                        hint('Too high to reach')
                    elseif IsDisabledControlJustPressed(0, 38) then
                        spraying = false
                        lib.hideTextUI()

                        local finished, why = sprayAt(payload, coords, normal, scale, set, kit)
                        if finished then
                            sprayed = true
                            local body = {}
                            for k, v in pairs(payload or {}) do
                                if k ~= 'paint' then body[k] = v end
                            end
                            body.coords = { x = coords.x, y = coords.y, z = coords.z }
                            body.rx, body.ry, body.rz = normal.x, normal.y, normal.z
                            body.scale = scale

                            local res = lib.callback.await('XS-CriminalTablet:graffiti:spray', false, body)
                            if not (res and res.ok) then painting = nil end
                            lib.notify({
                                description = (res and res.ok) and 'Tag is up.' or ((res and res.error) or 'Could not spray that'),
                                type = (res and res.ok) and 'success' or 'error',
                            })
                        elseif why then
                            lib.notify({ description = why, type = 'error' })
                        end
                    end
                else
                    hint('Aim at a wall')
                end

                if spraying and IsDisabledControlJustPressed(0, 194) then
                    spraying = false
                    lib.hideTextUI()
                    lib.notify({ description = 'Cancelled.', type = 'inform' })
                end
            end
        end)

        stopSpraying(sprayed)
        if not ok then
            painting = nil
            print('^1[XS-CriminalTablet]^0 spray loop error: ' .. tostring(err))
            lib.notify({ description = 'Spraying broke — try again.', type = 'error' })
        end
    end)
end

-- Dying mid-spray used to leave the lock set forever.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end
    if not spraying and not run then return end
    if args[1] ~= PlayerPedId() or args[6] ~= 1 then return end
    painting = nil
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
    for sid in pairs(watching) do stopWatching(sid) end
    painting = nil
    if spraying or run or can then stopSpraying() end
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    painting = nil
    if spraying or run or can then stopSpraying() end
end)
