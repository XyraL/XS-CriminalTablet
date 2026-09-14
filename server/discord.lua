-- ─────────────────────────────────────────────────────────────
-- Discord webhook logging. Four categories, four separate webhook URLs
-- (Config.Discord), so admins/players/economy/war watchers can each have
-- their own channel without one drowning out the others. Any category
-- left blank in config is silently skipped — never required.
-- ─────────────────────────────────────────────────────────────
Discord = {}

local urlByCategory = {
    admin = Config.Discord.adminWebhook,
    gang = Config.Discord.gangWebhook,
    economy = Config.Discord.economyWebhook,
    war = Config.Discord.warWebhook,
}

Discord.Color = {
    info = 0x5865F2,    -- routine admin adjustment / neutral
    good = 0x2dd4bf,    -- founded, deposit, purchase
    warn = 0xf5a524,    -- boss changed, withdrawal, dues
    bad = 0xe5484d,     -- disbanded, kicked, penalty
}

-- title/description are plain strings; fields is an optional array of
-- { name, value, inline }. Fire-and-forget — a Discord outage should
-- never be able to break gameplay.
function Discord.Send(category, title, description, color, fields)
    local url = urlByCategory[category]
    if not url or url == '' then return end

    PerformHttpRequest(url, function() end, 'POST', json.encode({
        username = Config.Discord.botName,
        embeds = {
            {
                title = title,
                description = description,
                color = color or Discord.Color.info,
                fields = fields,
                timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            },
        },
    }), { ['Content-Type'] = 'application/json' })
end
