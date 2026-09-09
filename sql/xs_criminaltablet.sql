-- XS-CriminalTablet / Gang Ops schema
-- Import once into your server database.

CREATE TABLE IF NOT EXISTS `xs_gangs` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `name`          VARCHAR(64)     NOT NULL,
    `label`         VARCHAR(64)     NOT NULL,
    `owner`         VARCHAR(64)     NOT NULL,            -- citizenid of boss
    `notoriety`     INT             NOT NULL DEFAULT 0,
    `bank`          BIGINT          NOT NULL DEFAULT 0,
    `dues_amount`   INT             NOT NULL DEFAULT 0,
    `dues_last`     BIGINT          NOT NULL DEFAULT 0,  -- unix ms of last cycle
    `last_active`   BIGINT          NOT NULL DEFAULT 0,  -- unix ms, drives decay
    `perk_points`   INT             NOT NULL DEFAULT 0,  -- unspent, awarded on gang level-up
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Owned gang perks (Config.GangPerks) — permanent, gang-wide modifiers
-- bought with perk_points. Mirrors xs_boost_perks' shape.
CREATE TABLE IF NOT EXISTS `xs_gang_perks` (
    `gang_id`       INT             NOT NULL,
    `perk_id`       VARCHAR(48)     NOT NULL,
    `bought_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`gang_id`, `perk_id`),
    CONSTRAINT `fk_gangperk_gang` FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_ranks` (
    `gang_id`       INT             NOT NULL,
    `grade`         INT             NOT NULL,
    `name`          VARCHAR(48)     NOT NULL,
    `permissions`   LONGTEXT        NOT NULL,            -- json array or "*"
    PRIMARY KEY (`gang_id`, `grade`),
    CONSTRAINT `fk_ranks_gang` FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_members` (
    `gang_id`       INT             NOT NULL,
    `citizenid`     VARCHAR(64)     NOT NULL,
    `name`          VARCHAR(96)     NOT NULL,            -- cached display name
    `grade`         INT             NOT NULL DEFAULT 0,
    `rep`           INT             NOT NULL DEFAULT 0,  -- personal rep, feeds gang notoriety
    `dues_paid_at`  BIGINT          NOT NULL DEFAULT 0,  -- unix ms of last dues charge, drives offline catch-up
    `last_seen`     BIGINT          NOT NULL DEFAULT 0,  -- unix ms, updated on tablet snapshot fetch
    `joined_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),                           -- one gang per character
    KEY `idx_gang` (`gang_id`),
    CONSTRAINT `fk_member_gang` FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_task_cooldowns` (
    `citizenid`     VARCHAR(64)     NOT NULL,
    `task_id`       VARCHAR(48)     NOT NULL,
    `completed_at`  BIGINT          NOT NULL DEFAULT 0,  -- unix ms
    PRIMARY KEY (`citizenid`, `task_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Personal task rank — independent of gang membership (survives leaving/
-- joining a different gang), mirrors xs_boost_stats' shape. XP here is
-- separate from the gang rep tasks also pay out; it only gates which task
-- variants (Config.Tasks[*].minLevel) are available to you.
CREATE TABLE IF NOT EXISTS `xs_task_stats` (
    `citizenid`     VARCHAR(64)     NOT NULL,
    `name`          VARCHAR(96)     NOT NULL DEFAULT '',
    `xp`            INT             NOT NULL DEFAULT 0,
    `level`         INT             NOT NULL DEFAULT 1,
    `total_completed` INT           NOT NULL DEFAULT 0,
    PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Zones are admin-assigned only — there is no in-world capture. A zone may
-- be seeded from Config.Territories, or created entirely from the admin
-- tablet (which also sets coords from the admin's current position).
CREATE TABLE IF NOT EXISTS `xs_territories` (
    `zone`          VARCHAR(48)     NOT NULL,
    `label`         VARCHAR(64)     NOT NULL DEFAULT '',
    `color`         INT             NOT NULL DEFAULT 0,
    `income`        INT             NOT NULL DEFAULT 0,
    `coord_x`       FLOAT           NULL,
    `coord_y`       FLOAT           NULL,
    `coord_z`       FLOAT           NULL,
    `gang_id`       INT             NULL,                -- assigned gang, null = unassigned
    `assigned_at`   BIGINT          NOT NULL DEFAULT 0,
    PRIMARY KEY (`zone`),
    KEY `idx_holder` (`gang_id`),
    CONSTRAINT `fk_terr_gang` FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Boss-placed world objects: tier-unlock benches/peds and the gang vault
-- container. One row per (gang, kind, unlock_id) — re-placing updates the
-- existing row rather than stacking duplicates.
CREATE TABLE IF NOT EXISTS `xs_gang_placements` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `kind`          VARCHAR(16)     NOT NULL,            -- 'bench' | 'ped' | 'vault'
    `unlock_id`     VARCHAR(48)     NOT NULL,            -- TierUnlocks id, or 'vault'
    `model`         VARCHAR(64)     NOT NULL,
    `label`         VARCHAR(64)     NOT NULL DEFAULT '',
    `x`             FLOAT           NOT NULL,
    `y`             FLOAT           NOT NULL,
    `z`             FLOAT           NOT NULL,
    `heading`       FLOAT           NOT NULL DEFAULT 0,
    `placed_by`     VARCHAR(64)     NOT NULL DEFAULT '',
    `placed_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_placement` (`gang_id`, `kind`, `unlock_id`),
    CONSTRAINT `fk_placement_gang` FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_logs` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `message`       VARCHAR(255)    NOT NULL,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_gang_log` (`gang_id`),
    CONSTRAINT `fk_log_gang` FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Dedicated treasury ledger (separate from the general activity log) for
-- the Treasury tab's bank-statement-style transaction history.
CREATE TABLE IF NOT EXISTS `xs_gang_bank_log` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `citizenid`     VARCHAR(64)     NOT NULL DEFAULT '',
    `name`          VARCHAR(96)     NOT NULL,
    `kind`          VARCHAR(16)     NOT NULL,            -- 'deposit' | 'withdraw'
    `amount`        BIGINT          NOT NULL DEFAULT 0,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_banklog_gang` (`gang_id`),
    CONSTRAINT `fk_banklog_gang` FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Blackmarket chat: anonymous codename per character, a capped world feed,
-- and DMs addressed by handle (never by citizenid) so identity never
-- leaks through the chat UI itself.
CREATE TABLE IF NOT EXISTS `xs_chat_handles` (
    `citizenid`     VARCHAR(64)     NOT NULL,
    `handle`        VARCHAR(32)     NOT NULL,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),
    UNIQUE KEY `uniq_handle` (`handle`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_chat_world` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `handle`        VARCHAR(32)     NOT NULL,
    `message`       VARCHAR(280)    NOT NULL,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_chat_dms` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `from_citizenid` VARCHAR(64)    NOT NULL,
    `to_citizenid`  VARCHAR(64)     NOT NULL,
    `from_handle`   VARCHAR(32)     NOT NULL,
    `to_handle`     VARCHAR(32)     NOT NULL,
    `message`       VARCHAR(280)    NOT NULL,
    `read_at`       BIGINT          NOT NULL DEFAULT 0,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_from` (`from_citizenid`),
    KEY `idx_to` (`to_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Car boosting: fully standalone from gangs. One row per character —
-- level/xp drive vehicle-tier unlocks, total_boosted drives the
-- leaderboard, total_cash is just a stat (not used for anything mechanical).
CREATE TABLE IF NOT EXISTS `xs_boost_stats` (
    `citizenid`     VARCHAR(64)     NOT NULL,
    `name`          VARCHAR(96)     NOT NULL DEFAULT '',  -- cached display name for the leaderboard
    `level`         INT             NOT NULL DEFAULT 1,
    `xp`            INT             NOT NULL DEFAULT 0,
    `total_boosted` INT             NOT NULL DEFAULT 0,
    `total_cash`    BIGINT          NOT NULL DEFAULT 0,
    `last_boost_at` BIGINT          NOT NULL DEFAULT 0,   -- unix ms, drives cooldown
    `perk_points`   INT             NOT NULL DEFAULT 0,   -- unspent, awarded on level-up
    PRIMARY KEY (`citizenid`),
    KEY `idx_leaderboard` (`total_boosted`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Owned perks (Config.Boosting.perks) — passive unlocks bought with
-- perk_points, never consumed/used-up, just a permanent modifier.
CREATE TABLE IF NOT EXISTS `xs_boost_perks` (
    `citizenid`     VARCHAR(64)     NOT NULL,
    `perk_id`       VARCHAR(48)     NOT NULL,
    `bought_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`, `perk_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Server-wide recent sells, shown on the Job tab. Capped to the most
-- recent rows at query time (Config.Boosting.recentActivityLimit) — this
-- table itself isn't pruned, just queried with a LIMIT.
CREATE TABLE IF NOT EXISTS `xs_boost_log` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `name`          VARCHAR(96)     NOT NULL,
    `vehicle_label` VARCHAR(64)     NOT NULL,
    `cash`          INT             NOT NULL DEFAULT 0,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Safe to re-run on a DB that already has these tables from an earlier
-- version of this file (MySQL 8 / MariaDB 10.0+ required for IF NOT EXISTS).
ALTER TABLE `xs_gang_members` ADD COLUMN IF NOT EXISTS `rep` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gang_members` ADD COLUMN IF NOT EXISTS `dues_paid_at` BIGINT NOT NULL DEFAULT 0;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `label` VARCHAR(64) NOT NULL DEFAULT '';
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `color` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `income` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `coord_x` FLOAT NULL;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `coord_y` FLOAT NULL;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `coord_z` FLOAT NULL;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `assigned_at` BIGINT NOT NULL DEFAULT 0;
ALTER TABLE `xs_boost_stats` ADD COLUMN IF NOT EXISTS `perk_points` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `perk_points` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gang_members` ADD COLUMN IF NOT EXISTS `last_seen` BIGINT NOT NULL DEFAULT 0;
