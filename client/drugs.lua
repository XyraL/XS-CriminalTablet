-- ─────────────────────────────────────────────────────────────
-- Drug selling client: target a nearby NPC ped to sell. The targeted ped
-- is just an interaction prompt, not a real transaction partner — server
-- is the authority on count/cooldown/payout. A 5s progress bar plays out
-- the "deal" before the sale actually commits.
-- ─────────────────────────────────────────────────────────────
if Config.DrugSelling.enabled then
    local hasTarget = GetResourceState('ox_target') == 'started'

    local function sellMenuFor(ped)
        if not DoesEntityExist(ped) then return end
        local sellable = lib.callback.await('XS-CriminalTablet:drugs:getSellable', false)
        if not sellable or #sellable == 0 then
            lib.notify({ description = "You don't have anything to sell.", type = 'error' })
            return
        end

        local options = {}
        for _, s in ipairs(sellable) do
            options[#options + 1] = {
                title = s.label,
                description = ('You have %d — $%d each'):format(s.count, s.price),
                icon = 'fas fa-sack-dollar',
                onSelect = function()
                    if not DoesEntityExist(ped) then
                        lib.notify({ description = 'They walked off.', type = 'error' })
                        return
                    end

                    local myPed = PlayerPedId()
                    ClearPedTasksImmediately(ped) -- stop them wandering off mid-deal
                    RequestAnimDict('mp_common')
                    local waited = 0
                    while not HasAnimDictLoaded('mp_common') and waited < 1000 do Wait(50); waited = waited + 50 end
                    TaskPlayAnim(myPed, 'mp_common', 'givetake1_a', 8.0, -8.0, -1, 49, 0, false, false, false)
                    TaskPlayAnim(ped, 'mp_common', 'givetake1_b', 8.0, -8.0, -1, 49, 0, false, false, false)

                    local completed = lib.progressBar({
                        duration = 5000,
                        label = 'Making the deal...',
                        canCancel = true,
                        disable = { move = true, car = true, combat = true },
                    })

                    ClearPedTasks(myPed)
                    if DoesEntityExist(ped) then
                        ClearPedTasks(ped)
                        TaskWanderStandard(ped, 10.0, 10)
                    end

                    if not completed then return end

                    local res = lib.callback.await('XS-CriminalTablet:drugs:sell', false, s.item)
                    if res and res.ok then
                        lib.notify({ description = ('Sold for $%d.'):format(res.price), type = 'success' })
                    else
                        lib.notify({ description = (res and res.error) or 'Failed to sell', type = 'error' })
                    end
                end,
            }
        end

        lib.registerContext({ id = 'xs_selldrug', title = 'Sell', options = options })
        lib.showContext('xs_selldrug')
    end

    -- GetGamePool('CPed') returns every ped handle currently streamed in,
    -- players included — filter those out for the fallback's nearest-ped lookup.
    local function nearestPed()
        local myPed = PlayerPedId()
        local pos = GetEntityCoords(myPed)
        local nearest, nearestDist = nil, Config.DrugSelling.sellRadius
        for _, ped in ipairs(GetGamePool('CPed')) do
            if ped ~= myPed and not IsPedAPlayer(ped) and DoesEntityExist(ped) then
                local d = #(pos - GetEntityCoords(ped))
                if d <= nearestDist then nearest, nearestDist = ped, d end
            end
        end
        return nearest
    end

    if hasTarget then
        local ok = pcall(function()
            exports.ox_target:addGlobalPed({
                {
                    name = 'xs_sell_drugs',
                    label = 'Sell Drugs',
                    icon = 'fas fa-sack-dollar',
                    distance = 2.5,
                    canInteract = function(entity)
                        return DoesEntityExist(entity) and not IsPedAPlayer(entity)
                    end,
                    onSelect = function(data) sellMenuFor(data.entity) end,
                },
            })
        end)
        if not ok then hasTarget = false end
    end

    -- Fallback if ox_target isn't installed (or the addGlobalPed call above
    -- failed for any reason): /selldrug finds the nearest NPC itself.
    if not hasTarget then
        RegisterCommand(Config.DrugSelling.command, function()
            local ped = nearestPed()
            if not ped then
                lib.notify({ description = 'Nobody nearby to sell to.', type = 'error' })
                return
            end
            sellMenuFor(ped)
        end, false)
    end
end
