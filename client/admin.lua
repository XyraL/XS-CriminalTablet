-- ─────────────────────────────────────────────────────────────
-- Admin tablet client: opens a separate NUI view. The server re-checks
-- the ACE permission on every callback regardless of how this opened, so
-- there's nothing sensitive to protect client-side here.
--
-- The one thing that lives on this side is the zone creator hand-off:
-- drawing a polygon means closing the panel and walking the block.
-- ─────────────────────────────────────────────────────────────
local isOpen = false

local function closeAdmin()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNetEvent('XS-CriminalTablet:client:openAdmin', function()
    if isOpen then return end
    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openAdmin' })
end)

RegisterNUICallback('admin:close', function(_, cb)
    closeAdmin()
    cb({})
end)

local adminAllowed = {
    -- dashboard + gangs
    ['XS-CriminalTablet:admin:getDashboard']    = true,
    ['XS-CriminalTablet:admin:getOverview']     = true,
    ['XS-CriminalTablet:admin:getMembers']      = true,
    ['XS-CriminalTablet:admin:getRanks']        = true,
    ['XS-CriminalTablet:admin:updateRank']      = true,
    ['XS-CriminalTablet:admin:getPrices']       = true,
    ['XS-CriminalTablet:admin:setPrice']        = true,
    ['XS-CriminalTablet:admin:resetPrice']      = true,
    ['XS-CriminalTablet:admin:createGang']      = true,
    ['XS-CriminalTablet:admin:updateGang']      = true,
    ['XS-CriminalTablet:admin:disbandGang']     = true,
    ['XS-CriminalTablet:admin:resetGang']       = true,
    ['XS-CriminalTablet:admin:setBank']         = true,
    ['XS-CriminalTablet:admin:addMember']       = true,
    ['XS-CriminalTablet:admin:kickMember']      = true,
    ['XS-CriminalTablet:admin:setMemberGrade']  = true,
    ['XS-CriminalTablet:admin:adjustRep']       = true,
    -- map editor
    ['XS-CriminalTablet:admin:getMapData']      = true,
    ['XS-CriminalTablet:admin:resolveCitizenId'] = true,
    ['XS-CriminalTablet:admin:whereAmI']        = true,
    ['XS-CriminalTablet:admin:placeFor']        = true,
    ['XS-CriminalTablet:admin:removePlacement'] = true,
    ['XS-CriminalTablet:admin:createBlip']      = true,
    ['XS-CriminalTablet:admin:updateBlip']      = true,
    ['XS-CriminalTablet:admin:deleteBlip']      = true,
    -- zones
    ['XS-CriminalTablet:admin:createZone']      = true,
    ['XS-CriminalTablet:admin:setZoneCoords']   = true,
    ['XS-CriminalTablet:admin:squareZone']      = true,
    ['XS-CriminalTablet:admin:setZonePolygon']  = true,
    ['XS-CriminalTablet:admin:updateZone']      = true,
    ['XS-CriminalTablet:admin:deleteZone']      = true,
    ['XS-CriminalTablet:admin:setTerritory']    = true,
    -- graffiti
    ['XS-CriminalTablet:admin:graffitiListArt']   = true,
    ['XS-CriminalTablet:admin:graffitiAddArt']    = true,
    ['XS-CriminalTablet:admin:graffitiDeleteArt'] = true,
    ['XS-CriminalTablet:admin:graffitiListTags']  = true,
    ['XS-CriminalTablet:admin:graffitiRemoveTag'] = true,
    ['XS-CriminalTablet:admin:graffitiWipeGang']  = true,
    -- garage
    ['XS-CriminalTablet:admin:garageList']   = true,
    ['XS-CriminalTablet:admin:garageGrant']  = true,
    ['XS-CriminalTablet:admin:garageDelete'] = true,
    -- war + test mode
    ['XS-CriminalTablet:admin:warList']         = true,
    ['XS-CriminalTablet:admin:warStop']         = true,
    ['XS-CriminalTablet:admin:testModeState']   = true,
    ['XS-CriminalTablet:admin:testModeZone']    = true,
    ['XS-CriminalTablet:admin:testModeArm']     = true,
    ['XS-CriminalTablet:admin:testModeStopAll'] = true,
    -- blackmarket + dealer
    ['XS-CriminalTablet:admin:chatGetWorld']      = true,
    ['XS-CriminalTablet:admin:chatDeleteWorld']   = true,
    ['XS-CriminalTablet:admin:chatResolveHandle'] = true,
    ['XS-CriminalTablet:admin:dealerGetStock']      = true,
    ['XS-CriminalTablet:admin:dealerState']         = true,
    ['XS-CriminalTablet:admin:dealerAddItem']       = true,
    ['XS-CriminalTablet:admin:dealerRemoveItem']    = true,
    ['XS-CriminalTablet:admin:dealerAddSpawn']      = true,
    ['XS-CriminalTablet:admin:dealerAddSpawnHere']  = true,
    ['XS-CriminalTablet:admin:dealerRemoveSpawn']   = true,
    ['XS-CriminalTablet:admin:dealerSetSetting']    = true,
    ['XS-CriminalTablet:admin:dealerResetSetting']  = true,
    ['XS-CriminalTablet:admin:dealerReroll']        = true,
    ['XS-CriminalTablet:admin:dealerClearCooldown'] = true,
}

RegisterNUICallback('admin:call', function(payload, cb)
    local name = payload.name
    if not adminAllowed[name] then return cb({ ok = false, error = 'unknown action' }) end
    local args = payload.args or {}
    local res = lib.callback.await(name, false, table.unpack(args))
    cb(res or {})
end)

-- ── in-world hand-offs ──
-- Drawing a zone means walking it, so the panel closes and the creator
-- takes over. It reopens on its own once the shape is saved or dropped.
RegisterNUICallback('admin:drawZone', function(data, cb)
    closeAdmin()
    cb({})
    CreateThread(function()
        Creator.Start(data.zone)
    end)
end)

RegisterNUICallback('admin:teleportZone', function(data, cb)
    cb({})
    if not data or not data.x then return end
    closeAdmin()
    local ped = PlayerPedId()
    local found, z = GetGroundZFor_3dCoord(data.x + 0.0, data.y + 0.0, (data.z or 0.0) + 25.0, false)
    SetEntityCoords(ped, data.x + 0.0, data.y + 0.0, found and z or (data.z or 30.0), false, false, false, false)
    lib.notify({ description = 'Teleported to the zone.', type = 'inform' })
end)

AddEventHandler('XS-CriminalTablet:client:creatorDone', function()
    -- Straight back into the panel so a run of zone edits doesn't mean
    -- re-typing /admintablet between each one.
    CreateThread(function()
        Wait(250)
        TriggerEvent('XS-CriminalTablet:client:openAdmin')
    end)
end)
