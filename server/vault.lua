-- ─────────────────────────────────────────────────────────────
-- Vault / armory: a shared stash per gang, backed by ox_inventory.
-- Access is gated by the 'manage_vault' permission.
-- ─────────────────────────────────────────────────────────────
Vault = {}

local function stashId(gangId) return ('xs_gang_%d'):format(gangId) end

-- Register/refresh the stash for a gang so ox_inventory knows about it.
-- Slot/weight perks (Config.GangPerks) bump the base size.
local function ensureStash(gangId)
    local mods = GangPerks.ModifiersFor(gangId)
    local slots = Config.Vault.slots + mods.vaultSlotsBonus
    local weight = math.floor(Config.Vault.maxWeight * (1 + mods.vaultWeightBonusPct / 100))
    exports.ox_inventory:RegisterStash(
        stashId(gangId),
        ('Gang Vault'),
        slots,
        weight,
        false -- not owner-restricted; we gate access ourselves below
    )
end

-- Open the vault for a player if allowed. Called by the client's
-- proximity prompt once they're standing next to their gang's placed
-- vault container (see server/placeables.lua).
function Vault.Open(src)
    if not Gangs.HasPerm(src, 'manage_vault') then
        Framework.Notify(src, 'You do not have vault access.', 'error')
        return false
    end
    local gang = Gangs.GetBySource(src)
    if not gang then return false end
    ensureStash(gang.id)
    exports.ox_inventory:forceOpenInventory(src, 'stash', stashId(gang.id))
    return true
end
