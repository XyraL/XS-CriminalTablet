-- ─────────────────────────────────────────────────────────────
-- Contracts board.
--
-- A thin rotation layer over the task engine in tasks.lua: rather than
-- every job being permanently available, a subset sits on the board and
-- rerolls on a timer, so the board is worth checking back on.
--
-- The board is server-wide, not per-gang — everyone is fighting over the
-- same work, which is the point.
-- ─────────────────────────────────────────────────────────────
Contracts = {}

local board = {}       -- [taskId] = true
local rotatedAt = 0

local function now() return os.time() * 1000 end

local function eligiblePool()
    local pool = {}
    for _, t in ipairs(Config.Tasks) do
        if not t.coopOnly then pool[#pool + 1] = t.id end
    end
    return pool
end

function Contracts.Reroll()
    local pool = eligiblePool()
    -- Fisher-Yates, then take the first N.
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    board = {}
    local size = math.min(Config.Contracts.boardSize, #pool)
    for i = 1, size do board[pool[i]] = true end
    rotatedAt = now()

    TriggerClientEvent('XS-CriminalTablet:client:sync', -1, 'contracts', {})
    return board
end

-- nil disables board filtering entirely (used when the feature is off, so
-- every contract stays available exactly as it did before 2.0).
function Contracts.OnBoard()
    if not Config.Contracts.enabled then return nil end
    return board
end

function Contracts.Status()
    return {
        enabled = Config.Contracts.enabled,
        categories = Config.Contracts.categories,
        rotatedAt = rotatedAt,
        nextRotationAt = rotatedAt + (Config.Contracts.rotateMinutes * 60000),
        boardSize = Config.Contracts.boardSize,
        now = now(),
    }
end

CreateThread(function()
    Wait(5000)
    if not Config.Contracts.enabled then return end
    Contracts.Reroll()
    while true do
        Wait(Config.Contracts.rotateMinutes * 60000)
        Contracts.Reroll()
    end
end)

lib.callback.register('XS-CriminalTablet:contracts:getStatus', function()
    return Contracts.Status()
end)
