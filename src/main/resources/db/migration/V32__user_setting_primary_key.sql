-- =============================================================================
-- V32__user_setting_primary_key.sql — 补 user_setting 主键并去重
-- =============================================================================
-- 背景：V6 建表注释写「user_id 即主键」，但 DDL 漏写 PRIMARY KEY。
--   缺少唯一键导致 UserSettingMapper.upsert 的 ON DUPLICATE KEY UPDATE 失效：
--   每次 PATCH /settings 都插入新行；GET /settings 的 selectByUserId 命中多行，
--   MyBatis 抛 TooManyResultsException → 50001（2026-11-03 设置页报错根因）。
-- 处理：
--   1) 每个 user_id 仅保留 updated_at/created_at 最新的一行，重建表并加 PRIMARY KEY；
--   2) 旧表改名 user_setting_bak_v32 留档，确认无误后可手工 DROP。
-- =============================================================================

DROP TABLE IF EXISTS `user_setting_new`;

CREATE TABLE `user_setting_new` (
  `user_id`                BIGINT   NOT NULL COMMENT '用户 ID（1:1 与 user，主键）',
  `notify_enabled`         TINYINT  NOT NULL DEFAULT 1 COMMENT '消息通知总开关：0=关，1=开',
  `notify_system`          TINYINT  NOT NULL DEFAULT 1 COMMENT '系统通知分通道：0=关，1=开',
  `notify_interaction`     TINYINT  NOT NULL DEFAULT 1 COMMENT '互动通知分通道：0=关，1=开',
  `notify_cert`            TINYINT  NOT NULL DEFAULT 1 COMMENT '认证通知分通道：0=关，1=开',
  `notify_message`         TINYINT  NOT NULL DEFAULT 1 COMMENT '新消息通知开关：0=关，1=开',
  `personalized_recommend` TINYINT  NOT NULL DEFAULT 1 COMMENT '个性化推荐开关：0=关，1=开',
  `ai_improve_enabled`     TINYINT  NOT NULL DEFAULT 1 COMMENT 'AI 数据用于改进解析：0=关，1=开',
  `created_at`             DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at`             DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                                      ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`user_id`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '用户通知设置—[B2-11]；1:1 user，缺行=全默认（各通道全开）';

INSERT INTO `user_setting_new`
  (`user_id`, `notify_enabled`, `notify_system`, `notify_interaction`, `notify_cert`,
   `notify_message`, `personalized_recommend`, `ai_improve_enabled`, `created_at`, `updated_at`)
SELECT `user_id`, `notify_enabled`, `notify_system`, `notify_interaction`, `notify_cert`,
       `notify_message`, `personalized_recommend`, `ai_improve_enabled`, `created_at`, `updated_at`
FROM (
  SELECT `user_id`, `notify_enabled`, `notify_system`, `notify_interaction`, `notify_cert`,
         `notify_message`, `personalized_recommend`, `ai_improve_enabled`, `created_at`, `updated_at`,
         ROW_NUMBER() OVER (PARTITION BY `user_id` ORDER BY `updated_at` DESC, `created_at` DESC) AS `rn`
  FROM `user_setting`
) `t`
WHERE `rn` = 1;

RENAME TABLE `user_setting` TO `user_setting_bak_v32`,
             `user_setting_new` TO `user_setting`;
