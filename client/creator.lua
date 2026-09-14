-- ─────────────────────────────────────────────────────────────
-- In-world zone creator. Staff walk the corners of a block and the
-- polygon is drawn live in front of them — markers on each corner, lines
-- along every edge, and a closing line back to the start so the shape is
-- obvious before it's saved.
--
-- This is the thing that makes turf setup bearable: no coordinate
-- guessing in config.lua, just walk the block.
-- ─────────────────────────────────────────────────────────────
Creator = {}

local active = false
local points = {}
local zoneKey = nil

local KEY_ADD    = 38   -- E
local KEY_UNDO   = 194  -- Backspace
local KEY_SAVE   = 191  -- Enter
local KEY_CANCEL = 73   -- X

local function drawHelp()
    local lines = {
        ('~y~%s~s~  ·  %d corner%s'):format(zoneKey, #points, #points == 1 and '' or 's'),
        '~b~[E]~s~ drop corner   ~b~[Backspace]~s~ undo',
        '~g~[Enter]~s~ save   ~r~[X]~s~ cancel',
        #points < 3 and '~r~Need at least 3 corners~s~' or '~g~Ready to save~s~',
    }
    for i, line in ipairs(lines) do
        SetTextFont(4)
        SetTextScale(0.0, i == 1 and 0.42 or 0.34)
        SetTextColour(235, 237, 240, 230)
        SetTextOutline()
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName(line)
        EndTextCommandDisplayText(0.015, 0.30 + (i - 1) * 0.028)
    end
end

local function drawShape()
    for i, p in ipairs(points) do
        DrawMarker(1, p.x, p.y, p.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            0.8, 0.8, 1.6, 245, 165, 36, 120, false, false, 2, false, nil, nil, false)

        local nextP = points[i + 1]
        if nextP then
            DrawLine(p.x, p.y, p.z, nextP.x, nextP.y, nextP.z, 245, 165, 36, 200)
        end
    end

    -- Close the loop so you can see the actual footprint, not just a path.
    if #points >= 3 then
        local first, last = points[1], points[#points]
        DrawLine(last.x, last.y, last.z, first.x, first.y, first.z, 45, 212, 191, 200)
    end
end

function Creator.Start(key)
    if active then
        lib.notify({ description = 'Already drawing a zone.', type = 'error' })
        return
    end
    active = true
    zoneKey = key
    points = {}

    lib.notify({ description = ('Walk the corners of %s. [E] to drop one.'):format(key), type = 'inform' })

    CreateThread(function()
        while active do
            Wait(0)
            drawShape()
            drawHelp()

            DisableControlAction(0, KEY_ADD, true)
            DisableControlAction(0, KEY_UNDO, true)
            DisableControlAction(0, KEY_SAVE, true)
            DisableControlAction(0, KEY_CANCEL, true)

            if IsDisabledControlJustPressed(0, KEY_ADD) then
                local c = GetEntityCoords(PlayerPedId())
                points[#points + 1] = { x = c.x, y = c.y, z = c.z }
                PlaySoundFrontend(-1, 'NAV_UP_DOWN', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
            end

            if IsDisabledControlJustPressed(0, KEY_UNDO) and #points > 0 then
                points[#points] = nil
                PlaySoundFrontend(-1, 'BACK', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
            end

            if IsDisabledControlJustPressed(0, KEY_CANCEL) then
                active = false
                lib.notify({ description = 'Zone drawing cancelled.', type = 'inform' })
                TriggerEvent('XS-CriminalTablet:client:creatorDone', false)
            end

            if IsDisabledControlJustPressed(0, KEY_SAVE) then
                if #points < 3 then
                    lib.notify({ description = 'Drop at least 3 corners first.', type = 'error' })
                else
                    active = false
                    local flat = {}
                    local zSum = 0.0
                    for _, p in ipairs(points) do
                        flat[#flat + 1] = { x = p.x, y = p.y }
                        zSum = zSum + p.z
                    end
                    local res = lib.callback.await('XS-CriminalTablet:admin:setZonePolygon', false,
                        zoneKey, flat, zSum / #points)
                    lib.notify({
                        description = (res and res.ok) and ('%s saved — %d corners.'):format(zoneKey, #flat)
                            or ((res and res.error) or 'Could not save the zone'),
                        type = (res and res.ok) and 'success' or 'error',
                    })
                    TriggerEvent('XS-CriminalTablet:client:creatorDone', res and res.ok)
                end
            end
        end
    end)
end

function Creator.IsActive() return active end

RegisterNetEvent('XS-CriminalTablet:client:startZoneCreator', function(key)
    Creator.Start(key)
end)
