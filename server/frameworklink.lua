-- ─────────────────────────────────────────────────────────────
-- Framework gang link. Staff can tie a crew to a gang from the framework's
-- own list (QBCore shared gangs, QBox gangs). Anyone the framework puts in
-- that gang joins the crew, on the rank matching their framework grade, and
-- leaves it when the framework takes them out. A crew that is not linked is
-- never touched by framework changes.
-- ─────────────────────────────────────────────────────────────
FrameworkLink = {}

local lastSync = {}

function FrameworkLink.On()
    return Config.FrameworkLink and Config.FrameworkLink.enabled
end

-- The framework gang a crew is tied to, or nil.
function FrameworkLink.NameOf(gang)
    if not gang or not FrameworkLink.On() then return nil end
    local name = gang.framework_gang
    if not name or name == '' then return nil end
    return name
end

local function crewFor(name)
    if not name or name == '' or name == 'none' then return nil end
    local row = MySQL.single.await('SELECT id FROM xs_gangs WHERE framework_gang = ?', { name })
    return row and Gangs.Get(row.id) or nil
end
FrameworkLink.CrewFor = crewFor

-- The crew rank for a framework grade: the same number when the crew has
-- it, the nearest one below when it does not.
local function gradeFor(gang, level)
    if not Config.FrameworkLink.matchGrades then return Gangs.JoinGrade(gang) end
    local best, lowest
    for g in pairs(gang.ranks) do
        if g <= level and (not best or g > best) then best = g end
        if not lowest or g < lowest then lowest = g end
    end
    return best or lowest or 0
end

function FrameworkLink.Sync(src)
    if not FrameworkLink.On() then return end
    local player = Framework.GetPlayer(src)
    if not player or not player.PlayerData then return end
    lastSync[src] = os.time()
    local cid = player.PlayerData.citizenid
    local fg = player.PlayerData.gang or {}
    local level = tonumber(fg.grade and fg.grade.level) or 0
    local linked = crewFor(fg.name)
    local current = Gangs.GetByCitizen(cid)

    if current and (not linked or current.id ~= linked.id) then
        if not FrameworkLink.NameOf(current) or current.owner == cid then return end
        local name = current.members[cid] and current.members[cid].name or cid
        MySQL.update.await('DELETE FROM xs_gang_members WHERE citizenid = ?', { cid })
        current.members[cid] = nil
        Gangs.Log(current.id, ('%s left with the framework gang'):format(name), 'roster')
        Gangs.Broadcast(current.id, 'roster', {})
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
        current = nil
    end
    if not linked then return end

    local grade = gradeFor(linked, level)
    if not current then
        if Gangs.MemberCount(linked) >= Gangs.MaxMembers(linked.id) then
            print(('^3[XS-CriminalTablet]^0 %s is in the framework gang %s but %s is full'):format(cid, fg.name, linked.label))
            return
        end
        local name = Framework.GetName(src) or cid
        MySQL.insert.await('INSERT INTO xs_gang_members (gang_id, citizenid, name, grade) VALUES (?, ?, ?, ?)', { linked.id, cid, name, grade })
        Gangs._reload(linked.id)
        Gangs.Log(linked.id, ('%s joined from the framework gang'):format(name), 'roster')
        Gangs.Broadcast(linked.id, 'roster', {})
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    elseif Config.FrameworkLink.matchGrades and linked.owner ~= cid and current.members[cid] and current.members[cid].grade ~= grade then
        MySQL.update.await('UPDATE xs_gang_members SET grade = ? WHERE citizenid = ?', { grade, cid })
        current.members[cid].grade = grade
        Gangs.Broadcast(linked.id, 'roster', {})
        TriggerClientEvent('XS-CriminalTablet:client:refresh', src)
    end
end

-- Opening the tablet re-checks, at most every 15 seconds, so a missed
-- framework event never leaves someone stuck on the wrong side.
function FrameworkLink.MaybeSync(src)
    if not FrameworkLink.On() then return end
    if lastSync[src] and os.time() - lastSync[src] < 15 then return end
    FrameworkLink.Sync(src)
end

function FrameworkLink.SyncAll()
    if not FrameworkLink.On() then return end
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        local ok, err = pcall(FrameworkLink.Sync, src)
        if not ok then print('^1[XS-CriminalTablet]^0 framework gang sync failed: ' .. tostring(err)) end
    end
end

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    local src = player and player.PlayerData and player.PlayerData.source
    if src then CreateThread(function() FrameworkLink.Sync(src) end) end
end)

AddEventHandler('QBCore:Server:OnGangUpdate', function(src)
    src = tonumber(src)
    if src then CreateThread(function() FrameworkLink.Sync(src) end) end
end)

AddEventHandler('playerDropped', function()
    lastSync[source] = nil
end)

CreateThread(function()
    local has = MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'xs_gangs' AND COLUMN_NAME = 'framework_gang'
    ]])
    if (tonumber(has) or 0) == 0 then
        MySQL.query.await('ALTER TABLE `xs_gangs` ADD COLUMN `framework_gang` VARCHAR(64) NULL DEFAULT NULL')
    end
    Wait(4000)
    FrameworkLink.SyncAll()
end)
