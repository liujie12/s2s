-- =============================================================================
-- V7__device_push_platform.sql — device 增推送通道列（[B2-2]）
-- =============================================================================
-- 出处口径：
--   · PRD §12 `POST /users/me/devices`（原写 `/devices/token`，2026-10-12 裁定路径以 openapi 为准）
--     in: `platform`(apns/fcm/hw/mi/oppo/vivo/honor) + `token`；
--   · PRD §6.14 推送通道 = APNs / 小米 / 华为 / OPPO / vivo / 荣耀（境内不可用 FCM）。
-- 缺口：V1 的 `device.platform` 是 **OS**（enum android/ios，登录时写），
--   而推送 token 上报的 `platform` 是**推送通道** —— 两者同名不同义。若合用一个列，
--   「下发走哪家」与「设备是什么系统」会互相顶替（登录会覆盖推送通道、上报会覆盖 OS）。
-- 裁定（2026-10-12）：新增 `push_platform` 承载推送通道，`device.platform` 语义保持不变。
-- 口径：
--   · 可空（存量行与「未授权推送」的设备没有通道），下发前须判空跳过；
--   · 通道枚举与 openapi `DevicePlatformEnum` / PRD §12 同源，`fcm` 境内不可用、仅为对齐保留；
--   · 不加索引：下发按 `user_id` 扫（已有 `idx_user_id`），通道不单独检索。
-- EXPLAIN 结论：本迁移为纯 DDL（ALTER TABLE，无 SELECT/DML 查询语句），
--   EXPLAIN 不适用（豁免口径同 V5/V6，编码规范 §2.2）。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行（同 V2/V5/V6）。
-- =============================================================================

ALTER TABLE `device`
    ADD COLUMN `push_platform` ENUM('apns','fcm','hw','mi','oppo','vivo','honor') NULL
        COMMENT '推送通道（apns/hw/mi/oppo/vivo/honor/fcm）；NULL=未上报推送 token' AFTER `push_token`;
