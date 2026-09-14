-- ─────────────────────────────────────────────────────────────
-- Pricing.
--
-- config.lua only ever supplies a DEFAULT price. Staff set the real ones
-- live in the admin tablet, and those overrides win — so a server owner
-- can tune the whole economy without editing a file or restarting.
--
-- One table covers both price kinds:
--   unlock   key = the TierUnlocks id          ('gang_vault')
--   upgrade  key = "<upgradeId>:<level>"       ('vault:2')
-- ─────────────────────────────────────────────────────────────
Prices = {}

local overrides = {}   -- [kind] = { [key] = price }

local function load()
    overrides = {}
    for _, row in ipairs(MySQL.query.await('SELECT kind, price_key, price FROM xs_prices') or {}) do
        overrides[row.kind] = overrides[row.kind] or {}
        overrides[row.kind][row.price_key] = row.price
    end
end

function Prices.Get(kind, key, default)
    local byKind = overrides[kind]
    local override = byKind and byKind[key]
    if override ~= nil then return override end
    return math.max(0, math.floor(tonumber(default) or 0))
end

function Prices.Set(kind, key, price)
    price = math.max(0, math.floor(tonumber(price) or 0))
    MySQL.query.await(
        'INSERT INTO xs_prices (kind, price_key, price) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE price = ?',
        { kind, key, price, price })
    overrides[kind] = overrides[kind] or {}
    overrides[kind][key] = price
    return true
end

-- Drop an override so the entry falls back to its config default.
function Prices.Reset(kind, key)
    MySQL.update('DELETE FROM xs_prices WHERE kind = ? AND price_key = ?', { kind, key })
    if overrides[kind] then overrides[kind][key] = nil end
    return true
end

-- ── unlocks ─────────────────────────────────────────────────
function Prices.UnlockPrice(unlockId)
    local def = Placeables.FindUnlockDef(unlockId)
    return Prices.Get('unlock', unlockId, def and def.price or 0)
end

-- ── upgrades ────────────────────────────────────────────────
function Prices.UpgradeCost(upgradeId, level)
    for _, u in ipairs(Config.Upgrades) do
        if u.id == upgradeId then
            local step = u.levels[level]
            return Prices.Get('upgrade', ('%s:%d'):format(upgradeId, level), step and step.cost or 0)
        end
    end
    return 0
end

-- ── admin view ──────────────────────────────────────────────
-- Everything priced on the server, flat, with both the live price and the
-- config default so staff can see what they've changed.
function Prices.ListAll()
    local unlocks = {}
    for _, tier in ipairs(Config.Rep.tiers) do
        for _, u in ipairs(Config.TierUnlocks[tier.name] or {}) do
            local live = Prices.Get('unlock', u.id, u.price or 0)
            unlocks[#unlocks + 1] = {
                key = u.id, label = u.label, kind = u.kind, tier = tier.name,
                price = live, default = u.price or 0, overridden = live ~= (u.price or 0),
            }
        end
    end

    local upgrades = {}
    for _, up in ipairs(Config.Upgrades) do
        for i, step in ipairs(up.levels) do
            local key = ('%s:%d'):format(up.id, i)
            local live = Prices.Get('upgrade', key, step.cost or 0)
            upgrades[#upgrades + 1] = {
                key = key, label = ('%s — level %d'):format(up.label, i), icon = up.icon,
                price = live, default = step.cost or 0, overridden = live ~= (step.cost or 0),
            }
        end
    end

    return { unlocks = unlocks, upgrades = upgrades }
end

CreateThread(function()
    Wait(2500)
    load()
end)

Prices._reload = load
