-- ─────────────────────────────────────────────────────────────
-- Admin tablet client: opens a separate NUI view. The server re-checks
-- the ACE permission on every callback regardless of how this opened,
-- so there's nothing sensitive to protect client-side here.
-- ─────────────────────────────────────────────────────────────
local isOpen = false

RegisterNetEvent('XS-CriminalTablet:client:openAdmin', function()
    if isOpen then return end
    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openAdmin' })
end)

RegisterNUICallback('admin:close', function(_, cb)
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    cb({})
end)

local adminAllowed = {
    ['XS-CriminalTablet:admin:getOverview']  = true,
    ['XS-CriminalTablet:admin:getMembers']   = true,
    ['XS-CriminalTablet:admin:kickMember']   = true,
    ['XS-CriminalTablet:admin:setMemberGrade'] = true,
    ['XS-CriminalTablet:admin:createGang']  = true,
    ['XS-CriminalTablet:admin:updateGang']  = true,
    ['XS-CriminalTablet:admin:disbandGang'] = true,
    ['XS-CriminalTablet:admin:adjustRep']     = true,
    ['XS-CriminalTablet:admin:adjustNotoriety'] = true,
    ['XS-CriminalTablet:admin:setBank']      = true,
    ['XS-CriminalTablet:admin:setTerritory'] = true,
    ['XS-CriminalTablet:admin:createZone']   = true,
    ['XS-CriminalTablet:admin:setZoneCoords'] = true,
    ['XS-CriminalTablet:admin:updateZone']   = true,
    ['XS-CriminalTablet:admin:deleteZone']   = true,
    ['XS-CriminalTablet:admin:boostSearch']      = true,
    ['XS-CriminalTablet:admin:boostSetStats']    = true,
    ['XS-CriminalTablet:admin:boostResetStats']  = true,
    ['XS-CriminalTablet:admin:boostDashboard']   = true,
    ['XS-CriminalTablet:admin:chatGetWorld']        = true,
    ['XS-CriminalTablet:admin:chatDeleteWorld']     = true,
    ['XS-CriminalTablet:admin:chatResolveHandle']   = true,
    ['XS-CriminalTablet:admin:dealerGetStock']        = true,
    ['XS-CriminalTablet:admin:dealerReroll']          = true,
    ['XS-CriminalTablet:admin:dealerClearCooldown']   = true,
    ['XS-CriminalTablet:admin:dealerGetStatus']       = true,
    ['XS-CriminalTablet:admin:getDashboard']          = true,
}

RegisterNUICallback('admin:call', function(payload, cb)
    local name = payload.name
    if not adminAllowed[name] then return cb({ ok = false, error = 'unknown action' }) end
    local args = payload.args or {}
    local res = lib.callback.await(name, false, table.unpack(args))
    cb(res or {})
end)
