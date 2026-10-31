-- =============================================================================
-- V27__template_depart_time.sql — 拼车模板「出发时间」改为时刻字段
-- =============================================================================
-- 口径（计划 KTD1 / KTD4 / U2）：
--   1. 只改 L2=301（顺风车/拼车）那一行 fields 里的 depart_time 字段：
--      type text → datetime，并移除 placeholder（占位文案由时间控件自带，
--      自由文本时代的「如：工作日 8:00」对新控件无意义）；label / required
--      与其余三个字段逐字保留（与 V26 同源，不借机改文案）。
--   2. template_version 加一：客户端按版本判断本地缓存是否过期。
--   3. 本行字段与客户端本地模板 lib/domain/publish_template.dart 的 301
--      条目、以及 docs/api/openapi.yaml 的 TemplateField.type 枚举三处同源，
--      任一改动须同时改另两处。
--   4. 值为 RFC3339 UTC 时刻串（契约全局纪律第 5 条），落现有 attributes
--      JSON 字符串键，不动表结构；历史文本（如「工作日 8:00」）按已填放行，
--      服务端必填判定零改动（KTD3）。
-- =============================================================================

UPDATE `template`
SET `fields` = '[{"key":"route","label":"起点 → 终点","type":"route_pair","required":true,"placeholder":"如：回龙观 → 中关村"},{"key":"depart_time","label":"出发时间","type":"datetime","required":true},{"key":"seats","label":"空座数","type":"number","required":true,"placeholder":"1-6"},{"key":"car_model","label":"车型","type":"text","required":false,"placeholder":"如：轩逸（白色）"}]',
    `template_version` = `template_version` + 1
WHERE `leaf_category_id` = 301;
