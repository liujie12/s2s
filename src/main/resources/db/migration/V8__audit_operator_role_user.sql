-- =============================================================================
-- V8__audit_operator_role_user.sql — audit_log.operator_role 增 user 值（[147] DEC-11）
-- =============================================================================
-- 出处口径：
--   · DEC-11（2026-10-10 裁定）：「audit_log.operator_role 在『用户触发的解密留痕』
--     场景无合法取值」→ 裁定改为**新增 user 枚举值**（不再用 system 兜底）。
--   · PRD §9.10.1「查看用户脱敏信息」为必留审计项，而 GET /posts/{id}/contact 的
--     留痕由**普通用户**触发；普通用户不属后台四角色，故需独立取值。
--   · 依据源：《决策登记表》DEC-11；B2-5 清单（审计按角色筛选不得含脏维度）。
-- 变更形态：ENUM 末尾追加 'user'（不改既有四值、不改列位置），存量行取值不变。
-- 缺口与后续：DEC-11 落地仅 DDL + OperatorRole 两处，调用点不变（AuditEntry 载荷
--   形态不变）；唯一消费点 OperatorRole.java 同步新增 USER。
-- EXPLAIN 结论：纯 DDL（ALTER TABLE MODIFY COLUMN），无 SELECT/DML，EXPLAIN 不适用
--   （豁免口径同 V5/V6/V7，编码规范 §2.2）。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行。
-- =============================================================================

ALTER TABLE `audit_log`
    MODIFY COLUMN `operator_role` ENUM('super_admin','admin','auditor','system','user') NOT NULL
        COMMENT '操作人角色（super_admin/admin/auditor/system/user；user=用户触发的解密留痕）';
