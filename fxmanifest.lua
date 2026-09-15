fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'XS-CriminalTablet'
author 'XyraL'
description 'Gang-only criminal tablet for QBox/QBCore. Turf war, raids, garage, graffiti, contracts and a full in-world creator.'
version '2.0.1'

-- Works on QBox (qbx_core) OR QBCore (qb-core). The bridge auto-detects.
dependencies {
    'ox_lib',
    'oxmysql',
}

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/permissions.lua',
    'shared/apps.lua',
}

client_scripts {
    'bridge/framework.lua',
    'client/main.lua',
    'client/device.lua',
    'client/territory.lua',
    'client/creator.lua',
    'client/admin.lua',
    'client/placeables.lua',
    'client/blips.lua',
    'client/graffiti.lua',
    'client/garage.lua',
    'client/war.lua',
    'client/medic.lua',
    'client/radial.lua',
    'client/drugs.lua',
    'client/dealer.lua',
    'client/crafting.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/framework.lua',
    'server/discord.lua',
    'server/main.lua',
    'server/gangs.lua',
    'server/ranks.lua',
    'server/gangperks.lua',
    'server/upgrades.lua',
    'server/territory.lua',
    'server/capture.lua',
    'server/rep.lua',
    'server/vault.lua',
    'server/placeables.lua',
    'server/blips.lua',
    'server/bank.lua',
    'server/prices.lua',
    'server/garage.lua',
    'server/graffiti.lua',
    'server/war.lua',
    'server/medic.lua',
    'server/field.lua',
    'server/analytics.lua',
    'server/tasks.lua',
    'server/contracts.lua',
    'server/testmode.lua',
    'server/admin.lua',
    'server/crafting.lua',
    'server/dealer.lua',
    'server/drugs.lua',
    'server/chat.lua',
    'server/migrate.lua',
}

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js',
    'web/admin.js',
    'web/mapedit.js',
    'web/craft.js',
    'web/graffiti.js',
    'web/tag.html',
    -- Leaflet is vendored (BSD-2) — NUI has no reliable internet, so no CDN.
    'web/vendor/leaflet/leaflet.js',
    'web/vendor/leaflet/leaflet.css',
    'web/vendor/leaflet/images/*.png',
    'web/vendor/leaflet/LICENSE.txt',
    -- Map tile pyramid, shared with the rest of the line.
    'web/assets/maps/tiles/*.webp',
}
