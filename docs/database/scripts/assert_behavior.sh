#!/usr/bin/env bash
# =============================================================================
# Batch1 schema 行为断言脚本
# 用途：验证 DDL 落地后的实际行为是否符合设计契约（不只是建表成功）
# 参数：$1 = 容器名（默认 mysql8），$2 = 业务库名（默认 s2s_batch1），$3 = 埋点库名（默认 s2s_track_batch1）
# 覆盖：生成列不可写 / 生成列计算正确 / 盲索引唯一约束 / 收藏幂等 / 写守卫分流
#      / 埋点维度快照 / 兜底表结构一致 / 埋点事件去重（A8，含 user_id 非空守护）
# =============================================================================
set -uo pipefail

CONTAINER="${1:-mysql8}"
BIZ_DB="${2:-s2s_batch1}"
TRACK_DB="${3:-s2s_track_batch1}"
PASS="123456"

# 执行 SQL 并返回结果；失败时输出错误码，供断言判定
# $1 = SQL 文本
q() {
  docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" --default-character-set=utf8mb4 -D "$BIZ_DB" -e "$1" 2>&1 | grep -v 'Using a password'
}

qt() {
  docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" --default-character-set=utf8mb4 -D "$TRACK_DB" -e "$1" 2>&1 | grep -v 'Using a password'
}

echo "### A1 生成列不可写（期望 ERROR 3105）"
q "INSERT INTO post (user_id,type,leaf_category_id,l2_category_id,title,\`desc\`,grid_id,lng,lat,contact_channel,contact_value_enc,completeness_conditions,template_version,expire_at,key_version) VALUES (1,'resource',10101,999,'t','d','1_1',1.0,1.0,'phone',UNHEX('00'),'{}',1,NOW(),0);"

echo
echo "### A2 完整度生成列计算（期望 3条件全真=2 / 2条件=1 / 1条件=0）"
q "INSERT INTO post (user_id,type,leaf_category_id,title,\`desc\`,grid_id,lng,lat,contact_channel,contact_value_enc,completeness_conditions,template_version,expire_at,key_version) VALUES
 (1,'resource',10101,'全绿','d','1_1',1.0,1.0,'phone',UNHEX('00'),'{\"required_full\":true,\"address_precise\":true,\"leaf_matched\":true}',1,NOW(),0),
 (1,'resource',10102,'两条','d','1_1',1.0,1.0,'phone',UNHEX('00'),'{\"required_full\":true,\"address_precise\":true,\"leaf_matched\":false}',1,NOW(),0),
 (1,'resource',10203,'一条','d','1_1',1.0,1.0,'phone',UNHEX('00'),'{\"required_full\":true,\"address_precise\":false,\"leaf_matched\":false}',1,NOW(),0);"
q "SELECT title, leaf_category_id, l2_category_id, completeness_level FROM post ORDER BY id;"

echo
echo "### A3 盲索引唯一约束（同 identity_hash 第二次插入期望 ERROR 1062）"
q "INSERT INTO user (phone_mask,nickname,key_version) VALUES ('138****8000','甲',0),('139****9000','乙',0);"
q "INSERT INTO user_identity (user_id,identity_type,identity_hash,identity_value_enc,key_version) VALUES (1,'phone',UNHEX(REPEAT('AB',32)),UNHEX('00'),0);"
q "INSERT INTO user_identity (user_id,identity_type,identity_hash,identity_value_enc,key_version) VALUES (2,'phone',UNHEX(REPEAT('AB',32)),UNHEX('00'),0);"

echo
echo "### A4 收藏幂等：重复 INSERT ... ON DUPLICATE KEY UPDATE（期望始终 1 行）"
q "INSERT INTO favorite (user_id,post_id) VALUES (1,1) ON DUPLICATE KEY UPDATE deleted_at=NULL;"
q "INSERT INTO favorite (user_id,post_id) VALUES (1,1) ON DUPLICATE KEY UPDATE deleted_at=NULL;"
q "SELECT COUNT(*) AS rows_after_double_insert FROM favorite WHERE user_id=1 AND post_id=1;"

echo "--- 取消收藏后重新收藏（期望仍 1 行且 deleted_at 复位为 NULL）"
q "UPDATE favorite SET deleted_at=NOW() WHERE user_id=1 AND post_id=1;"
q "INSERT INTO favorite (user_id,post_id) VALUES (1,1) ON DUPLICATE KEY UPDATE deleted_at=NULL;"
q "SELECT COUNT(*) AS cnt, MAX(deleted_at) AS deleted_at FROM favorite WHERE user_id=1 AND post_id=1;"

echo
echo "### A5 写守卫分流"
q "UPDATE post SET status='active' WHERE id=1;"
echo "--- 用户意图写：version 不匹配（期望 Rows matched: 0）"
q "UPDATE post SET status='archived', version=version+1 WHERE id=1 AND version=999;"
echo "--- 系统派生写：status 不在前驱集（期望 Rows matched: 0，静默跳过）"
q "UPDATE post SET status='archived', status_reason=1 WHERE id=1 AND status IN ('draft');"
echo "--- 系统派生写：status 在前驱集（期望 Rows matched: 1）"
q "UPDATE post SET status='archived', status_reason=1 WHERE id=1 AND status IN ('active','hidden');"
q "SELECT id,status,status_reason FROM post WHERE id=1;"

echo
echo "### A6 埋点维度快照列可写入"
qt "INSERT INTO track_event_202609 (event_name,interaction_id,user_id,ts,props,leaf_category_id,completeness_level,is_ai_assisted,grid_id) VALUES ('post_published','11111111-1111-1111-1111-111111111111',1,NOW(3),'{\"a\":1}',10101,2,1,'1_1');"
qt "SELECT event_name,leaf_category_id,completeness_level,is_ai_assisted,grid_id FROM track_event_202609;"

echo
echo "### A7 兜底表与月表列结构一致性（期望差集为空）"
qt "SELECT column_name,data_type FROM information_schema.columns WHERE table_schema='$TRACK_DB' AND table_name='track_event_202609'
    AND (column_name,data_type) NOT IN (SELECT column_name,data_type FROM information_schema.columns WHERE table_schema='$TRACK_DB' AND table_name='track_event_fallback');"

echo
echo "### A8 埋点事件去重（uk_event_dedup）"
echo "--- A8.1 同键重复插入：期望 affected 0 行、表内仍 1 行（不报错、不新增）"
qt "INSERT INTO track_event_202609 (event_name,interaction_id,user_id,ts,props) VALUES ('layer_switch','22222222-2222-2222-2222-222222222222',1,'2026-09-06 10:00:00.123','{\"n\":1}') ON DUPLICATE KEY UPDATE id=id;"
qt "INSERT INTO track_event_202609 (event_name,interaction_id,user_id,ts,props) VALUES ('layer_switch','22222222-2222-2222-2222-222222222222',1,'2026-09-06 10:00:00.123','{\"n\":2}') ON DUPLICATE KEY UPDATE id=id;"
qt "SELECT COUNT(*) AS rows_after_double_insert, MAX(props->>'\$.n') AS props_n FROM track_event_202609 WHERE interaction_id='22222222-2222-2222-2222-222222222222';"

echo "--- A8.2 ts 差 1 毫秒即视为不同事件（期望 2 行）——证明去重键含毫秒精度"
qt "INSERT INTO track_event_202609 (event_name,interaction_id,user_id,ts) VALUES ('layer_switch','33333333-3333-3333-3333-333333333333',1,'2026-09-06 10:00:00.123') ON DUPLICATE KEY UPDATE id=id;"
qt "INSERT INTO track_event_202609 (event_name,interaction_id,user_id,ts) VALUES ('layer_switch','33333333-3333-3333-3333-333333333333',1,'2026-09-06 10:00:00.124') ON DUPLICATE KEY UPDATE id=id;"
qt "SELECT COUNT(*) AS rows_ts_1ms_apart FROM track_event_202609 WHERE interaction_id='33333333-3333-3333-3333-333333333333';"

echo "--- A8.3 同 interaction_id 不同 user_id 不互相覆盖（期望 2 行）——证明跨用户不碰撞"
qt "INSERT INTO track_event_202609 (event_name,interaction_id,user_id,ts) VALUES ('contact_event','44444444-4444-4444-4444-444444444444',1,'2026-09-06 10:00:00.500') ON DUPLICATE KEY UPDATE id=id;"
qt "INSERT INTO track_event_202609 (event_name,interaction_id,user_id,ts) VALUES ('contact_event','44444444-4444-4444-4444-444444444444',2,'2026-09-06 10:00:00.500') ON DUPLICATE KEY UPDATE id=id;"
qt "SELECT COUNT(*) AS rows_diff_user FROM track_event_202609 WHERE interaction_id='44444444-4444-4444-4444-444444444444';"

echo "--- A8.4 user_id 恒非 NULL（期望 0）——唯一索引不对 NULL 去重，此假设必须可执行地守护"
qt "SELECT COUNT(*) AS rows_with_null_user FROM track_event_202609 WHERE user_id IS NULL;"

echo "--- A8.5 idx_interaction 已删除且 interaction_id 等值查询仍走索引（期望 key=uk_event_dedup）"
qt "EXPLAIN SELECT id FROM track_event_202609 WHERE interaction_id='22222222-2222-2222-2222-222222222222';"

echo
echo "### DONE"
