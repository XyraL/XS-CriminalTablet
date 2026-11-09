-- ─────────────────────────────────────────────────────────────
-- Walk-and-place for the job builder. Staff close the builder, walk to
-- each spot and drop it where they stand, facing the way it should face,
-- then go straight back to the job they were editing.
-- ─────────────────────────────────────────────────────────────
JobWalk = {}

local active = false
local KEY_ADD, KEY_UNDO, KEY_DONE, KEY_CANCEL = 38, 194, 191, 73

local function text(line, row, scale)
    SetTextFont(4)
    SetTextScale(0.0, scale or 0.34)
    SetTextColour(235, 237, 240, 230)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(line)
    EndTextCommandDisplayText(0.015, 0.30 + row * 0.028)
end

local function finish(spec, points)
    active = false
    TriggerEvent('XS-CriminalTablet:client:openAdmin')
    SendNUIMessage({ action = 'jobPoints', data = { field = spec.field, points = points } })
end

function JobWalk.Start(spec)
    if active then return end
    active = true
    local points = {}
    local max = spec.many and 20 or 1
    CreateThread(function()
        while active do
            Wait(0)
            for i, p in ipairs(points) do
                DrawMarker(1, p.x, p.y, p.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 1.4, 77, 141, 255, 130, false, false, 2, false, nil, nil, false)
                local fx, fy = p.x + math.sin(-math.rad(p.w)) * 1.2, p.y + math.cos(-math.rad(p.w)) * 1.2
                DrawLine(p.x, p.y, p.z, fx, fy, p.z, 77, 141, 255, 220)
                if spec.many then
                    SetDrawOrigin(p.x, p.y, p.z + 0.4, 0)
                    SetTextFont(4); SetTextScale(0.0, 0.32); SetTextColour(255, 255, 255, 230); SetTextOutline(); SetTextCentre(true)
                    BeginTextCommandDisplayText('STRING'); AddTextComponentSubstringPlayerName(tostring(i)); EndTextCommandDisplayText(0.0, 0.0)
                    ClearDrawOrigin()
                end
            end
            text(('~b~%s~s~ · %s'):format(spec.job or 'Job', spec.label or spec.field), 0, 0.42)
            text(('%d of %s placed'):format(#points, spec.many and 'up to 20' or '1'), 1)
            text('~b~[E]~s~ drop here, facing the way you face   ~b~[Backspace]~s~ undo', 2)
            text('~g~[Enter]~s~ back to the builder   ~r~[X]~s~ cancel', 3)

            DisableControlAction(0, KEY_ADD, true)
            DisableControlAction(0, KEY_UNDO, true)
            DisableControlAction(0, KEY_DONE, true)
            DisableControlAction(0, KEY_CANCEL, true)

            if IsDisabledControlJustPressed(0, KEY_ADD) and #points < max then
                local ped = PlayerPedId()
                local c = GetEntityCoords(ped)
                points[#points + 1] = { x = c.x, y = c.y, z = c.z, w = GetEntityHeading(ped) }
                PlaySoundFrontend(-1, 'NAV_UP_DOWN', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                if not spec.many then finish(spec, points) end
            elseif IsDisabledControlJustPressed(0, KEY_UNDO) and #points > 0 then
                points[#points] = nil
                PlaySoundFrontend(-1, 'BACK', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
            elseif IsDisabledControlJustPressed(0, KEY_DONE) then
                finish(spec, points)
            elseif IsDisabledControlJustPressed(0, KEY_CANCEL) then
                finish(spec, {})
            end
        end
    end)
end

function JobWalk.IsActive() return active end
