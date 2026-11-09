-- Live settings on the client: the server sends the full set on start
-- and again whenever staff save.
RegisterNetEvent('XS-CriminalTablet:client:settings', function(values)
    Settings.Apply(values)
end)

CreateThread(function()
    Settings.Apply(lib.callback.await('XS-CriminalTablet:settings:values', false))
end)
