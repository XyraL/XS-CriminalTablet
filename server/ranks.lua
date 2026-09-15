-- ─────────────────────────────────────────────────────────────
-- Rank ladder editor. Bosses build their own ladder per gang: name,
-- and any mix of the 26 permissions in shared/permissions.lua.
--
-- Two rules hold the whole thing together:
--   1. The top grade is always the boss seat and always keeps '*'.
--      Nothing can strip the owner's own authority and lock the gang.
--   2. Nobody may grant a permission their own rank doesn't have, so a
--      Lieutenant with 'manage_ranks' can't quietly promote themselves.
-- ─────────────────────────────────────────────────────────────
Ranks = {}

local function topGrade(gang) return Gangs._topGrade(gang.ranks) end

-- The permissions the acting player is allowed to hand out.
local function grantableBy(src, gang)
    local cid = Framework.GetCitizenId(src)
    if gang.owner == cid then return '*' end
    local member = gang.members[cid]
    if not member then return {} end
    local rank = gang.ranks[member.grade]
    if not rank then return {} end
    return rank.permissions
end

local function canGrant(grantable, perm)
    if grantable == '*' then return true end
    for _, p in ipairs(grantable) do if p == perm then return true end end
    return false
end

-- Nobody touches a rank above their own seat. `manage_ranks` on its own is not
-- enough: without this an Associate holding it can strip the Underboss rank
-- back to whatever they can grant, or delete it outright and demote everyone
-- sitting on it. The owner is exempt. `own` allows acting on your own seat,
-- which is fine for an edit -- canGrant already stops you handing yourself
-- anything you do not hold -- but not for a delete.
local function outranks(src, gang, grade, own)
    local cid = Framework.GetCitizenId(src)
    if gang.owner == cid then return true end
    local member = gang.members[cid]
    if not member then return false end
    if own then return member.grade >= grade end
    return member.grade > grade
end

local function persist(gangId, grade, name, perms)
    MySQL.query.await(
        'INSERT INTO xs_gang_ranks (gang_id, grade, name, permissions) VALUES (?, ?, ?, ?) ' ..
        'ON DUPLICATE KEY UPDATE name = ?, permissions = ?',
        { gangId, grade, name, perms, name, perms })
end

function Ranks.List(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return { ranks = {}, groups = XSTablet.PermissionGroups } end

    local list = {}
    for grade, r in pairs(gang.ranks) do
        list[#list + 1] = {
            grade = grade, name = r.name,
            permissions = r.permissions == '*' and '*' or r.permissions,
            isTop = grade == topGrade(gang),
            memberCount = 0,
        }
    end
    for _, m in pairs(gang.members) do
        for _, r in ipairs(list) do
            if r.grade == m.grade then r.memberCount = r.memberCount + 1 end
        end
    end
    table.sort(list, function(a, b) return a.grade > b.grade end)

    return {
        ranks = list,
        groups = XSTablet.PermissionGroups,
        grantable = grantableBy(src, gang),
        maxRanks = Config.MaxRanks,
        canEdit = Gangs.HasPerm(src, 'manage_ranks'),
    }
end

-- Add a rank one step below the current lowest non-zero gap, or at the
-- next free grade under the top. Ladders stay dense — no holes to reason
-- about later.
function Ranks.Add(src, name)
    if not Gangs.HasPerm(src, 'manage_ranks') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end

    local count = 0
    for _ in pairs(gang.ranks) do count = count + 1 end
    if count >= Config.MaxRanks then return false, ('max %d ranks'):format(Config.MaxRanks) end

    name = tostring(name or ''):sub(1, 48)
    if #name < 2 then return false, 'name too short' end

    -- Insert directly beneath the boss: shift nothing, just take the
    -- first free grade below the top.
    local top = topGrade(gang)
    local grade = nil
    for g = top - 1, 1, -1 do
        if not gang.ranks[g] then grade = g; break end
    end
    if not grade then
        -- Ladder is dense all the way down. Push the boss up one and slot
        -- the new rank into the seat it just left.
        local newTop = top + 1
        local boss = gang.ranks[top]
        persist(gang.id, newTop, boss.name, '"*"')
        MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE gang_id = ? AND grade = ?',
            { newTop, gang.id, top })
        grade = top
    end

    persist(gang.id, grade, name, json.encode({}))
    Gangs._reload(gang.id)
    Gangs.Log(gang.id, ('Rank "%s" created'):format(name), 'roster')
    Gangs.Broadcast(gang.id, 'ranks', {})
    return true, grade
end

function Ranks.Update(src, grade, fields)
    if not Gangs.HasPerm(src, 'manage_ranks') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    grade = tonumber(grade)
    local rank = gang.ranks[grade]
    if not rank then return false, 'unknown rank' end
    if not outranks(src, gang, grade, true) then return false, 'that rank sits at or above your own' end

    local isTop = grade == topGrade(gang)
    local name = rank.name
    local perms = rank.permissions

    if fields.name then
        name = tostring(fields.name):sub(1, 48)
        if #name < 2 then return false, 'name too short' end
    end

    if fields.permissions ~= nil then
        if isTop then
            -- The boss seat always keeps everything. Silently ignoring
            -- this is friendlier than erroring on a slider the UI
            -- already disables.
            perms = '*'
        else
            local wanted = XSTablet.SanitizePermissions(fields.permissions)
            local grantable = grantableBy(src, gang)
            for _, p in ipairs(wanted) do
                if not canGrant(grantable, p) then
                    return false, ('you cannot grant "%s" — your own rank does not have it'):format(
                        XSTablet.Permissions[p] and XSTablet.Permissions[p].label or p)
                end
            end
            perms = wanted
        end
    end

    persist(gang.id, grade, name, perms == '*' and '"*"' or json.encode(perms))
    gang.ranks[grade] = { name = name, permissions = perms }
    Gangs.Log(gang.id, ('Rank "%s" updated'):format(name), 'roster')
    Gangs.Broadcast(gang.id, 'ranks', {})
    return true
end

-- Deleting a rank moves everyone on it down to the grade below.
function Ranks.Delete(src, grade)
    if not Gangs.HasPerm(src, 'manage_ranks') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    grade = tonumber(grade)
    if not gang.ranks[grade] then return false, 'unknown rank' end
    if grade == topGrade(gang) then return false, 'cannot delete the boss rank' end
    if grade == 0 then return false, 'cannot delete the entry rank' end
    if not outranks(src, gang, grade) then return false, 'that rank sits at or above your own' end

    local below = 0
    for g in pairs(gang.ranks) do
        if g < grade and g > below then below = g end
    end

    local name = gang.ranks[grade].name
    MySQL.update('UPDATE xs_gang_members SET grade = ? WHERE gang_id = ? AND grade = ?', { below, gang.id, grade })
    MySQL.update('DELETE FROM xs_gang_ranks WHERE gang_id = ? AND grade = ?', { gang.id, grade })
    Gangs._reload(gang.id)
    Gangs.Log(gang.id, ('Rank "%s" removed'):format(name), 'roster')
    Gangs.Broadcast(gang.id, 'ranks', {})
    return true
end

-- ── callbacks ───────────────────────────────────────────────
lib.callback.register('XS-CriminalTablet:ranks:list', function(src)
    return Ranks.List(src)
end)

lib.callback.register('XS-CriminalTablet:ranks:add', function(src, name)
    local ok, res = Ranks.Add(src, name)
    return { ok = ok, error = not ok and res or nil, grade = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:ranks:update', function(src, grade, fields)
    local ok, err = Ranks.Update(src, grade, fields or {})
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:ranks:delete', function(src, grade)
    local ok, err = Ranks.Delete(src, grade)
    return { ok = ok, error = err }
end)
