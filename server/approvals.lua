-- ─────────────────────────────────────────────────────────────
-- Crew uploads waiting on staff: a crew's own logo, and their own photos
-- to spray as tags. Nothing a crew sends is seen by anyone else until
-- staff approve it in the builder.
-- ─────────────────────────────────────────────────────────────
Approvals = {}

local KIND_PERM = { logo = 'manage_motd', tag = 'manage_graffiti' }
local KIND_NAME = { logo = 'crew logo', tag = 'tag photo' }

local function now() return os.time() * 1000 end
local function staff(src) return src and IsPlayerAceAllowed(src, Config.AdminAce) end

-- A direct https link to an image file. Discord and Imgur attachment links
-- keep the file type in the path, before any query string.
function Approvals.CleanUrl(url)
    url = tostring(url or ''):gsub('%s', '')
    if #url > 500 then return nil, 'that link is too long' end
    local path = url:match('^https://[%w%-%.]+%.%a+(/[^%?#]*)')
    if not path then return nil, 'paste a direct https link to the image' end
    path = path:lower()
    if not (path:match('%.png$') or path:match('%.jpe?g$') or path:match('%.webp$') or path:match('%.gif$')) then
        return nil, 'the link has to point at a .png, .jpg, .webp or .gif'
    end
    return url
end

function Approvals.Submit(src, kind, url, label)
    if not KIND_PERM[kind] then return false, 'unknown kind' end
    local cfg = Config.Approvals
    if kind == 'logo' and not cfg.logos then return false, 'crew logos are switched off' end
    if kind == 'tag' and not cfg.tags then return false, 'custom tags are switched off' end
    local gang = Gangs.GetBySource(src)
    if not gang then return false, 'no gang' end
    local cid = Framework.GetCitizenId(src)
    if gang.owner ~= cid and not Gangs.HasPerm(src, KIND_PERM[kind]) then return false, 'no permission' end
    local clean, err = Approvals.CleanUrl(url)
    if not clean then return false, err end
    label = tostring(label or ''):gsub('[%c]', ''):match('^%s*(.-)%s*$'):sub(1, 40)
    if kind == 'tag' and #label < 2 then return false, 'give it a name' end
    if kind == 'logo' then label = gang.label end
    local pending = MySQL.scalar.await("SELECT COUNT(*) FROM `xs_submissions` WHERE `gang_id` = ? AND `kind` = ? AND `status` = 'pending'", { gang.id, kind }) or 0
    if pending >= (cfg.maxPending or 3) then return false, ('you already have %d waiting for staff'):format(pending) end

    local name = Framework.GetName(src) or cid
    local id = MySQL.insert.await('INSERT INTO `xs_submissions` (`gang_id`, `kind`, `label`, `url`, `status`, `submitted_by`, `submitted_name`, `created_at`) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { gang.id, kind, label, clean, 'pending', cid, name, now() })
    if cfg.autoApprove then return Approvals.Review(nil, id, true) end

    Gangs.Log(gang.id, ('%s sent a %s to staff'):format(name, KIND_NAME[kind]), kind == 'logo' and 'roster' or 'graffiti')
    for _, p in ipairs(GetPlayers()) do
        local s = tonumber(p)
        if staff(s) then Framework.Notify(s, ('%s sent a %s for approval.'):format(gang.label, KIND_NAME[kind]), 'inform') end
    end
    return true
end

function Approvals.Review(src, id, approve, note)
    local row = MySQL.single.await('SELECT * FROM `xs_submissions` WHERE `id` = ?', { tonumber(id) })
    if not row then return false, 'not found' end
    if row.status ~= 'pending' then return false, 'already decided' end
    local gang = Gangs.Get(row.gang_id)
    note = tostring(note or ''):gsub('[%c]', ''):sub(1, 120)
    if approve and gang then
        if row.kind == 'logo' then
            MySQL.update.await('UPDATE `xs_gangs` SET `logo` = ? WHERE `id` = ?', { row.url, gang.id })
            gang.logo = row.url
            Gangs.NotifyGang(gang.id, 'Your crew logo was approved.', 'success')
        else
            local ok, err = Graffiti.AdminAddArt(gang.id, row.label, row.url, 'url')
            if not ok then return false, err end
        end
    elseif gang then
        Gangs.NotifyGang(gang.id, ('Staff turned down your %s%s'):format(KIND_NAME[row.kind], note ~= '' and (': ' .. note) or '.'), 'error')
    end
    local status = approve and gang and 'approved' or 'rejected'
    local reviewer = src and (Framework.GetName(src) or GetPlayerName(src)) or 'auto'
    MySQL.update.await('UPDATE `xs_submissions` SET `status` = ?, `reviewed_by` = ?, `note` = ?, `reviewed_at` = ? WHERE `id` = ?', { status, reviewer, note, now(), row.id })
    if gang then
        Gangs.Log(gang.id, ('Staff %s the %s "%s"'):format(status == 'approved' and 'approved' or 'turned down', KIND_NAME[row.kind], row.label), row.kind == 'logo' and 'roster' or 'graffiti')
        Gangs.Broadcast(gang.id, 'gang', {})
    end
    return true
end

function Approvals.RemoveLogo(gangId)
    local gang = Gangs.Get(tonumber(gangId))
    if not gang then return false, 'unknown gang' end
    MySQL.update.await('UPDATE `xs_gangs` SET `logo` = NULL WHERE `id` = ?', { gang.id })
    gang.logo = nil
    Gangs.Broadcast(gang.id, 'gang', {})
    return true
end

local function shape(r)
    local g = Gangs.Get(r.gang_id)
    return { id = r.id, kind = r.kind, label = r.label, url = r.url, status = r.status, note = r.note, by = r.submitted_name,
        reviewer = r.reviewed_by, at = r.created_at, decidedAt = r.reviewed_at,
        crew = g and g.label or '?', color = g and g.color or nil, gangId = r.gang_id }
end

function Approvals.ForCrew(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return nil end
    local cid = Framework.GetCitizenId(src)
    local list = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM `xs_submissions` WHERE `gang_id` = ? ORDER BY `id` DESC LIMIT 20', { gang.id }) or {}) do list[#list + 1] = shape(r) end
    return { logo = gang.logo, submissions = list, enabled = { logo = Config.Approvals.logos, tag = Config.Approvals.tags },
        can = { logo = gang.owner == cid or Gangs.HasPerm(src, 'manage_motd'), tag = gang.owner == cid or Gangs.HasPerm(src, 'manage_graffiti') } }
end

function Approvals.AdminList()
    local pending, recent = {}, {}
    for _, r in ipairs(MySQL.query.await("SELECT * FROM `xs_submissions` WHERE `status` = 'pending' ORDER BY `id` ASC LIMIT 100") or {}) do pending[#pending + 1] = shape(r) end
    for _, r in ipairs(MySQL.query.await("SELECT * FROM `xs_submissions` WHERE `status` <> 'pending' ORDER BY `reviewed_at` DESC LIMIT 25") or {}) do recent[#recent + 1] = shape(r) end
    return { pending = pending, recent = recent }
end

CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `xs_submissions` (
            `id`             INT          NOT NULL AUTO_INCREMENT,
            `gang_id`        INT          NOT NULL,
            `kind`           VARCHAR(8)   NOT NULL,
            `label`          VARCHAR(64)  NOT NULL DEFAULT '',
            `url`            VARCHAR(500) NOT NULL,
            `status`         VARCHAR(10)  NOT NULL DEFAULT 'pending',
            `submitted_by`   VARCHAR(64)  NOT NULL DEFAULT '',
            `submitted_name` VARCHAR(96)  NOT NULL DEFAULT '',
            `reviewed_by`    VARCHAR(96)  NULL,
            `note`           VARCHAR(160) NULL,
            `created_at`     BIGINT       NOT NULL,
            `reviewed_at`    BIGINT       NULL,
            PRIMARY KEY (`id`),
            KEY `idx_status` (`status`),
            KEY `idx_gang` (`gang_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    local has = MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'xs_gangs' AND COLUMN_NAME = 'logo'
    ]])
    if (tonumber(has) or 0) == 0 then
        MySQL.query.await('ALTER TABLE `xs_gangs` ADD COLUMN `logo` VARCHAR(500) NULL DEFAULT NULL')
    end
end)

lib.callback.register('XS-CriminalTablet:approvals:mine', function(src)
    return Approvals.ForCrew(src)
end)

lib.callback.register('XS-CriminalTablet:approvals:submit', function(src, kind, url, label)
    local ok, err = Approvals.Submit(src, kind, url, label)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:approvals:removeLogo', function(src)
    local gang = Gangs.GetBySource(src)
    if not gang then return { ok = false, error = 'no gang' } end
    if gang.owner ~= Framework.GetCitizenId(src) and not Gangs.HasPerm(src, 'manage_motd') then return { ok = false, error = 'no permission' } end
    local ok, err = Approvals.RemoveLogo(gang.id)
    return { ok = ok, error = err }
end)

lib.callback.register('XS-CriminalTablet:admin:approvals', function(src)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    return { ok = true, data = Approvals.AdminList() }
end)

lib.callback.register('XS-CriminalTablet:admin:review', function(src, id, approve, note)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    local ok, err = Approvals.Review(src, id, approve == true, note)
    return { ok = ok, error = err, data = ok and Approvals.AdminList() or nil }
end)

lib.callback.register('XS-CriminalTablet:admin:removeLogo', function(src, gangId)
    if not staff(src) then return { ok = false, error = 'not authorized' } end
    local ok, err = Approvals.RemoveLogo(gangId)
    return { ok = ok, error = err }
end)
