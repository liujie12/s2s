-- =============================================================================
-- V26__template_route_pair.sql — 拼车模板「起点 → 终点」改为结构化地点对
-- =============================================================================
-- 口径（计划 KTD2 / U7）：
--   1. 只改 L2=301（顺风车/拼车）那一行 fields 里的 route 字段 type：
--      text → route_pair；label / required / placeholder 与其余三个字段
--      逐字保留（与 V4 同源，不借机改文案）。
--   2. template_version 加一：客户端按版本判断本地缓存是否过期。
--   3. 本行字段与客户端本地模板 lib/domain/publish_template.dart 的 301
--      条目、以及 docs/api/openapi.yaml 的 TemplateField.type 枚举三处同源，
--      任一改动须同时改另两处。
-- =============================================================================

UPDATE `template`
SET `fields` = '[{"key":"route","label":"起点 → 终点","type":"route_pair","required":true,"placeholder":"如：回龙观 → 中关村"},{"key":"depart_time","label":"出发时间","type":"text","required":true,"placeholder":"如：工作日 8:00"},{"key":"seats","label":"空座数","type":"number","required":true,"placeholder":"1-6"},{"key":"car_model","label":"车型","type":"text","required":false,"placeholder":"如：轩逸（白色）"}]',
    `template_version` = `template_version` + 1
WHERE `leaf_category_id` = 301;
