-- ─────────────────────────────────────────────────────────────
-- App registry
-- The device is a shell. Each app registers itself here so the UI can
-- list it and route to it. This is what makes this a platform:
-- ship "Dark Web Market", "Contracts Board", etc. later as new apps
-- without touching the shell. Server owners enable/disable per app.
-- ─────────────────────────────────────────────────────────────
XSTablet = XSTablet or {}
XSTablet.Apps = {}

-- Register an app.
-- @param app table: { id, label, icon, enabled, requiresGang? }
function XSTablet.RegisterApp(app)
    assert(app.id, 'App requires an id')
    XSTablet.Apps[app.id] = {
        id = app.id,
        label = app.label or app.id,
        icon = app.icon or 'square',
        enabled = app.enabled ~= false,
        requiresGang = app.requiresGang == true,
        order = app.order or 100,
    }
end

-- Returns a sorted list of enabled apps for the UI, filtered to what this
-- specific player can actually see — gang-gated apps don't show at all
-- (not even the rail icon) if they're not in one.
function XSTablet.GetEnabledApps(hasGang)
    local list = {}
    for _, app in pairs(XSTablet.Apps) do
        if app.enabled and (not app.requiresGang or hasGang) then list[#list + 1] = app end
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
end

-- Gang Ops — requires being in a gang. Kept order 10 (lowest among
-- gang-gated apps) so members still default into it; non-gang players
-- never see it at all, so the lower order is moot for them.
XSTablet.RegisterApp({
    id = 'gangops',
    label = 'Gang Ops',
    icon = 'users',
    order = 10,
    enabled = true,
    requiresGang = true,
})

-- Car boosting — open to everyone, gang or not. Ordered after Gang Ops so
-- it isn't the default tab for gang members, but is the only (and
-- therefore default) tab for non-gang players.
XSTablet.RegisterApp({
    id = 'boosting',
    label = 'Boosting',
    icon = 'car',
    order = 15,
    enabled = true,
    requiresGang = false,
})

-- Blackmarket — anonymous world chat + handle-addressed DMs. Also
-- gang-gated, even though the chat content itself isn't gang-specific.
XSTablet.RegisterApp({
    id = 'blackmarket',
    label = 'Blackmarket',
    icon = 'comments',
    order = 20,
    enabled = Config.Chat.enabled,
    requiresGang = true,
})
