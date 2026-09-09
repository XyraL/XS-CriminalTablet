-- ─────────────────────────────────────────────────────────────
-- Drug selling: works anywhere, not gated to gang territory. The client
-- only checks "is there an NPC nearby" as a light gate against selling
-- mid-air with nobody around — the server is the actual authority on
-- inventory count and cooldown, and pays out regardless of gang status
-- (rep on top of cash only if the seller's in a gang).
-- ─────────────────────────────────────────────────────────────
Drugs = {}

local byItem = {}
for _, d in ipairs(Config.DrugSelling.items) do byItem[d.item] = d end

local lastSoldAt = {} -- [src] = unix ms

function Drugs.GetSellable(src)
    local list = {}
    for _, d in ipairs(Config.DrugSelling.items) do
        local count = exports.ox_inventory:Search(src, 'count', d.item)
        if (count or 0) > 0 then
            list[#list + 1] = { item = d.item, label = d.label, price = d.price, count = count }
        end
    end
    return list
end

function Drugs.Sell(src, item)
    local def = byItem[item]
    if not def then return false, 'unknown item' end

    local now = os.time() * 1000
    local cdMs = Config.DrugSelling.cooldownSeconds * 1000
    if now - (lastSoldAt[src] or 0) < cdMs then return false, 'too soon' end

    local count = exports.ox_inventory:Search(src, 'count', item)
    if (count or 0) < 1 then return false, "you don't have that" end

    exports.ox_inventory:RemoveItem(src, item, 1)
    Framework.AddMoney(src, Config.DrugSelling.account, def.price, 'xs-drug-sale')
    lastSoldAt[src] = now

    local cid = Framework.GetCitizenId(src)
    local gang = cid and Gangs.GetByCitizen(cid)
    if gang then
        Gangs.AddMemberRep(cid, def.rep, 'drug_sale:' .. item)
        Gangs.Log(gang.id, ('%s sold %s for $%d (+%d rep)'):format(Framework.GetName(src) or cid, def.label, def.price, def.rep))
    end

    return true, def.price
end

lib.callback.register('XS-CriminalTablet:drugs:getSellable', function(src)
    return Drugs.GetSellable(src)
end)

lib.callback.register('XS-CriminalTablet:drugs:sell', function(src, item)
    local ok, res = Drugs.Sell(src, item)
    return { ok = ok, error = not ok and res or nil, price = ok and res or nil }
end)
