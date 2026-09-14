-- ─────────────────────────────────────────────────────────────
-- Rank permissions
-- The full granular set. Bosses build their own rank ladder per gang
-- (name + salary + any mix of these), so this list is the vocabulary
-- both the rank editor and every server-side check read from.
--
-- Adding one here makes it appear in the rank editor automatically —
-- the UI is generated from this table, never hardcoded.
-- ─────────────────────────────────────────────────────────────
XSTablet = XSTablet or {}

XSTablet.PermissionGroups = {
    {
        id = 'roster', label = 'Roster',
        permissions = {
            { id = 'invite',              label = 'Invite members',        description = 'Send invites to players' },
            { id = 'kick',                label = 'Remove members',        description = 'Kick someone out of the gang' },
            { id = 'promote',             label = 'Promote members',       description = 'Raise a member to a higher rank' },
            { id = 'demote',              label = 'Demote members',        description = 'Drop a member to a lower rank' },
            { id = 'transfer_leadership', label = 'Hand over leadership',  description = 'Make another member the boss (gives up your own seat)' },
            { id = 'manage_ranks',        label = 'Manage rank ladder',    description = 'Create, rename, reorder and re-permission ranks' },
            { id = 'manage_motd',         label = 'Set the crew notice',   description = 'Edit the notice every member sees on the tablet' },
        },
    },
    {
        id = 'money', label = 'Treasury',
        permissions = {
            { id = 'bank_withdraw', label = 'Withdraw funds',     description = 'Take money out of the treasury (anyone can deposit)' },
            { id = 'bank_ledger',   label = 'View ledger',        description = 'Read the full transaction history' },
            { id = 'manage_upgrades', label = 'Buy upgrades',     description = 'Spend the treasury on permanent gang upgrades' },
            { id = 'manage_perks',  label = 'Spend perk points',  description = 'Buy tiers on the gang perk tree' },
        },
    },
    {
        id = 'storage', label = 'Storage',
        permissions = {
            { id = 'vault_open',    label = 'Open the vault',     description = 'Access the shared item stash' },
            { id = 'vault_manage',  label = 'Manage the vault',   description = 'Move or remove the vault container itself' },
            { id = 'garage_take',   label = 'Take vehicles',      description = 'Pull gang vehicles out of the garage' },
            { id = 'garage_store',  label = 'Store vehicles',     description = 'Add vehicles to the gang garage' },
            { id = 'garage_delete', label = 'Delete vehicles',    description = 'Permanently remove a vehicle from the garage' },
        },
    },
    {
        id = 'property', label = 'Property',
        permissions = {
            { id = 'place_objects',  label = 'Place gang points', description = 'Place the HQ, safe, garage, medic point and benches' },
            { id = 'remove_objects', label = 'Remove gang points', description = 'Pick placed points back up' },
        },
    },
    {
        id = 'turf', label = 'Turf & war',
        permissions = {
            { id = 'capture_territory', label = 'Work rival turf', description = 'Build your crew\'s share of a block someone else holds' },
            { id = 'start_raid',        label = 'Mobilise a raid', description = 'Launch a raid against a rival gang' },
            { id = 'declare_war',       label = 'Declare war',     description = 'Open a full two-sided war' },
            { id = 'stash_raid',        label = 'Loot a stash',    description = 'Take the loot window after winning a war' },
        },
    },
    {
        id = 'ops', label = 'Operations',
        permissions = {
            { id = 'accept_contracts', label = 'Take contracts',   description = 'Accept jobs from the contracts board' },
            { id = 'spray_graffiti',   label = 'Spray graffiti',   description = 'Tag walls with the gang library' },
            { id = 'manage_graffiti',  label = 'Manage graffiti',  description = 'Remove tags and organise the gang library' },
            { id = 'view_analytics',   label = 'View analytics',   description = 'See street standing and the rival breakdown' },
        },
    },
}

-- Flat { id -> def } lookup, plus an ordered id list for anything that
-- needs to iterate deterministically.
XSTablet.Permissions = {}
XSTablet.PermissionOrder = {}
for _, group in ipairs(XSTablet.PermissionGroups) do
    for _, perm in ipairs(group.permissions) do
        perm.group = group.id
        XSTablet.Permissions[perm.id] = perm
        XSTablet.PermissionOrder[#XSTablet.PermissionOrder + 1] = perm.id
    end
end

function XSTablet.IsPermission(id)
    return XSTablet.Permissions[id] ~= nil
end

-- Drops anything that isn't a real permission id and de-duplicates —
-- every write path (rank editor, config seed) runs input through this so
-- a typo'd id can never end up persisted in the DB.
function XSTablet.SanitizePermissions(list)
    if list == '*' then return '*' end
    local seen, out = {}, {}
    for _, id in ipairs(list or {}) do
        if XSTablet.Permissions[id] and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end
