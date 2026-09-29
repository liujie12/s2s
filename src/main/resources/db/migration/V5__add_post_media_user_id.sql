-- [125] KTD8：post_media 增加归属列 user_id，支撑「media 属当前用户」校验与「非本人不可见」视角分流。
-- Batch1 post_media 表为空，直接加 NOT NULL 列无历史数据约束问题。
ALTER TABLE `post_media`
    ADD COLUMN `user_id` BIGINT NOT NULL COMMENT '媒体上传者 user_id（归属校验）' AFTER `post_id`;

-- 归属查询索引：commit/发布按 (user_id, id) 校验归属
ALTER TABLE `post_media`
    ADD KEY `idx_user_id` (`user_id`);
