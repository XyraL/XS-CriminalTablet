-- ─────────────────────────────────────────────────────────────
-- Gang bank: voluntary contributions, no forced dues. Any member can
-- deposit whenever they want; withdrawing stays gated by 'manage_bank' so
-- one member can't drain the pool solo. Every transaction is logged to a
-- dedicated ledger (xs_gang_bank_log) for the Treasury tab.
-- ─────────────────────────────────────────────────────────────
Bank = {}

local function logTransaction(gangId, src, kind, amount)
    MySQL.insert('INSERT INTO xs_gang_bank_log (gang_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
        { gangId, Framework.GetCitizenId(src) or '', Framework.GetName(src) or 'Someone', kind, amount })
end

function Bank.Deposit(src, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false, 'invalid amount' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    if Framework.GetMoney(src, Config.Bank.account) < amount then return false, 'not enough funds' end

    Framework.RemoveMoney(src, Config.Bank.account, amount, 'gang-deposit')
    gang.bank = gang.bank + amount
    MySQL.update('UPDATE xs_gangs SET bank = bank + ? WHERE id = ?', { amount, gang.id })
    Gangs.Log(gang.id, ('%s deposited $%d'):format(Framework.GetName(src), amount))
    logTransaction(gang.id, src, 'deposit', amount)
    Discord.Send('economy', 'Deposit', ('%s deposited $%d into %s'):format(Framework.GetName(src), amount, gang.label), Discord.Color.good)
    return true, gang.bank
end

function Bank.Withdraw(src, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false, 'invalid amount' end
    if not Gangs.HasPerm(src, 'manage_bank') then return false, 'no permission' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    if gang.bank < amount then return false, 'gang bank too low' end

    gang.bank = gang.bank - amount
    MySQL.update('UPDATE xs_gangs SET bank = bank - ? WHERE id = ?', { amount, gang.id })
    Framework.AddMoney(src, Config.Bank.account, amount, 'gang-withdraw')
    Gangs.Log(gang.id, ('%s withdrew $%d'):format(Framework.GetName(src), amount))
    logTransaction(gang.id, src, 'withdraw', amount)
    Discord.Send('economy', 'Withdrawal', ('%s withdrew $%d from %s'):format(Framework.GetName(src), amount, gang.label), Discord.Color.warn)
    return true, gang.bank
end

function Bank.GetLedger(gangId)
    return MySQL.query.await(
        'SELECT name, kind, amount, created_at FROM xs_gang_bank_log WHERE gang_id = ? ORDER BY id DESC LIMIT ?',
        { gangId, Config.Bank.ledgerLimit or 25 }) or {}
end
