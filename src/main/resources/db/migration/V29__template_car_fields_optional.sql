-- =============================================================================
-- V29__template_car_fields_optional.sql — 拼车车辆四行改为选填
-- =============================================================================
-- 口径（2026-10-31 用户裁定「必填项要求都去掉，后期根据需求再定」）：
--   1. 只改 L2=301（顺风车/拼车）那一行 fields：
--        · car_brand   required true → false
--        · car_model   required true → false
--        · car_color / plate_no 本就是选填，原样保留。
--      route / depart_time / seats 三项必填保持不变（PRD §5.4.3 既有口径，
--      不属本次放开范围）。
--   2. template_version 加一：客户端按版本判断本地缓存是否过期。
--   3. 与 lib/domain/publish_template.dart 的 301 条目同源，须同时改。
--   4. 不新增字段、不删字段、不新增接口、不动表结构、不新增错误码；
--      完整度判定（required_full）随 required 标记自动变松，服务端无需改代码。
--   5. 历史数据无影响：老帖 car_model 自由文本原样展示，不清洗不迁移。
-- =============================================================================

UPDATE `template`
SET `fields` = '[{"key":"route","label":"起点 → 终点","type":"route_pair","required":true,"placeholder":"如：回龙观 → 中关村"},{"key":"depart_time","label":"出发时间","type":"datetime","required":true},{"key":"seats","label":"空座数","type":"number","required":true,"placeholder":"1-6"},{"key":"car_brand","label":"品牌","type":"select","required":false,"placeholder":"选择或手填","options":["比亚迪","大众","丰田","本田","日产","吉利","长安","特斯拉","宝马","奔驰","奥迪","别克","雪佛兰","福特","现代","起亚","马自达","斯柯达","标致","雪铁龙","雷克萨斯","凯迪拉克","沃尔沃","林肯","捷豹","保时捷","长城","奇瑞","荣威","名爵","五菱","红旗","哈弗","传祺","领克","蔚来","小鹏","理想","哪吒","零跑","埃安","极氪","腾势"]},{"key":"car_model","label":"车型","type":"select","required":false,"options":["轿车","SUV","MPV","跑车","微面","皮卡","其他"]},{"key":"car_color","label":"颜色","type":"select","required":false,"placeholder":"选择或手填","options":["白色","黑色","银色","灰色","蓝色"]},{"key":"plate_no","label":"车牌","type":"text","required":false,"placeholder":"如：皖A12345"}]',
    `template_version` = `template_version` + 1
WHERE `leaf_category_id` = 301;
