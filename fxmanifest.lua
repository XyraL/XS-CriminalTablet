fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'XS-CriminalTablet'
author 'XyraL'
description 'Modular criminal device for QBox/QBCore. Gangs, territory, rep, tasks, crafting, dealers and boosting.'
version '1.0.2'

-- Works on QBox (qbx_core) OR QBCore (qb-core). The bridge auto-detects.
-- Shared deps both frameworks support cleanly:
dependencies {
    'ox_lib',
    'oxmysql',
}

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/apps.lua',
}

client_scripts {
    'bridge/framework.lua',
    'client/main.lua',
    'client/device.lua',
    'client/territory.lua',
    'client/admin.lua',
    'client/placeables.lua',
    'client/drugs.lua',
    'client/dealer.lua',
    'client/crafting.lua',
    'client/boosting.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/framework.lua',
    'server/discord.lua',
    'server/main.lua',
    'server/gangs.lua',
    'server/gangperks.lua',
    'server/territory.lua',
    'server/notoriety.lua',
    'server/vault.lua',
    'server/placeables.lua',
    'server/bank.lua',
    'server/tasks.lua',
    'server/admin.lua',
    'server/crafting.lua',
    'server/dealer.lua',
    'server/drugs.lua',
    'server/chat.lua',
    'server/boosting.lua',
}

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js',
    'web/admin.js',
    'web/craft.js',
    -- Leaflet is vendored (BSD-2) — NUI has no reliable internet, so no CDN.
    'web/vendor/leaflet/leaflet.js',
    'web/vendor/leaflet/leaflet.css',
    'web/vendor/leaflet/images/*.png',
    'web/vendor/leaflet/LICENSE.txt',
    -- Map tile pyramid, shared with the rest of the line.
    'web/assets/maps/tiles/*.webp',
}
