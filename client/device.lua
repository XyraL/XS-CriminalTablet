-- ─────────────────────────────────────────────────────────────
-- Device UI controller. Opens the NUI, fetches a snapshot, and relays
-- every UI action to a validated server callback.
--
-- The allowlist below is the whole security boundary on this side: the
-- page can only ever reach a callback that is named in it.
-- ─────────────────────────────────────────────────────────────
local isOpen = false
local ANIM_DICT = 'amb@code_human_in_bus_passenger_idles@female@tablet@base'
local ANIM_CLIP = 'base'

local function playDeviceAnim()
    RequestAnimDict(ANIM_DICT)
    local waited = 0
    while not HasAnimDictLoaded(ANIM_DICT) and waited < 1000 do Wait(50); waited = waited + 50 end
    if HasAnimDictLoaded(ANIM_DICT) then
        TaskPlayAnim(PlayerPedId(), ANIM_DICT, ANIM_CLIP, 3.0, 3.0, -1, 49, 0, false, false, false)
    end
end

local function stopDeviceAnim()
    ClearPedTasks(PlayerPedId())
end

local lastGangId = nil
local function noteGang(snapshot)
    local gangId = snapshot and snapshot.gang and snapshot.gang.id or nil
    if gangId ~= lastGangId then
        lastGangId = gangId
        TriggerEvent('XS-CriminalTablet:client:gangIdChanged', gangId)
    end
end

local function openDevice(app)
    if isOpen then return end
    local snapshot = lib.callback.await('XS-CriminalTablet:getSnapshot', false)
    noteGang(snapshot)
    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', data = snapshot, app = app })
    playDeviceAnim()
end

-- Invites. ox_lib's dialog draws underneath the device page while it's
-- open, so an open device gets an in-page banner; a closed one gets the
-- dialog. A banner still pending when the device closes falls back to the
-- dialog so nothing is silently lost.
Device = Device or {}
local pendingInvite = nil
local INVITE_ACCEPT = {
    gang = 'XS-CriminalTablet:server:acceptInvite',
    task = 'XS-CriminalTablet:server:acceptTaskCoopInvite',
}

local function promptInviteDialog(inv)
    local accepted = lib.alertDialog({
        header = inv.title,
        content = ('**%s** %s.\n\nAccept?'):format(inv.from, inv.detail),
        centered = true,
        cancel = true,
        labels = { confirm = 'Accept', cancel = 'Decline' },
    })
    if accepted == 'confirm' then TriggerServerEvent(INVITE_ACCEPT[inv.kind]) end
end

function Device.PromptInvite(kind, title, from, detail)
    local inv = { kind = kind, title = title, from = from or 'Someone', detail = detail }
    if isOpen then
        pendingInvite = inv
        SendNUIMessage({ action = 'invite', data = inv })
    else
        promptInviteDialog(inv)
    end
end

local function closeDevice()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    stopDeviceAnim()
    if pendingInvite then
        local inv = pendingInvite
        pendingInvite = nil
        CreateThread(function() promptInviteDialog(inv) end)
    end
end

RegisterNUICallback('inviteRespond', function(data, cb)
    local inv = pendingInvite
    pendingInvite = nil
    if data and data.accept and inv and INVITE_ACCEPT[inv.kind] then
        TriggerServerEvent(INVITE_ACCEPT[inv.kind])
    end
    cb({})
end)

RegisterNetEvent('XS-CriminalTablet:client:refresh', function()
    if isOpen then SendNUIMessage({ action = 'refresh' }) end
    CreateThread(function()
        local snapshot = lib.callback.await('XS-CriminalTablet:getSnapshot', false)
        noteGang(snapshot)
    end)
end)

RegisterNetEvent('XS-CriminalTablet:client:openDevice', function() openDevice() end)
RegisterNetEvent('XS-CriminalTablet:client:openDeviceFromWorld', function() openDevice() end)
RegisterNetEvent('XS-CriminalTablet:client:openDeviceAt', function(app) openDevice(app) end)

-- Live pushes from the server (someone joined, turf flipped, war score
-- moved) go straight through to the page so it updates without reopening.
RegisterNetEvent('XS-CriminalTablet:client:sync', function(event, data)
    if isOpen then SendNUIMessage({ action = 'sync', event = event, data = data }) end
end)

RegisterNetEvent('XS-CriminalTablet:client:testModeUpdate', function(data)
    if isOpen then SendNUIMessage({ action = 'testMode', data = data }) end
end)

RegisterNetEvent('XS-CriminalTablet:client:captureUpdate', function(data)
    if isOpen then SendNUIMessage({ action = 'capture', data = data }) end
end)

RegisterNUICallback('close', function(_, cb)
    closeDevice()
    cb({})
end)

-- Generic relay: the UI names a server callback + args; we await + return.
-- Keeps the JS side tiny and the server the single source of truth.
local allowed = {
    -- shell
    ['XS-CriminalTablet:getSnapshot']    = true,
    ['XS-CriminalTablet:players:search'] = true,
    ['XS-CriminalTablet:gang:getLiveMap'] = true,
    -- roster
    ['XS-CriminalTablet:invite']              = true,
    ['XS-CriminalTablet:kick']                = true,
    ['XS-CriminalTablet:setGrade']            = true,
    ['XS-CriminalTablet:transferLeadership']  = true,
    ['XS-CriminalTablet:leaveGang']           = true,
    ['XS-CriminalTablet:setMotd']             = true,
    -- ranks
    ['XS-CriminalTablet:ranks:list']    = true,
    ['XS-CriminalTablet:ranks:add']     = true,
    ['XS-CriminalTablet:ranks:update']  = true,
    ['XS-CriminalTablet:ranks:delete']  = true,
    -- treasury
    ['XS-CriminalTablet:bankDeposit']         = true,
    ['XS-CriminalTablet:bankWithdraw']        = true,
    ['XS-CriminalTablet:bankGetLedger']       = true,
    ['XS-CriminalTablet:placeables:buy']      = true,
    ['XS-CriminalTablet:upgrades:getTracks']  = true,
    ['XS-CriminalTablet:upgrades:buy']        = true,
    ['XS-CriminalTablet:gangperks:getTree']   = true,
    ['XS-CriminalTablet:gangperks:buyPerk']   = true,
    -- turf
    ['XS-CriminalTablet:territory:getAll']  = true,
    ['XS-CriminalTablet:capture:start']     = true,
    ['XS-CriminalTablet:capture:getState']  = true,
    ['XS-CriminalTablet:capture:whereAmI']  = true,
    -- property
    ['XS-CriminalTablet:placeables:getAvailable'] = true,
    ['XS-CriminalTablet:placeables:remove']       = true,
    -- war
    ['XS-CriminalTablet:war:getOverview'] = true,
    ['XS-CriminalTablet:war:startRaid']   = true,
    ['XS-CriminalTablet:war:declare']     = true,
    ['XS-CriminalTablet:war:getState']    = true,
    -- garage
    ['XS-CriminalTablet:garage:list']   = true,
    ['XS-CriminalTablet:garage:delete'] = true,
    -- graffiti
    ['XS-CriminalTablet:graffiti:getLibrary'] = true,
    ['XS-CriminalTablet:graffiti:saveArt']    = true,
    ['XS-CriminalTablet:graffiti:deleteArt']  = true,
    ['XS-CriminalTablet:graffiti:remove']     = true,
    -- medic
    ['XS-CriminalTablet:medic:getStatus'] = true,
    -- contracts
    ['XS-CriminalTablet:contracts:getStatus']    = true,
    ['XS-CriminalTablet:tasks:getAvailable']     = true,
    ['XS-CriminalTablet:tasks:accept']           = true,
    ['XS-CriminalTablet:tasks:cancel']           = true,
    ['XS-CriminalTablet:tasks:getStatus']        = true,
    ['XS-CriminalTablet:tasks:getAchievements']  = true,
    ['XS-CriminalTablet:tasks:getLeaderboard']   = true,
    ['XS-CriminalTablet:tasks:getCoopTasks']     = true,
    ['XS-CriminalTablet:tasks:getCrewStatus']    = true,
    ['XS-CriminalTablet:tasks:inviteCoop']       = true,
    ['XS-CriminalTablet:tasks:cancelCrew']       = true,
    ['XS-CriminalTablet:tasks:acceptCoop']       = true,
    -- standing
    ['XS-CriminalTablet:analytics:getStandings'] = true,
    -- dealer + blackmarket
    ['XS-CriminalTablet:dealer:getStatus']     = true,
    ['XS-CriminalTablet:dealer:contact']       = true,
    ['XS-CriminalTablet:chat:getMyHandle']     = true,
    ['XS-CriminalTablet:chat:setHandle']       = true,
    ['XS-CriminalTablet:chat:getWorldHistory'] = true,
    ['XS-CriminalTablet:chat:postWorld']       = true,
    ['XS-CriminalTablet:chat:getThreads']      = true,
    ['XS-CriminalTablet:chat:getThread']       = true,
    ['XS-CriminalTablet:chat:sendDM']          = true,
    -- test mode
    ['XS-CriminalTablet:testmode:getState'] = true,
}

-- Live chat pushes bypass the relay and go straight to the page.
RegisterNetEvent('XS-CriminalTablet:client:chatWorldMessage', function(data)
    SendNUIMessage({ action = 'chatWorldMessage', data = data })
end)

RegisterNetEvent('XS-CriminalTablet:client:chatDM', function(data)
    SendNUIMessage({ action = 'chatDM', data = data })
end)

RegisterNUICallback('call', function(payload, cb)
    local name = payload.name
    if not allowed[name] then return cb({ ok = false, error = 'unknown action' }) end
    local args = payload.args or {}
    local res = lib.callback.await(name, false, table.unpack(args))
    cb(res or {})
end)

-- ── world hand-offs ──
-- These close the tablet and hand control to a client-native flow, so
-- they don't go through the server-callback relay above.

RegisterNUICallback('placeObject', function(data, cb)
    closeDevice()
    cb({})
    CreateThread(function() Placeables.StartPlacement(data.id) end)
end)

RegisterNUICallback('spray', function(data, cb)
    closeDevice()
    cb({})
    CreateThread(function() TriggerEvent('XS-CriminalTablet:client:startSpray', data) end)
end)

RegisterNUICallback('garageTake', function(data, cb)
    closeDevice()
    cb({})
    CreateThread(function() GangGarage.Take(data.id) end)
end)

RegisterNUICallback('garageStore', function(_, cb)
    closeDevice()
    cb({})
    CreateThread(function() GangGarage.StoreCurrent() end)
end)

RegisterNUICallback('setWaypoint', function(data, cb)
    if data and data.x and data.y then
        SetNewWaypoint(data.x + 0.0, data.y + 0.0)
        lib.notify({ description = 'Waypoint set.', type = 'inform' })
    end
    cb({})
end)

-- ESC closes from the page.
RegisterNUICallback('escape', function(_, cb)
    closeDevice()
    cb({})
end)
