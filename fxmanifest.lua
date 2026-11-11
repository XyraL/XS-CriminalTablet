fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'XS-CriminalTablet'
author 'XyraL'
description 'Gang-only criminal tablet for QBox/QBCore. Turf war, raids, garage, graffiti, contracts and a full in-world creator.'
version '3.1.0'

-- Works on QBox (qbx_core) OR QBCore (qb-core). The bridge auto-detects.
dependencies {
    'ox_lib',
    'oxmysql',
}

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/permissions.lua',
    'shared/settings.lua',
    'shared/apps.lua',
}

client_scripts {
    'bridge/framework.lua',
    'bridge/keys.lua',
    'client/settings.lua',
    'client/main.lua',
    'client/device.lua',
    'client/territory.lua',
    'client/creator.lua',
    'client/jobwalk.lua',
    'client/admin.lua',
    'client/placeables.lua',
    'client/blips.lua',
    'client/graffiti.lua',
    'client/garage.lua',
    'client/war.lua',
    'client/intel.lua',
    'client/medic.lua',
    'client/radial.lua',
    'client/drugs.lua',
    'client/dealer.lua',
    'client/crafting.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/framework.lua',
    'bridge/keys.lua',
    'server/settings.lua',
    'server/discord.lua',
    'server/main.lua',
    'server/gangs.lua',
    'server/frameworklink.lua',
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
    'server/approvals.lua',
    'server/war.lua',
    'server/intel.lua',
    'server/medic.lua',
    'server/field.lua',
    'server/analytics.lua',
    'server/tasks.lua',
    'server/contracts.lua',
    'server/jobs.lua',
    'server/testmode.lua',
    'server/admin.lua',
    'server/crafting.lua',
    'server/content.lua',
    'server/dealer.lua',
    'server/drugs.lua',
    'server/chat.lua',
    'server/migrate.lua',
}

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/builder.css',
    'web/admin.css',
    'web/radial.css',
    'web/craft.css',
    'web/warhud.css',
    'web/app.js',
    'web/radial.js',
    'web/warhud.js',
    'web/rivals.js',
    'web/uploads.js',
    'web/bradial.js',
    'web/bjobs.js',
    'web/bcontent.js',
    'web/bapprovals.js',
    'web/picker.js',
    'web/admin.js',
    'web/bsettings.js',
    'web/palette.js',
    'web/mapedit.js',
    'web/craft.js',
    'web/graffiti.js',
    'web/spraysound.js',
    'web/sounds/*.ogg',
    'web/tag.html',
    -- Leaflet is vendored (BSD-2) — NUI has no reliable internet, so no CDN.
    'web/vendor/leaflet/leaflet.js',
    'web/vendor/leaflet/leaflet.css',
    'web/vendor/leaflet/images/*.png',
    'web/vendor/leaflet/LICENSE.txt',
    -- Map tile pyramid, shared with the rest of the line.
    'web/assets/maps/tiles/*.webp',
}
