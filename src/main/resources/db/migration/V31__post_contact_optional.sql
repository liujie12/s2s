-- =============================================================================
-- V31__post_contact_optional.sql — post 联系方式三列放开 NOT NULL（2026-11-02）
-- =============================================================================
-- 出处口径：
--   · 前端 2026-11-01 已把「联系方式」改为选填（用户在发布页可留空），
--     但契约 required 与三列 NOT NULL 未同步，真机表现为：点「同意协议并发布」
--     按钮闪一下、帖子未落库——服务端 40001「缺少必填参数 contactValue」。
--   · 2026-11-02 用户裁定：**改后端允许不填**（前后端对齐到「选填」），
--     并新增错误码 41002「该信息未留联系方式」承接 /contact 的取号请求
--     （DEC-14 当年预留的触发条件 ②「发布侧校验变更」正式生效）。
-- 变更形态：三列由 NOT NULL 改为 NULL；存量行全部已有值，不涉及数据回填。
-- 配套改动：PostCreateRequest 去 @NotBlank、PostService 空值跳过加密、
--   ContactService 三列全空 → 41002、openapi/PRD §12.5 登记 41002。
-- 回滚：三列重新收紧为 NOT NULL 前，须先把 NULL 行补出联系方式（否则 ALTER 失败）。
-- EXPLAIN 结论：纯 DDL（ALTER TABLE MODIFY），无 SELECT/DML，EXPLAIN 不适用。
-- =============================================================================

ALTER TABLE `post`
    MODIFY COLUMN `contact_channel` ENUM('phone','wechat') NULL
        COMMENT '联系方式渠道（二选一单轨；发布时未填联系方式则为 NULL）',
    MODIFY COLUMN `contact_value_enc` VARBINARY(255) NULL
        COMMENT '联系方式 AEAD 密文（仅 /contact 接口解密返回；未填联系方式则为 NULL）',
    MODIFY COLUMN `key_version` TINYINT NULL
        COMMENT '联系方式 AEAD 密钥版本号（未填联系方式则为 NULL）';
