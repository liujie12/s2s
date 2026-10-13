-- =============================================================================
-- V9__post_contact_mask.sql — post 增 contact_mask 列（[147] DEC-13「方案 B」）
-- =============================================================================
-- 出处口径：
--   · DEC-13（2026-10-10 裁定，取「方案 B」）：post 补 contact_mask 列，**发布时算
--     掩码落库**，使详情/联系中转页未拉取态可显示真实脱敏值（对齐 PRD §7.4.2 稿图）。
--   · 红线保持：contact_value_enc 的解密唯一调用点仍在 contact 域；本列为**发布时
--     由明文派生的脱敏值**（不需要解密），详情接口读取它不触调解密不变量。
-- 变更形态：新增列，可空（存量行无掩码值，为 NULL）。
-- 缺口与后续：发布链（PostService）写掩码、详情出参（PostQueryService/PostQueryMapper）
--   回该列、openapi PostDetail.contact_mask 语义由「恒 null」改为「发布时脱敏值」、
--   前端未拉取态切真值；须复核与 DEC-14（维持 noContact 现状）不冲突。
-- EXPLAIN 结论：纯 DDL（ALTER TABLE ADD COLUMN），无 SELECT/DML，EXPLAIN 不适用。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行。
-- =============================================================================

ALTER TABLE `post`
    ADD COLUMN `contact_mask` VARCHAR(64) NULL
        COMMENT '发布时计算的脱敏联系方式（展示用，不参与查询；完整值只由 /contact 接口解密返回）'
        AFTER `contact_value_enc`;
