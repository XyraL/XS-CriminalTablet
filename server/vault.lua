-- ─────────────────────────────────────────────────────────────
-- Vault / armory: a shared ox_inventory stash per gang, namespaced by id.
-- Access is gated by the 'vault_open' permission, and by gang-locked
-- zones — a rival standing at your container still can't open it.
--
-- The vault is also what a stash raid loots after a lost war, so its
-- contents are genuinely at risk.
-- ─────────────────────────────────────────────────────────────
Vault = {}

function Vault.StashId(gangId) return ('xs_gang_%d'):format(gangId) end

-- Register/refresh the stash so ox_inventory knows its current size.
-- Perks and treasury upgrades both feed the slot/weight numbers, so this
-- is called again whenever either changes.
function Vault.Refresh(gangId)
    local gang = Gangs.Get(gangId)
    if not gang then return end
    local mods = Gangs.Modifiers(gangId)
    local slots = Config.Vault.slots + mods.vaultSlotsBonus
    local weight = math.floor(Config.Vault.maxWeight * (1 + mods.vaultWeightBonusPct / 100))
    exports.ox_inventory:RegisterStash(
        Vault.StashId(gangId),
        ('%s Vault'):format(gang.label),
        slots,
        weight,
        false -- not owner-restricted; access is gated below
    )
end

-- Open the vault for a player standing at their gang's placed container.
function Vault.Open(src)
    if not Gangs.HasPerm(src, 'vault_open') then
        Framework.Notify(src, 'You do not have vault access.', 'error')
        return false
    end
    local gang = Gangs.GetBySource(src)
    if not gang then return false end

    if not Territory.CanInteractAt(src, GetEntityCoords(GetPlayerPed(src))) then
        Framework.Notify(src, 'This block belongs to someone else.', 'error')
        return false
    end

    Vault.Refresh(gang.id)
    exports.ox_inventory:forceOpenInventory(src, 'stash', Vault.StashId(gang.id))
    Gangs.Log(gang.id, ('%s opened the vault'):format(Framework.GetName(src) or 'Someone'), 'storage')
    return true
end

-- Pull a handful of stacks out of a gang's stash. Used by the stash raid,
-- which is the only thing that takes from a vault without opening it.
function Vault.LootStacks(gangId, maxStacks)
    local stash = Vault.StashId(gangId)
    local items = exports.ox_inventory:GetInventoryItems(stash)
    if not items then return {} end

    local pool = {}
    for _, item in pairs(items) do
        if item and item.name and (item.count or 0) > 0 then pool[#pool + 1] = item end
    end
    if #pool == 0 then return {} end

    -- Shuffle so a raid doesn't always strip the same slots.
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    local taken = {}
    for i = 1, math.min(maxStacks, #pool) do
        local item = pool[i]
        local removed = exports.ox_inventory:RemoveItem(stash, item.name, item.count, item.metadata)
        if removed then
            taken[#taken + 1] = { name = item.name, label = item.label or item.name, count = item.count, metadata = item.metadata }
        end
    end
    return taken
end
