-- =============================================================================
-- V6__user_setting.sql — 用户设置表（[B2-11] 设置域载体）
-- =============================================================================
-- 出处口径：
--   · PRD §13：`GET/PATCH /settings` = 通知开关 + 默认范围 + 隐私项；
--   · PRD §9.3：消息通知总开关 + 分通道（系统/互动/认证）；
-- 缺口：V1 仅 `user.default_radius` 承载「默认范围」，**通知开关无任何载体**。
-- 裁定：2026-10-11（DEC-33）新建本表承载通知开关；不污染 `user` 账号热表，后续设置项可扩展。
-- 口径：
--   · 1:1 与 `user`（`user_id` 即主键，不另建自增 id——本表为纯扩展属性表）；
--   · 布尔列以 `TINYINT` 表（范式同 V1 的 `forbidden`/`restricted`）；
--   · 缺行 = 全默认（各通道全开）；service 侧 `INSERT ... ON DUPLICATE KEY UPDATE` upsert 兜底。
-- EXPLAIN 结论：本迁移为纯 DDL（CREATE TABLE，无 SELECT/DML 查询语句），
--   EXPLAIN 不适用（编码规范 §2.2 要求的「无结论视为未完成」按此注明豁免）。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行
--   （与 V1 存档脚本的 initdb 时代写法刻意区分，同 V2/V5）。
-- =============================================================================

CREATE TABLE `user_setting` (
  `user_id`             BIGINT   NOT NULL                        COMMENT '用户 ID（1:1 与 user，主键）',
  `notify_enabled`      TINYINT  NOT NULL DEFAULT 1              COMMENT '消息通知总开关：0=关，1=开（PRD §9.3）',
  `notify_system`       TINYINT  NOT NULL DEFAULT 1              COMMENT '系统通知分通道：0=关，1=开',
  `notify_interaction`  TINYINT  NOT NULL DEFAULT 1              COMMENT '互动通知分通道：0=关，1=开',
  `notify_cert`         TINYINT  NOT NULL DEFAULT 1              COMMENT '认证通知分通道：0=关，1=开',
  `created_at`          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at`          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '用户通知设置—[B2-11]；1:1 user，缺行=全默认（各通道全开）';
