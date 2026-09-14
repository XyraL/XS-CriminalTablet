CREATE TABLE IF NOT EXISTS `xs_gangs` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `name`          VARCHAR(64)     NOT NULL,
    `label`         VARCHAR(64)     NOT NULL,
    `color`         VARCHAR(9)      NOT NULL DEFAULT '#f5a524',
    `motd`          VARCHAR(255)    NOT NULL DEFAULT '',
    `owner`         VARCHAR(64)     NOT NULL,
    `notoriety`     INT             NOT NULL DEFAULT 0,
    `bank`          BIGINT          NOT NULL DEFAULT 0,
    `max_members`   INT             NOT NULL DEFAULT 0,
    `war_wins`      INT             NOT NULL DEFAULT 0,
    `war_losses`    INT             NOT NULL DEFAULT 0,
    `last_active`   BIGINT          NOT NULL DEFAULT 0,
    `perk_points`   INT             NOT NULL DEFAULT 0,
    `raid_cooldown` BIGINT          NOT NULL DEFAULT 0,
    `raid_immune`   BIGINT          NOT NULL DEFAULT 0,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_perks` (
    `gang_id`       INT             NOT NULL,
    `perk_id`       VARCHAR(48)     NOT NULL,
    `bought_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`gang_id`, `perk_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_upgrades` (
    `gang_id`       INT             NOT NULL,
    `upgrade_id`    VARCHAR(48)     NOT NULL,
    `level`         INT             NOT NULL DEFAULT 0,
    `updated_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`gang_id`, `upgrade_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_prices` (
    `kind`          VARCHAR(16)     NOT NULL,
    `price_key`     VARCHAR(64)     NOT NULL,
    `price`         BIGINT          NOT NULL DEFAULT 0,
    `updated_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`kind`, `price_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_unlocks` (
    `gang_id`       INT             NOT NULL,
    `unlock_id`     VARCHAR(48)     NOT NULL,
    `paid`          BIGINT          NOT NULL DEFAULT 0,
    `bought_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`gang_id`, `unlock_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_ranks` (
    `gang_id`       INT             NOT NULL,
    `grade`         INT             NOT NULL,
    `name`          VARCHAR(48)     NOT NULL,
    `permissions`   LONGTEXT        NOT NULL,
    PRIMARY KEY (`gang_id`, `grade`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_members` (
    `gang_id`       INT             NOT NULL,
    `citizenid`     VARCHAR(64)     NOT NULL,
    `name`          VARCHAR(96)     NOT NULL,
    `grade`         INT             NOT NULL DEFAULT 0,
    `rep`           INT             NOT NULL DEFAULT 0,
    `last_seen`     BIGINT          NOT NULL DEFAULT 0,
    `joined_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),
    KEY `idx_gang` (`gang_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_task_cooldowns` (
    `citizenid`     VARCHAR(64)     NOT NULL,
    `task_id`       VARCHAR(48)     NOT NULL,
    `completed_at`  BIGINT          NOT NULL DEFAULT 0,
    PRIMARY KEY (`citizenid`, `task_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_task_stats` (
    `citizenid`     VARCHAR(64)     NOT NULL,
    `name`          VARCHAR(96)     NOT NULL DEFAULT '',
    `xp`            INT             NOT NULL DEFAULT 0,
    `level`         INT             NOT NULL DEFAULT 1,
    `total_completed` INT           NOT NULL DEFAULT 0,
    PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_territories` (
    `zone`          VARCHAR(48)     NOT NULL,
    `label`         VARCHAR(64)     NOT NULL DEFAULT '',
    `color`         INT             NOT NULL DEFAULT 0,
    `points`        LONGTEXT        NULL,
    `radius`        FLOAT           NOT NULL DEFAULT 60,
    `coord_x`       FLOAT           NULL,
    `coord_y`       FLOAT           NULL,
    `coord_z`       FLOAT           NULL,
    `capturable`    TINYINT(1)      NOT NULL DEFAULT 1,
    `gang_id`       INT             NULL,
    `assigned_at`   BIGINT          NOT NULL DEFAULT 0,
    PRIMARY KEY (`zone`),
    KEY `idx_holder` (`gang_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_territory_influence` (
    `zone`          VARCHAR(48)     NOT NULL,
    `gang_id`       INT             NOT NULL,
    `influence`     FLOAT           NOT NULL DEFAULT 0,
    `updated_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`zone`, `gang_id`),
    KEY `idx_influence_gang` (`gang_id`),
    FOREIGN KEY (`zone`)
        REFERENCES `xs_territories` (`zone`) ON DELETE CASCADE,
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_placements` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `kind`          VARCHAR(16)     NOT NULL,
    `unlock_id`     VARCHAR(48)     NOT NULL,
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
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_art` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `label`         VARCHAR(64)     NOT NULL DEFAULT '',
    `art`           LONGTEXT        NOT NULL,
    `source`        VARCHAR(16)     NOT NULL DEFAULT 'admin',
    `added_by`      VARCHAR(64)     NOT NULL DEFAULT '',
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_art_gang` (`gang_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_graffiti` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `art_id`        INT             NULL,
    `art`           LONGTEXT        NOT NULL,
    `x`             FLOAT           NOT NULL,
    `y`             FLOAT           NOT NULL,
    `z`             FLOAT           NOT NULL,
    `rx`            FLOAT           NOT NULL DEFAULT 0,
    `ry`            FLOAT           NOT NULL DEFAULT 0,
    `rz`            FLOAT           NOT NULL DEFAULT 0,
    `scale`         FLOAT           NOT NULL DEFAULT 1,
    `tint`          VARCHAR(9)      NOT NULL DEFAULT '',
    `sprayed_by`    VARCHAR(64)     NOT NULL DEFAULT '',
    `sprayed_name`  VARCHAR(96)     NOT NULL DEFAULT '',
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_graffiti_gang` (`gang_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_vehicles` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `model`         VARCHAR(64)     NOT NULL,
    `label`         VARCHAR(64)     NOT NULL DEFAULT '',
    `plate`         VARCHAR(16)     NOT NULL,
    `props`         LONGTEXT        NULL,
    `stored`        TINYINT(1)      NOT NULL DEFAULT 1,
    `added_by`      VARCHAR(64)     NOT NULL DEFAULT '',
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_plate` (`plate`),
    KEY `idx_veh_gang` (`gang_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_wars` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `kind`          VARCHAR(8)      NOT NULL DEFAULT 'raid',
    `attacker_id`   INT             NOT NULL,
    `defender_id`   INT             NOT NULL,
    `state`         VARCHAR(12)     NOT NULL DEFAULT 'prep',
    `score_attack`  INT             NOT NULL DEFAULT 0,
    `score_defend`  INT             NOT NULL DEFAULT 0,
    `winner_id`     INT             NULL,
    `started_at`    BIGINT          NOT NULL DEFAULT 0,
    `ends_at`       BIGINT          NOT NULL DEFAULT 0,
    `finished_at`   BIGINT          NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `idx_war_attacker` (`attacker_id`),
    KEY `idx_war_defender` (`defender_id`),
    KEY `idx_war_state` (`state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_stash_windows` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `war_id`        INT             NOT NULL,
    `winner_id`     INT             NOT NULL,
    `loser_id`      INT             NOT NULL,
    `expires_at`    BIGINT          NOT NULL DEFAULT 0,
    `looted_at`     BIGINT          NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `idx_stash_winner` (`winner_id`),
    KEY `idx_stash_open` (`looted_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_blips` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `label`         VARCHAR(64)     NOT NULL DEFAULT '',
    `sprite`        INT             NOT NULL DEFAULT 84,
    `color`         INT             NOT NULL DEFAULT 0,
    `scale`         FLOAT           NOT NULL DEFAULT 0.8,
    `x`             FLOAT           NOT NULL,
    `y`             FLOAT           NOT NULL,
    `z`             FLOAT           NOT NULL DEFAULT 30,
    `visibility`    VARCHAR(8)      NOT NULL DEFAULT 'gang',
    `short_range`   TINYINT(1)      NOT NULL DEFAULT 1,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_blip_gang` (`gang_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_dealer_pool` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `item`          VARCHAR(64)     NOT NULL,
    `label`         VARCHAR(64)     NOT NULL DEFAULT '',
    `price_min`     INT             NOT NULL DEFAULT 0,
    `price_max`     INT             NOT NULL DEFAULT 0,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_dealer_item` (`item`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_dealer_spawns` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `label`         VARCHAR(64)     NOT NULL DEFAULT '',
    `x`             FLOAT           NOT NULL,
    `y`             FLOAT           NOT NULL,
    `z`             FLOAT           NOT NULL,
    `heading`       FLOAT           NOT NULL DEFAULT 0,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_settings` (
    `scope`         VARCHAR(32)     NOT NULL,
    `skey`          VARCHAR(48)     NOT NULL,
    `svalue`        TEXT            NOT NULL,
    `updated_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`scope`, `skey`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_logs` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `message`       VARCHAR(255)    NOT NULL,
    `category`      VARCHAR(16)     NOT NULL DEFAULT 'general',
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_gang_log` (`gang_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `xs_gang_bank_log` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `gang_id`       INT             NOT NULL,
    `citizenid`     VARCHAR(64)     NOT NULL DEFAULT '',
    `name`          VARCHAR(96)     NOT NULL,
    `kind`          VARCHAR(16)     NOT NULL,
    `amount`        BIGINT          NOT NULL DEFAULT 0,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_banklog_gang` (`gang_id`),
    FOREIGN KEY (`gang_id`)
        REFERENCES `xs_gangs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

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

ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `color` VARCHAR(9) NOT NULL DEFAULT '#f5a524';
ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `motd` VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `max_members` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `war_wins` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `war_losses` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `perk_points` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `raid_cooldown` BIGINT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gangs` ADD COLUMN IF NOT EXISTS `raid_immune` BIGINT NOT NULL DEFAULT 0;

ALTER TABLE `xs_gang_members` ADD COLUMN IF NOT EXISTS `rep` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_gang_members` ADD COLUMN IF NOT EXISTS `last_seen` BIGINT NOT NULL DEFAULT 0;

ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `label` VARCHAR(64) NOT NULL DEFAULT '';
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `color` INT NOT NULL DEFAULT 0;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `points` LONGTEXT NULL;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `radius` FLOAT NOT NULL DEFAULT 60;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `coord_x` FLOAT NULL;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `coord_y` FLOAT NULL;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `coord_z` FLOAT NULL;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `capturable` TINYINT(1) NOT NULL DEFAULT 1;
ALTER TABLE `xs_territories` ADD COLUMN IF NOT EXISTS `assigned_at` BIGINT NOT NULL DEFAULT 0;

ALTER TABLE `xs_gang_logs` ADD COLUMN IF NOT EXISTS `category` VARCHAR(16) NOT NULL DEFAULT 'general';
