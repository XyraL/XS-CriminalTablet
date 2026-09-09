-- ─────────────────────────────────────────────────────────────
-- Blackmarket chat: anonymous handle per character, a capped world feed,
-- and DMs addressed by handle. The server is the only thing that ever
-- maps a handle back to a citizenid — that mapping never reaches the
-- client, so there's no way to deanonymize someone from the NUI alone.
-- ─────────────────────────────────────────────────────────────
Chat = {}

-- Blackmarket is gated to gang members only (even though the chat content
-- itself isn't gang-specific) — the tablet hides the tab for non-gang
-- players, and this is the server-side half of that, not just UI cosmetics.
local function requireGang(src)
    local cid = Framework.GetCitizenId(src)
    if not cid or not Gangs.GetByCitizen(cid) then return false end
    return true
end

local function randomHandle()
    local adj = Config.Chat.handleAdjectives[math.random(#Config.Chat.handleAdjectives)]
    local noun = Config.Chat.handleNouns[math.random(#Config.Chat.handleNouns)]
    local suffix = ('%04X'):format(math.random(0, 0xFFFF))
    return ('%s%s-%s'):format(adj, noun, suffix)
end

function Chat.GetOrCreateHandle(citizenid)
    local row = MySQL.single.await('SELECT handle FROM xs_chat_handles WHERE citizenid = ?', { citizenid })
    if row then return row.handle end

    -- Collision odds are tiny (adjectives × nouns × 65536 combos) but the
    -- unique key means a retry is free insurance either way.
    for _ = 1, 5 do
        local handle = randomHandle()
        local ok = pcall(function()
            MySQL.insert.await('INSERT INTO xs_chat_handles (citizenid, handle) VALUES (?, ?)', { citizenid, handle })
        end)
        if ok then return handle end
    end
    return nil
end

function Chat.ResolveHandle(handle)
    local row = MySQL.single.await('SELECT citizenid FROM xs_chat_handles WHERE handle = ?', { handle })
    return row and row.citizenid or nil
end

-- Lets a player pick their own handle instead of the generated one.
-- Renaming only affects future messages — past chat/DM rows keep the
-- handle text they were sent with (it's cached, not joined live), and the
-- old handle stops resolving to anyone once it's freed up.
function Chat.SetHandle(src, desired)
    desired = (desired or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if not desired:match('^[%w_%-]+$') then return false, 'letters, numbers, - and _ only' end
    if #desired < 3 or #desired > 24 then return false, 'must be 3-24 characters' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'no character' end

    local taken = MySQL.single.await('SELECT citizenid FROM xs_chat_handles WHERE handle = ?', { desired })
    if taken and taken.citizenid ~= cid then return false, 'handle already taken' end

    Chat.GetOrCreateHandle(cid) -- ensure a row exists before we try to update it
    local ok = pcall(function()
        MySQL.update.await('UPDATE xs_chat_handles SET handle = ? WHERE citizenid = ?', { desired, cid })
    end)
    if not ok then return false, 'handle already taken' end
    return true, desired
end

-- ── world feed ──
function Chat.GetWorldHistory()
    local rows = MySQL.query.await(
        'SELECT handle, message, created_at FROM xs_chat_world ORDER BY id DESC LIMIT ?',
        { Config.Chat.worldHistoryLimit }) or {}
    local list = {}
    for i = #rows, 1, -1 do list[#list + 1] = rows[i] end -- oldest first
    return list
end

-- ── admin moderation (no gang/anonymity gating — staff-only via admin.lua's ACE check) ──
function Chat.GetWorldHistoryAdmin()
    local rows = MySQL.query.await(
        'SELECT id, handle, message, created_at FROM xs_chat_world ORDER BY id DESC LIMIT ?',
        { Config.Chat.worldHistoryLimit }) or {}
    return rows
end

function Chat.DeleteWorldMessage(id)
    if not id then return false, 'no message id' end
    MySQL.update('DELETE FROM xs_chat_world WHERE id = ?', { id })
    return true
end

function Chat.PostWorld(src, message)
    message = (message or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if message == '' then return false, 'empty message' end
    if #message > Config.Chat.maxMessageLength then return false, 'message too long' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'no character' end
    local handle = Chat.GetOrCreateHandle(cid)
    if not handle then return false, 'could not assign a handle' end

    MySQL.insert.await('INSERT INTO xs_chat_world (handle, message) VALUES (?, ?)', { handle, message })
    TriggerClientEvent('XS-CriminalTablet:client:chatWorldMessage', -1, { handle = handle, message = message, created_at = os.date('%Y-%m-%d %H:%M:%S') })
    return true, handle
end

-- ── DMs ──
-- Threads: most recent message per counterpart handle, newest first.
function Chat.GetThreads(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end

    local rows = MySQL.query.await([[
        SELECT
            CASE WHEN from_citizenid = ? THEN to_handle ELSE from_handle END AS handle,
            message, created_at, from_citizenid, read_at
        FROM xs_chat_dms
        WHERE from_citizenid = ? OR to_citizenid = ?
        ORDER BY id DESC
    ]], { cid, cid, cid }) or {}

    local seen = {}
    local threads = {}
    for _, r in ipairs(rows) do
        if not seen[r.handle] then
            seen[r.handle] = true
            threads[#threads + 1] = {
                handle = r.handle,
                lastMessage = r.message,
                lastAt = r.created_at,
                unread = r.from_citizenid ~= cid and r.read_at == 0,
            }
        end
    end
    return threads
end

function Chat.GetThread(src, otherHandle)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    local otherCid = Chat.ResolveHandle(otherHandle)
    if not otherCid then return {} end

    local rows = MySQL.query.await([[
        SELECT from_handle, message, created_at, to_citizenid
        FROM xs_chat_dms
        WHERE (from_citizenid = ? AND to_citizenid = ?) OR (from_citizenid = ? AND to_citizenid = ?)
        ORDER BY id DESC LIMIT ?
    ]], { cid, otherCid, otherCid, cid, Config.Chat.dmHistoryLimit }) or {}

    MySQL.update('UPDATE xs_chat_dms SET read_at = ? WHERE to_citizenid = ? AND from_citizenid = ? AND read_at = 0',
        { os.time() * 1000, cid, otherCid })

    local list = {}
    for i = #rows, 1, -1 do list[#list + 1] = rows[i] end
    return list
end

function Chat.SendDM(src, toHandle, message)
    message = (message or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if message == '' then return false, 'empty message' end
    if #message > Config.Chat.maxMessageLength then return false, 'message too long' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'no character' end
    local fromHandle = Chat.GetOrCreateHandle(cid)

    local toCid = Chat.ResolveHandle(toHandle)
    if not toCid then return false, 'no one with that handle' end
    if toCid == cid then return false, "you can't message yourself" end

    MySQL.insert.await(
        'INSERT INTO xs_chat_dms (from_citizenid, to_citizenid, from_handle, to_handle, message) VALUES (?, ?, ?, ?, ?)',
        { cid, toCid, fromHandle, toHandle, message })

    -- deliver live if they're online right now
    for _, p in ipairs(GetPlayers()) do
        local s = tonumber(p)
        if Framework.GetCitizenId(s) == toCid then
            TriggerClientEvent('XS-CriminalTablet:client:chatDM', s, { handle = fromHandle, message = message })
            break
        end
    end

    return true, fromHandle
end

lib.callback.register('XS-CriminalTablet:chat:getMyHandle', function(src)
    if not requireGang(src) then return nil end
    local cid = Framework.GetCitizenId(src)
    return cid and Chat.GetOrCreateHandle(cid) or nil
end)

lib.callback.register('XS-CriminalTablet:chat:setHandle', function(src, desired)
    if not requireGang(src) then return { ok = false, error = 'no gang' } end
    local ok, res = Chat.SetHandle(src, desired)
    return { ok = ok, error = not ok and res or nil, handle = ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:chat:getWorldHistory', function(src)
    if not requireGang(src) then return {} end
    return Chat.GetWorldHistory()
end)

lib.callback.register('XS-CriminalTablet:chat:postWorld', function(src, message)
    if not requireGang(src) then return { ok = false, error = 'no gang' } end
    local ok, res = Chat.PostWorld(src, message)
    return { ok = ok, error = not ok and res or nil }
end)

lib.callback.register('XS-CriminalTablet:chat:getThreads', function(src)
    if not requireGang(src) then return {} end
    return Chat.GetThreads(src)
end)

lib.callback.register('XS-CriminalTablet:chat:getThread', function(src, handle)
    if not requireGang(src) then return {} end
    return Chat.GetThread(src, handle)
end)

lib.callback.register('XS-CriminalTablet:chat:sendDM', function(src, toHandle, message)
    if not requireGang(src) then return { ok = false, error = 'no gang' } end
    local ok, res = Chat.SendDM(src, toHandle, message)
    return { ok = ok, error = not ok and res or nil }
end)
