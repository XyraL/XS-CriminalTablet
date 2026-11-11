Config.Intel = Config.Intel or { enabled = true, alertCooldownMinutes = 5, hqRadius = 60.0, hqSeconds = 30, alertKills = true, mapPing = true, keepDays = 30 }
Config.Approvals = Config.Approvals or { logos = true, tags = true, maxPending = 3, autoApprove = false }
Config.FrameworkLink = Config.FrameworkLink or { enabled = false }
Config.Graffiti.spray = Config.Graffiti.spray or { prop = '', mist = true, sound = true, volume = 0.5, walkUp = true, reach = 3.0 }

-- ─────────────────────────────────────────────────────────────
-- Live settings: the parts of config.lua staff can change from the
-- builder without a restart. Each field is { key, type, label, hint, ... }
-- where key is the path inside Config ('War.raid.cost'). Number segments
-- index arrays, so 'DefaultRanks.0.permissions' is DefaultRanks[0].
-- ─────────────────────────────────────────────────────────────
Settings = { fields = {}, byKey = {} }

local TIERS = {}
for _, t in ipairs(Config.Rep.tiers) do TIERS[#TIERS + 1] = t.name end

Settings.Sections = {
    { id = 'tablet', icon = 'fa-tablet-screen-button', label = 'Tablet', hint = 'How players get the tablet open.', fields = {
        { 'DeviceItem', 'item', 'Tablet item', 'Using this item opens the tablet. It also has to be in your inventory items list.' },
        { 'OpenCommandNeedsItem', 'bool', 'The command needs the item too', 'Off lets anyone in a crew open the tablet by command without carrying one.' },
        { 'NoGangMessage', 'text', 'Message for players with no crew', 'Shown on the locked screen. Say where your server takes crew applications.', max = 200 },
    } },
    { id = 'members', icon = 'fa-users', label = 'Members and ranks', hint = 'Crew size, the rank people join on, and the starting ladder for new crews.', fields = {
        { 'MaxMembers', 'int', 'Members per crew', 'Before upgrades and perks add to it. A crew with its own cap set keeps that.', min = 1, max = 500 },
        { 'MaxRanks', 'int', 'Ranks per crew', nil, min = 2, max = 20 },
        { 'JoinGrade', 'int', 'Rank new members join on', 'Grade number. If a crew has no rank at that grade they join on the nearest one below.', min = 0, max = 20 },
        { 'DefaultRanks.0.permissions', 'perms', 'What the bottom rank can do in a new crew', 'Only for crews made from now on. Bosses change their own ranks under Roster.' },
        { 'GangInactivityDays', 'int', 'Days before a member shows as inactive', nil, min = 1, max = 120, unit = 'days' },
    } },
    { id = 'framework', icon = 'fa-link', label = 'Framework gangs', hint = 'Tie crews to the gangs your framework already has. Pick the gang on each crew in Crews.', fields = {
        { 'FrameworkLink.enabled', 'bool', 'Link crews to framework gangs', 'Members of a linked framework gang join the crew, and leave it when the framework takes them out.' },
        { 'FrameworkLink.matchGrades', 'bool', 'Framework grade sets the crew rank', 'Off puts everyone from the framework gang on the usual starting rank. On works best when the crew\'s ranks match the framework gang\'s grades.', needs = 'FrameworkLink.enabled' },
        { 'SyncFrameworkGang', 'bool', 'Write every crew into the framework too', 'Other scripts then see crew members as being in a gang named after the crew. Linked crews always do this.' },
    } },
    { id = 'rep', icon = 'fa-star', label = 'Rep', hint = 'What crews earn and lose rep for.', fields = {
        { 'Rep.max', 'int', 'Most rep a crew can hold', nil, min = 1000, max = 10000000 },
        { 'Rep.friendlyFirePenalty', 'int', 'Killing your own crew costs', nil, min = 0, max = 100000, unit = 'rep' },
        { 'Rep.rewards.member_recruited', 'int', 'New member joins', nil, min = -100000, max = 100000, unit = 'rep' },
        { 'Rep.rewards.zone_captured', 'int', 'Block taken', nil, min = -100000, max = 100000, unit = 'rep' },
        { 'Rep.rewards.zone_lost', 'int', 'Block lost', nil, min = -100000, max = 100000, unit = 'rep' },
        { 'Rep.rewards.raid_won', 'int', 'Raid won', nil, min = -100000, max = 100000, unit = 'rep' },
        { 'Rep.rewards.raid_lost', 'int', 'Raid lost', nil, min = -100000, max = 100000, unit = 'rep' },
        { 'Rep.rewards.war_won', 'int', 'War won', nil, min = -100000, max = 100000, unit = 'rep' },
        { 'Rep.rewards.war_lost', 'int', 'War lost', nil, min = -100000, max = 100000, unit = 'rep' },
        { 'Rep.rewards.graffiti_sprayed', 'int', 'Tag sprayed', nil, min = -100000, max = 100000, unit = 'rep' },
        { 'Rep.rewards.graffiti_covered', 'int', 'Rival tag covered', nil, min = -100000, max = 100000, unit = 'rep' },
    } },
    { id = 'turf', icon = 'fa-map-location-dot', label = 'Turf', hint = 'How blocks are worked and held.', fields = {
        { 'Territory.influenceSeconds', 'int', 'Time for one person to take a block', 'From nothing to all of it, standing in it alone.', min = 10, max = 7200, unit = 's' },
        { 'Territory.rivalInfluenceCap', 'int', 'Most a rival can build on someone else\'s block', nil, min = 0, max = 100, unit = '%' },
        { 'Territory.influenceDecayPerMinute', 'num', 'Share lost per minute with nobody there', '0 means it never fades.', min = 0, max = 20, step = 0.1, unit = '%/min' },
        { 'Territory.minPresence', 'int', 'People needed to move anything', nil, min = 1, max = 20 },
        { 'Territory.perExtraMember', 'num', 'Each extra person counts as', 'Of one person. 0.45 means the second person adds almost half again.', min = 0, max = 2, step = 0.05 },
        { 'Territory.holderWeight', 'num', 'Holding crew defends at', 'Times a normal person, on their own block.', min = 0.5, max = 5, step = 0.05, unit = 'x' },
        { 'Territory.minTierToContest', 'select', 'Lowest tier that can work rival turf', nil, options = TIERS },
        { 'Territory.alertOnContest', 'bool', 'Warn the crew when their block is being worked', nil },
        { 'Territory.gangLocked', 'bool', 'Rivals cannot use a crew\'s things on its block', 'Vault, benches and the rest only open for the crew that holds the block.' },
        { 'Placement.requireZoneOrHq', 'bool', 'Property only on held turf or near the HQ', nil },
        { 'Placement.hqBuildRadius', 'num', 'Building range around the HQ', nil, min = 5, max = 500, step = 1, unit = 'm' },
    } },
    { id = 'war', icon = 'fa-crosshairs', label = 'Raids and wars', hint = 'Costs, timings and what changes hands.', fields = {
        { 'War.enabled', 'bool', 'Raids and wars', 'Off hides the War Room and stops new raids and wars.' },
        { 'War.raid.cost', 'int', 'Raid cost', 'Taken from the attacking crew\'s treasury.', min = 0, max = 100000000, unit = '$', needs = 'War.enabled' },
        { 'War.raid.prepSeconds', 'int', 'Warning before a raid goes live', nil, min = 0, max = 3600, unit = 's', needs = 'War.enabled' },
        { 'War.raid.durationSeconds', 'int', 'Raid length', nil, min = 60, max = 7200, unit = 's', needs = 'War.enabled' },
        { 'War.raid.holdSeconds', 'int', 'Time to hold the HQ to win', nil, min = 10, max = 3600, unit = 's', needs = 'War.enabled' },
        { 'War.raid.radius', 'num', 'How close to the HQ counts', nil, min = 5, max = 300, step = 1, unit = 'm', needs = 'War.enabled' },
        { 'War.raid.minAttackers', 'int', 'Attackers needed', nil, min = 1, max = 30, needs = 'War.enabled' },
        { 'War.raid.minDefendersOnline', 'int', 'Defenders that must be online', nil, min = 0, max = 30, needs = 'War.enabled' },
        { 'War.raid.cooldownMinutes', 'int', 'Between raids by the same crew', nil, min = 0, max = 10080, unit = 'min', needs = 'War.enabled' },
        { 'War.raid.immunityMinutes', 'int', 'Breather for the crew that was raided', nil, min = 0, max = 10080, unit = 'min', needs = 'War.enabled' },
        { 'War.raid.cashCutPct', 'int', 'Share of the loser\'s treasury taken', nil, min = 0, max = 100, unit = '%', needs = 'War.enabled' },
        { 'War.raid.cashCutMax', 'int', 'Most one raid can take', nil, min = 0, max = 100000000, unit = '$', needs = 'War.enabled' },
        { 'War.raid.captureZoneOnWin', 'bool', 'A won raid also takes a block', nil, needs = 'War.enabled' },
        { 'War.war.declareCost', 'int', 'War cost', 'Taken when the other crew accepts.', min = 0, max = 100000000, unit = '$', needs = 'War.enabled' },
        { 'War.war.requestMinutes', 'int', 'Time to answer a war request', 'Wars only start when the other crew accepts.', min = 1, max = 60, unit = 'min', needs = 'War.enabled' },
        { 'War.war.requestCooldownMinutes', 'int', 'Wait before asking the same crew again', 'After they say no or let it run out.', min = 0, max = 1440, unit = 'min', needs = 'War.enabled' },
        { 'War.war.durationMinutes', 'int', 'War length', nil, min = 5, max = 1440, unit = 'min', needs = 'War.enabled' },
        { 'War.war.scoreToWin', 'int', 'Lead needed to win outright', nil, min = 1, max = 1000, needs = 'War.enabled' },
        { 'War.war.killScore', 'int', 'Points per kill', nil, min = 0, max = 100, needs = 'War.enabled' },
        { 'War.war.repeatKillCooldownSeconds', 'int', 'Killing the same person again scores after', nil, min = 0, max = 3600, unit = 's', needs = 'War.enabled' },
        { 'War.war.cooldownMinutes', 'int', 'Between wars by the same crew', nil, min = 0, max = 10080, unit = 'min', needs = 'War.enabled' },
        { 'War.war.stashWindowMinutes', 'int', 'Time the winner has to loot the safe', nil, min = 1, max = 240, unit = 'min', needs = 'War.enabled' },
        { 'War.objectives.enabled', 'bool', 'Objectives in wars', 'Points on both crews\' blocks to take and hold. Taking one scores and holding it keeps scoring.', needs = 'War.enabled' },
        { 'War.objectives.count', 'int', 'Objectives per war', nil, min = 1, max = 5, needs = 'War.objectives.enabled' },
        { 'War.objectives.radius', 'num', 'How close counts as on it', nil, min = 3, max = 60, step = 1, unit = 'm', needs = 'War.objectives.enabled' },
        { 'War.objectives.captureSeconds', 'int', 'Time alone on it to take it', nil, min = 5, max = 300, unit = 's', needs = 'War.objectives.enabled' },
        { 'War.objectives.capturePoints', 'int', 'Score for taking one', nil, min = 0, max = 50, needs = 'War.objectives.enabled' },
        { 'War.objectives.holdSeconds', 'int', 'Holding one scores every', nil, min = 10, max = 600, unit = 's', needs = 'War.objectives.enabled' },
        { 'War.objectives.holdPoints', 'int', 'Score each time', nil, min = 0, max = 50, needs = 'War.objectives.enabled' },
        { 'War.killFeed', 'bool', 'Kill feed during raids and wars', 'Shows who took out whom, by name, to both crews.', needs = 'War.enabled' },
        { 'War.stash.enabled', 'bool', 'Winning a war opens the loser\'s safe', nil, needs = 'War.enabled' },
        { 'War.stash.lootSeconds', 'int', 'Time to crack the safe', nil, min = 1, max = 120, unit = 's', needs = 'War.stash.enabled' },
        { 'War.stash.cashPct', 'int', 'Share of the loser\'s treasury in the safe', nil, min = 0, max = 100, unit = '%', needs = 'War.stash.enabled' },
        { 'War.stash.cashMax', 'int', 'Most cash in the safe', nil, min = 0, max = 100000000, unit = '$', needs = 'War.stash.enabled' },
        { 'War.stash.lootItems', 'bool', 'The safe also gives items from their vault', nil, needs = 'War.stash.enabled' },
        { 'War.stash.maxItemStacks', 'int', 'Item stacks taken', nil, min = 0, max = 50, needs = 'War.stash.lootItems' },
    } },
    { id = 'contracts', icon = 'fa-file-signature', label = 'Contracts', hint = 'The job board.', fields = {
        { 'Contracts.enabled', 'bool', 'Contracts', 'Off hides the Contracts app.' },
        { 'Contracts.boardSize', 'int', 'Jobs on the board', nil, min = 1, max = 20, needs = 'Contracts.enabled' },
        { 'Contracts.rotateMinutes', 'int', 'Board changes every', nil, min = 5, max = 1440, unit = 'min', needs = 'Contracts.enabled' },
        { 'Contracts.dropBonusPct', 'int', 'Crew Contracts bonus', 'Extra cash and rep on every job for a crew that bought Crew Contracts.', min = 0, max = 200, unit = '%', needs = 'Contracts.enabled' },
        { 'TasksCoop.enabled', 'bool', 'Jobs with a partner', nil, needs = 'Contracts.enabled' },
        { 'TasksCoop.maxCrewSize', 'int', 'People on one job', nil, min = 2, max = 8, needs = 'TasksCoop.enabled' },
        { 'TasksCoop.rewardBonusPct', 'int', 'Extra pay for working together', nil, min = 0, max = 500, unit = '%', needs = 'TasksCoop.enabled' },
    } },
    { id = 'garage', icon = 'fa-warehouse', label = 'Garage', hint = 'Crew cars.', fields = {
        { 'Garage.enabled', 'bool', 'Crew garage', 'Off hides the Garage app.' },
        { 'Garage.baseSlots', 'int', 'Cars per crew', 'Before upgrades add to it.', min = 0, max = 100, needs = 'Garage.enabled' },
        { 'Garage.spawnRadius', 'num', 'How close to the garage point', nil, min = 2, max = 100, step = 1, unit = 'm', needs = 'Garage.enabled' },
        { 'Garage.platePrefix', 'text', 'Plate prefix', nil, max = 4, upper = true, needs = 'Garage.enabled' },
        { 'Garage.giveKeys', 'bool', 'Hand over keys when a car comes out', nil, needs = 'Garage.enabled' },
        { 'Garage.warpIn', 'bool', 'Put the player in the car when it comes out', nil, needs = 'Garage.enabled' },
    } },
    { id = 'graffiti', icon = 'fa-spray-can', label = 'Graffiti', hint = 'Tags on walls.', fields = {
        { 'Graffiti.enabled', 'bool', 'Graffiti', 'Off hides the Studio and stops new tags.' },
        { 'Graffiti.requiredItem', 'item', 'Item needed to spray', nil, off = true, needs = 'Graffiti.enabled' },
        { 'Graffiti.consumeItem', 'bool', 'Spraying uses up the item', nil, needs = 'Graffiti.enabled' },
        { 'Graffiti.maxPerGang', 'int', 'Tags per crew', nil, min = 1, max = 500, needs = 'Graffiti.enabled' },
        { 'Graffiti.maxTotal', 'int', 'Tags on the whole map', nil, min = 1, max = 5000, needs = 'Graffiti.enabled' },
        { 'Graffiti.sprayDuration', 'int', 'Time to spray', 'After a quick shake of the can.', min = 1, max = 60, unit = 's', needs = 'Graffiti.enabled' },
        { 'Graffiti.spray.mist', 'bool', 'Paint mist from the can', nil, needs = 'Graffiti.enabled' },
        { 'Graffiti.spray.sound', 'bool', 'Can rattle and spray sound', 'Players nearby hear it too.', needs = 'Graffiti.enabled' },
        { 'Graffiti.spray.volume', 'num', 'Can rattle volume', 'The spray hiss is the game\'s own sound.', min = 0, max = 1, step = 0.05, needs = 'Graffiti.spray.sound' },
        { 'Graffiti.spray.walkUp', 'bool', 'Walk up to the wall first', 'Off sprays from where you stand.', needs = 'Graffiti.enabled' },
        { 'Graffiti.spray.reach', 'num', 'Highest a tag can go', 'How far above your feet the middle of a tag can sit.', min = 1, max = 10, step = 0.1, unit = 'm', needs = 'Graffiti.enabled' },
        { 'Graffiti.heldZonesOnly', 'bool', 'Only on blocks the crew holds', nil, needs = 'Graffiti.enabled' },
        { 'Graffiti.allowCovering', 'bool', 'Rivals can spray over a tag', nil, needs = 'Graffiti.enabled' },
        { 'Graffiti.expiryDays', 'int', 'Tags fade after', '0 means they stay until covered or removed.', min = 0, max = 365, unit = 'days', needs = 'Graffiti.enabled' },
        { 'Graffiti.renderDistance', 'num', 'Seen from', nil, min = 10, max = 200, step = 1, unit = 'm', needs = 'Graffiti.enabled' },
    } },
    { id = 'medic', icon = 'fa-kit-medical', label = 'Street doc', hint = 'One doctor every crew shares; crews buy access. Move him on the Street doc page.', fields = {
        { 'Medic.enabled', 'bool', 'Street doc', 'Off hides him for every crew.' },
        { 'Medic.healPrice', 'int', 'Patch-up price', '0 is free.', min = 0, max = 1000000, unit = '$', needs = 'Medic.enabled' },
        { 'Medic.revivePrice', 'int', 'Revive price', 'For bringing back a downed member carried in to him.', min = 0, max = 1000000, unit = '$', needs = 'Medic.enabled' },
        { 'Medic.payFrom', 'select', 'Who pays', 'crew is the treasury.', options = { 'cash', 'bank', 'crew' }, needs = 'Medic.enabled' },
        { 'Medic.treatSeconds', 'int', 'How long he takes', nil, min = 1, max = 60, unit = 's', needs = 'Medic.enabled' },
        { 'Medic.reviveRange', 'num', 'How close a downed member has to be', nil, min = 1, max = 15, step = 0.5, unit = 'm', needs = 'Medic.enabled' },
        { 'Medic.cooldownSeconds', 'int', 'Between visits', 'Per player.', min = 0, max = 3600, unit = 's', needs = 'Medic.enabled' },
        { 'Medic.pedModel', 'text', 'What he looks like', 'A ped model name.', max = 48, needs = 'Medic.enabled' },
        { 'Medic.scenario', 'text', 'What he does while he waits', 'A GTA scenario name. Empty to have him stand still.', max = 48, needs = 'Medic.enabled' },
    } },
    { id = 'radial', icon = 'fa-circle-dot', label = 'Field radial', hint = 'The wheel crews use in the street. Pick its actions on the Radial page.', fields = {
        { 'Radial.enabled', 'bool', 'Field radial', nil },
        { 'Radial.key', 'text', 'Key', 'Players can still change it for themselves in their key settings.', max = 16, upper = true, restart = true, needs = 'Radial.enabled' },
        { 'Radial.actionSeconds', 'int', 'Time for cuffing, bagging and the rest', nil, min = 1, max = 30, unit = 's', needs = 'Radial.enabled' },
        { 'Radial.cuffItem', 'item', 'Item needed to cuff', nil, off = true, needs = 'Radial.enabled' },
        { 'Radial.bagItem', 'item', 'Item needed to bag someone', nil, off = true, needs = 'Radial.enabled' },
        { 'Radial.rob.requireHandsUp', 'bool', 'Robbing needs hands up or cuffs', nil, needs = 'Radial.enabled' },
        { 'Radial.rob.cashOnly', 'bool', 'Robbing only takes cash', nil, needs = 'Radial.enabled' },
        { 'Radial.rob.maxItemStacks', 'int', 'Item stacks taken in a robbery', nil, min = 0, max = 20, needs = 'Radial.enabled' },
        { 'Radial.slash.item', 'item', 'Item needed to slash a tyre', nil, needs = 'Radial.enabled' },
        { 'Radial.slash.consume', 'bool', 'Slashing uses up the item', nil, needs = 'Radial.enabled' },
        { 'Radial.slash.seconds', 'int', 'Time to slash a tyre', nil, min = 1, max = 30, unit = 's', needs = 'Radial.enabled' },
    } },
    { id = 'money', icon = 'fa-vault', label = 'Treasury and vault', hint = 'Crew money and storage.', fields = {
        { 'Bank.account', 'select', 'Money comes from and goes to', nil, options = { 'bank', 'cash' } },
        { 'Bank.ledgerLimit', 'int', 'Ledger rows shown', nil, min = 5, max = 200 },
        { 'Vault.slots', 'int', 'Vault slots', 'Before upgrades and perks add to it.', min = 5, max = 500 },
        { 'Vault.maxWeight', 'int', 'Vault weight', 'In grams, before upgrades and perks.', min = 1000, max = 10000000, unit = 'g' },
    } },
    { id = 'standing', icon = 'fa-ranking-star', label = 'Standing', hint = 'The crew ranking.', fields = {
        { 'Analytics.enabled', 'bool', 'Standing', 'Off hides the Standing app.' },
        { 'Analytics.limit', 'int', 'Crews listed', nil, min = 3, max = 100, needs = 'Analytics.enabled' },
        { 'Analytics.publicTreasury', 'bool', 'Show every crew\'s treasury', nil, needs = 'Analytics.enabled' },
        { 'Analytics.weights.rep', 'num', 'Score per rep', nil, min = 0, max = 100, step = 0.1, needs = 'Analytics.enabled' },
        { 'Analytics.weights.territory', 'int', 'Score per block held', nil, min = 0, max = 100000, needs = 'Analytics.enabled' },
        { 'Analytics.weights.members', 'int', 'Score per member', nil, min = 0, max = 100000, needs = 'Analytics.enabled' },
        { 'Analytics.weights.treasury', 'num', 'Score per dollar banked', nil, min = 0, max = 10, step = 0.01, needs = 'Analytics.enabled' },
        { 'Analytics.weights.warWins', 'int', 'Score per war won', nil, min = 0, max = 100000, needs = 'Analytics.enabled' },
    } },
    { id = 'intel', icon = 'fa-user-secret', label = 'Rival intel', hint = 'The Rivals app and the alerts crews get when a rival moves on them.', fields = {
        { 'Intel.enabled', 'bool', 'Rival intel', 'Off hides the Rivals app and stops the alerts.' },
        { 'Intel.alertCooldownMinutes', 'int', 'Same alert again after', 'For the same place and the same rival.', min = 1, max = 120, unit = 'min', needs = 'Intel.enabled' },
        { 'Intel.hqRadius', 'num', 'Rivals near the HQ within', nil, min = 10, max = 300, step = 5, unit = 'm', needs = 'Intel.enabled' },
        { 'Intel.hqSeconds', 'int', 'For at least', nil, min = 5, max = 600, unit = 's', needs = 'Intel.enabled' },
        { 'Intel.alertKills', 'bool', 'Tell a crew when a rival kills one of theirs', nil, needs = 'Intel.enabled' },
        { 'Intel.mapPing', 'bool', 'Alerts flash on the map', nil, needs = 'Intel.enabled' },
        { 'Intel.keepDays', 'int', 'History kept for', nil, min = 1, max = 365, unit = 'days', needs = 'Intel.enabled' },
    } },
    { id = 'approvals', icon = 'fa-image', label = 'Crew uploads', hint = 'Logos and tag photos crews send in. They wait on the Approvals page.', fields = {
        { 'Approvals.logos', 'bool', 'Crews can send a logo', nil },
        { 'Approvals.tags', 'bool', 'Crews can send photos to spray', nil },
        { 'Approvals.maxPending', 'int', 'Waiting at once per crew', 'For each kind.', min = 1, max = 20 },
        { 'Approvals.autoApprove', 'bool', 'Approve everything without staff', 'Anything a crew links goes straight into the game. Leave this off unless you trust every crew.' },
    } },
    { id = 'blackmarket', icon = 'fa-comments', label = 'Blackmarket', hint = 'The anonymous chat.', fields = {
        { 'Chat.enabled', 'bool', 'Blackmarket', 'Off hides the Blackmarket app.' },
        { 'Chat.maxMessageLength', 'int', 'Longest message', nil, min = 20, max = 1000, unit = 'chars', needs = 'Chat.enabled' },
        { 'Chat.worldHistoryLimit', 'int', 'World messages kept', nil, min = 10, max = 1000, needs = 'Chat.enabled' },
        { 'Chat.dmHistoryLimit', 'int', 'Messages kept per conversation', nil, min = 10, max = 1000, needs = 'Chat.enabled' },
    } },
    { id = 'drugs', icon = 'fa-pills', label = 'Selling drugs', hint = 'Selling bricks to people in the street.', fields = {
        { 'DrugSelling.enabled', 'bool', 'Selling drugs', nil, restart = true },
        { 'DrugSelling.sellRadius', 'num', 'How close someone has to be', nil, min = 1, max = 30, step = 0.5, unit = 'm', needs = 'DrugSelling.enabled' },
        { 'DrugSelling.cooldownSeconds', 'int', 'Between sales', nil, min = 0, max = 3600, unit = 's', needs = 'DrugSelling.enabled' },
        { 'DrugSelling.account', 'select', 'Paid into', nil, options = { 'cash', 'bank' }, needs = 'DrugSelling.enabled' },
    } },
    { id = 'testmode', icon = 'fa-flask', label = 'Test mode', hint = 'Practice captures and raids against stand-ins.', fields = {
        { 'TestMode.enabled', 'bool', 'Staff can use test mode', nil },
        { 'TestMode.defenderCount', 'int', 'Stand-in defenders', nil, min = 0, max = 20, needs = 'TestMode.enabled' },
        { 'TestMode.defenderModel', 'text', 'Defender model', nil, max = 48, needs = 'TestMode.enabled' },
        { 'TestMode.defenderWeapon', 'text', 'Defender weapon', nil, max = 48, upper = true, needs = 'TestMode.enabled' },
        { 'TestMode.defenderAccuracy', 'int', 'Defender accuracy', nil, min = 0, max = 100, unit = '%', needs = 'TestMode.enabled' },
    } },
}

-- The wheel's actions are edited on the builder's Radial page, not in the
-- settings list, so they are stored like any setting but kept hidden there.
do
    local ids = {}
    for id in pairs(Config.Radial.actions) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, section in ipairs(Settings.Sections) do
        if section.id == 'radial' then
            for _, id in ipairs(ids) do
                section.fields[#section.fields + 1] = { 'Radial.actions.' .. id .. '.enabled', 'bool', 'Show ' .. id, nil, hidden = true }
                section.fields[#section.fields + 1] = { 'Radial.actions.' .. id .. '.label', 'text', 'Name for ' .. id, nil, max = 24, hidden = true }
            end
            section.fields[#section.fields + 1] = { 'Radial.order', 'order', 'Order round the wheel', nil, options = ids, hidden = true }
        end
    end
end

for _, section in ipairs(Settings.Sections) do
    local list = {}
    for _, f in ipairs(section.fields) do
        local def = { key = f[1], type = f[2], label = f[3], hint = f[4], section = section.id }
        for k, v in pairs(f) do
            if type(k) == 'string' then def[k] = v end
        end
        list[#list + 1] = def
        Settings.fields[#Settings.fields + 1] = def
        Settings.byKey[def.key] = def
    end
    section.fields = list
end

local function path(key)
    local parts = {}
    for part in key:gmatch('[^%.]+') do parts[#parts + 1] = tonumber(part) or part end
    return parts
end

function Settings.Read(key)
    local node = Config
    for _, part in ipairs(path(key)) do
        if type(node) ~= 'table' then return nil end
        node = node[part]
    end
    return node
end

function Settings.Write(key, value)
    local parts = path(key)
    local node = Config
    for i = 1, #parts - 1 do
        if type(node[parts[i]]) ~= 'table' then node[parts[i]] = {} end
        node = node[parts[i]]
    end
    node[parts[#parts]] = value
end

function Settings.Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Settings.Copy(x) end
    return out
end

function Settings.Same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    if #a ~= #b then return false end
    for k, v in pairs(a) do
        if not Settings.Same(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function slug(value, max)
    return (tostring(value or ''):lower():gsub('[^%w_%-]', '')):sub(1, max or 48)
end

local function within(def, n)
    if def.min and n < def.min then n = def.min end
    if def.max and n > def.max then n = def.max end
    return n
end

function Settings.Clean(def, value)
    local kind = def.type
    if kind == 'bool' then
        if type(value) == 'boolean' then return value end
        if value == 1 or value == '1' or value == 'true' then return true end
        if value == 0 or value == '0' or value == 'false' then return false end
        return nil
    elseif kind == 'int' then
        local n = tonumber(value)
        if not n or n ~= n then return nil end
        return within(def, math.floor(n + 0.5))
    elseif kind == 'num' then
        local n = tonumber(value)
        if not n or n ~= n then return nil end
        local step = def.step or 0.1
        n = math.floor(n / step + 0.5) * step
        return within(def, math.floor(n * 1000 + 0.5) / 1000)
    elseif kind == 'text' then
        if value == nil or type(value) == 'table' then return nil end
        local s = tostring(value):gsub('[%c]', ''):match('^%s*(.-)%s*$')
        if def.upper then s = s:upper():gsub('[^%u%d]', '') end
        s = s:sub(1, def.max or 64)
        if s == '' then return nil end
        return s
    elseif kind == 'select' then
        for _, option in ipairs(def.options or {}) do
            if option == value then return value end
        end
        return nil
    elseif kind == 'item' then
        local s = (value == false or value == nil) and '' or slug(value, 64)
        if s ~= '' then return s end
        if def.off then return '' end
        return nil
    elseif kind == 'perms' then
        if type(value) ~= 'table' then return nil end
        return XSTablet.SanitizePermissions(value)
    elseif kind == 'order' then
        if type(value) ~= 'table' then return nil end
        local known, seen, out = {}, {}, {}
        for _, o in ipairs(def.options or {}) do known[o] = true end
        for _, v in ipairs(value) do
            if known[v] and not seen[v] then seen[v] = true; out[#out + 1] = v end
        end
        for _, o in ipairs(def.options or {}) do
            if not seen[o] then out[#out + 1] = o end
        end
        return out
    end
    return nil
end

function Settings.Apply(values)
    if type(values) ~= 'table' then return end
    for key, value in pairs(values) do
        local def = Settings.byKey[key]
        if def then
            local clean = Settings.Clean(def, value)
            if clean ~= nil then Settings.Write(key, clean) end
        end
    end
end

function Settings.Public()
    local sections = {}
    for _, section in ipairs(Settings.Sections) do
        local fields = {}
        for _, def in ipairs(section.fields) do
            local out = {}
            for k, v in pairs(def) do out[k] = v end
            fields[#fields + 1] = out
        end
        sections[#sections + 1] = { id = section.id, icon = section.icon, label = section.label, hint = section.hint, fields = fields }
    end
    return sections
end
