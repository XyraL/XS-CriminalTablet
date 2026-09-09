-- ─────────────────────────────────────────────────────────────
-- Device UI controller. Opens the NUI, fetches a snapshot, and relays
-- every UI action to a server callback, returning the result to the UI.
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

local function openDevice()
    if isOpen then return end
    local snapshot = lib.callback.await('XS-CriminalTablet:getSnapshot', false)
    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', data = snapshot })
    playDeviceAnim()
end

-- Invites. ox_lib's dialog draws underneath the device page while it's
-- open, so an open device gets an in-page banner; a closed one gets the
-- dialog. A banner still pending when the device closes falls back to
-- the dialog so nothing is silently lost.
Device = Device or {}
local pendingInvite = nil
local INVITE_ACCEPT = {
    gang  = 'XS-CriminalTablet:server:acceptInvite',
    task  = 'XS-CriminalTablet:server:acceptTaskCoopInvite',
    boost = 'XS-CriminalTablet:server:acceptCoopInvite',
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
end)

RegisterNetEvent('XS-CriminalTablet:client:openDevice', openDevice)

RegisterNUICallback('close', function(_, cb)
    closeDevice()
    cb({})
end)

-- Generic relay: the UI names a server callback + args; we await + return.
-- Keeps the JS side tiny and the server the single source of truth.
local allowed = {
    ['XS-CriminalTablet:getSnapshot']   = true,
    ['XS-CriminalTablet:players:search'] = true,
    ['XS-CriminalTablet:invite']        = true,
    ['XS-CriminalTablet:kick']          = true,
    ['XS-CriminalTablet:setGrade']      = true,
    ['XS-CriminalTablet:bankDeposit']   = true,
    ['XS-CriminalTablet:bankWithdraw']  = true,
    ['XS-CriminalTablet:tasks:getAvailable'] = true,
    ['XS-CriminalTablet:tasks:accept']       = true,
    ['XS-CriminalTablet:tasks:cancel']       = true,
    ['XS-CriminalTablet:tasks:getStatus']        = true,
    ['XS-CriminalTablet:tasks:getAchievements']  = true,
    ['XS-CriminalTablet:tasks:getLeaderboard']   = true,
    ['XS-CriminalTablet:tasks:getCoopTasks']     = true,
    ['XS-CriminalTablet:tasks:getCrewStatus']    = true,
    ['XS-CriminalTablet:tasks:inviteCoop']       = true,
    ['XS-CriminalTablet:tasks:cancelCrew']       = true,
    ['XS-CriminalTablet:tasks:acceptCoop']       = true,
    ['XS-CriminalTablet:tasks:registerVan']      = true,
    ['XS-CriminalTablet:tasks:doPickupVan']      = true,
    ['XS-CriminalTablet:tasks:doUnload']         = true,
    ['XS-CriminalTablet:tasks:doCourierHandoff'] = true,
    ['XS-CriminalTablet:tasks:doReturnVan']      = true,
    ['XS-CriminalTablet:placeables:getAvailable'] = true,
    ['XS-CriminalTablet:placeables:remove']       = true,
    ['XS-CriminalTablet:dealer:getStatus']        = true,
    ['XS-CriminalTablet:dealer:contact']          = true,
    ['XS-CriminalTablet:chat:getMyHandle']        = true,
    ['XS-CriminalTablet:chat:setHandle']          = true,
    ['XS-CriminalTablet:chat:getWorldHistory']    = true,
    ['XS-CriminalTablet:chat:postWorld']          = true,
    ['XS-CriminalTablet:chat:getThreads']         = true,
    ['XS-CriminalTablet:chat:getThread']          = true,
    ['XS-CriminalTablet:chat:sendDM']             = true,
    ['XS-CriminalTablet:boosting:getStatus']      = true,
    ['XS-CriminalTablet:boosting:getLeaderboard'] = true,
    ['XS-CriminalTablet:boosting:accept']         = true,
    ['XS-CriminalTablet:boosting:cancel']         = true,
    ['XS-CriminalTablet:boosting:getAvailableVehicles'] = true,
    ['XS-CriminalTablet:boosting:getRecentActivity']    = true,
    ['XS-CriminalTablet:boosting:getAchievements']      = true,
    ['XS-CriminalTablet:boosting:getWanted']            = true,
    ['XS-CriminalTablet:boosting:getPerks']             = true,
    ['XS-CriminalTablet:boosting:buyPerk']              = true,
    ['XS-CriminalTablet:boosting:getCrewStatus']        = true,
    ['XS-CriminalTablet:boosting:inviteCoop']           = true,
    ['XS-CriminalTablet:boosting:cancelCrew']           = true,
    ['XS-CriminalTablet:boosting:acceptCoop']           = true,
    ['XS-CriminalTablet:gangperks:getTree']             = true,
    ['XS-CriminalTablet:gangperks:buyPerk']             = true,
    ['XS-CriminalTablet:bankGetLedger']                 = true,
}

-- Live chat pushes (not request/response, so they bypass the relay above
-- and go straight to the NUI as their own message actions).
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

-- Placement is a client-native flow (move a ghost prop, confirm in world),
-- so it closes the tablet and hands off to client/placeables.lua rather
-- than going through the generic server-callback relay above.
RegisterNUICallback('placeObject', function(data, cb)
    closeDevice()
    local model = Placeables.ResolveModel(data.kind, data.id)
    if model then Placeables.StartPlacement(data.kind, data.id, model) end
    cb({})
end)

-- ESC closes from the page.
RegisterNUICallback('escape', function(_, cb)
    closeDevice()
    cb({})
end)
