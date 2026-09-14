-- ─────────────────────────────────────────────────────────────
-- App registry
-- The device is a shell. Each app registers itself here so the UI can
-- list it and route to it — ship a new surface later without touching
-- the shell. Server owners enable/disable per app.
--
-- This tablet is GANG-ONLY: every app requires membership. A player with
-- no gang gets the locked screen and no rail at all.
-- ─────────────────────────────────────────────────────────────
XSTablet = XSTablet or {}
XSTablet.Apps = {}

-- Rail sections. Ten apps in one flat column is a wall; grouping them by
-- what they're FOR makes the rail scannable.
XSTablet.AppGroups = {
    { id = 'crew',    label = 'Crew' },
    { id = 'streets', label = 'Streets' },
    { id = 'assets',  label = 'Assets' },
    { id = 'intel',   label = 'Intel' },
}

-- Register an app.
-- @param app table: { id, label, icon, group, enabled, order, permission? }
function XSTablet.RegisterApp(app)
    assert(app.id, 'App requires an id')
    XSTablet.Apps[app.id] = {
        id = app.id,
        label = app.label or app.id,
        icon = app.icon or 'fa-square',
        group = app.group or 'crew',
        enabled = app.enabled ~= false,
        order = app.order or 100,
        -- Optional rank permission needed to even see the app. The server
        -- re-checks every action regardless — this only tidies the rail.
        permission = app.permission,
    }
end

-- Sorted list of the apps this specific player can see. `hasGang` false
-- returns nothing at all, which is what drives the locked screen.
function XSTablet.GetEnabledApps(hasGang, hasPerm)
    if not hasGang then return {} end
    local list = {}
    for _, app in pairs(XSTablet.Apps) do
        local allowed = not app.permission or (hasPerm and hasPerm(app.permission))
        if app.enabled and allowed then list[#list + 1] = app end
    end
    table.sort(list, function(a, b)
        if a.order == b.order then return a.id < b.id end
        return a.order < b.order
    end)
    return list
end

-- ── Crew ──
XSTablet.RegisterApp({
    id = 'hub', label = 'Hub', icon = 'fa-house-chimney', group = 'crew', order = 10,
})

XSTablet.RegisterApp({
    id = 'roster', label = 'Roster', icon = 'fa-users', group = 'crew', order = 20,
})

-- ── Streets ──
XSTablet.RegisterApp({
    id = 'turf', label = 'Turf', icon = 'fa-map-location-dot', group = 'streets', order = 30,
})

XSTablet.RegisterApp({
    id = 'war', label = 'War Room', icon = 'fa-crosshairs', group = 'streets', order = 40,
    enabled = Config.War.enabled,
})

XSTablet.RegisterApp({
    id = 'contracts', label = 'Contracts', icon = 'fa-file-signature', group = 'streets', order = 50,
    enabled = Config.Contracts.enabled,
})

-- ── Assets ──
XSTablet.RegisterApp({
    id = 'garage', label = 'Garage', icon = 'fa-warehouse', group = 'assets', order = 60,
    enabled = Config.Garage.enabled,
})

XSTablet.RegisterApp({
    id = 'graffiti', label = 'Studio', icon = 'fa-spray-can', group = 'assets', order = 70,
    enabled = Config.Graffiti.enabled,
})

XSTablet.RegisterApp({
    id = 'treasury', label = 'Treasury', icon = 'fa-vault', group = 'assets', order = 80,
})

-- ── Intel ──
XSTablet.RegisterApp({
    id = 'standing', label = 'Standing', icon = 'fa-ranking-star', group = 'intel', order = 90,
    enabled = Config.Analytics.enabled,
    permission = 'view_analytics',
})

XSTablet.RegisterApp({
    id = 'blackmarket', label = 'Blackmarket', icon = 'fa-comments', group = 'intel', order = 100,
    enabled = Config.Chat.enabled,
})
