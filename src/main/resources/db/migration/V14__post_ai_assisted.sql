-- =============================================================================
-- V14__post_ai_assisted.sql — post 增 ai_assisted 列（B2-4 T2 AI 智能发布）
-- =============================================================================
-- 出处口径：
--   · PRD §5.9「AI 结果确认页」——用户点「确认发布」即视为该条由 AI 辅助生成；
--   · PRD §5.9 合规裁定（2026-10-13）：内容标识「两处都做」——`ai-confirm-screen`
--     界面 + **最终帖子详情页**标「AI 辅助生成」，故需在 post 落库标记以支撑详情页判定。
--   · 配额：`POST /posts` 请求带 `ai_assisted=true` 时，发布成功后扣 1 次 AI 配额
--     （PRD §5.9「仅确认发布才计 1 次」；扣减点见 PostService.createPost）。
-- 变更形态：新增列，NOT NULL DEFAULT 0（存量行一律「非 AI 辅助」，与服务端默认一致）。
-- 缺口与后续：详情出参（PostQueryService/PostQueryMapper）、openapi PostDetail.ai_assisted、
--   前端详情页「AI 辅助生成」标识、确认页标识。
-- EXPLAIN 结论：纯 DDL（ALTER TABLE ADD COLUMN），无 SELECT/DML，EXPLAIN 不适用。
-- 无 DROP TABLE IF EXISTS：Flyway 版本化迁移由 flyway_schema_history 保证单次执行。
-- =============================================================================

ALTER TABLE `post`
    ADD COLUMN `ai_assisted` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT '本条是否由 T2 AI 智能发布辅助生成（PRD §5.9）；详情页「AI 辅助生成」标识来源'
        AFTER `completeness_level`;
