#!/usr/bin/env bash
# =============================================================================
# 容量测算：实测 post / track_event 的真实行宽（数据 + 索引）
#
# 背景：上一轮 EXPLAIN 造数的 desc 字段只有 4 字节，测出的 95.6MB/50万行
#      不能代表生产行宽。本脚本按 PRD 的字段语义填接近真实的内容长度重测。
#
# 内容长度依据（PRD §13.2 字段约束 + §6 表单规格）：
#   title  VARCHAR(64)   取中位 20 个汉字  = 60 字节
#   desc   TEXT          取中位 100 个汉字 = 300 字节
#   address VARCHAR(128) 取 15 个汉字      = 45 字节
#   template_values JSON 取 5 个键值对
#   contact_value_enc    AEAD 密文，11 位手机号 + 12B IV + 16B tag ≈ 40 字节
#
# 输出：单行数据字节 / 单行索引字节，供 40G 盘与 256MB buffer_pool 反推上限
# 用完即删测算库，不污染 s2s / s2s_track
# =============================================================================
set -uo pipefail

CONTAINER="${1:-mysql8}"
ROWS="${2:-100000}"
SIZE_DB="s2s_sizing"
PASS="123456"

q() {
  docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" --default-character-set=utf8mb4 -D "$SIZE_DB" -e "$1" 2>&1 | grep -v 'Using a password'
}
qroot() {
  docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" --default-character-set=utf8mb4 -e "$1" 2>&1 | grep -v 'Using a password'
}

echo "### 建测算库，复制 post 与埋点月表结构"
qroot "DROP DATABASE IF EXISTS $SIZE_DB; CREATE DATABASE $SIZE_DB DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
q "CREATE TABLE post LIKE s2s.post;"
q "CREATE TABLE track_event LIKE s2s_track.track_event_202609;"

echo "### 按真实内容长度造 $ROWS 行 post"
q "SET SESSION cte_max_recursion_depth = $ROWS;
INSERT INTO post (user_id,type,leaf_category_id,title,\`desc\`,grid_id,price,price_unit,lng,lat,address,template_values,contact_channel,contact_value_enc,completeness_conditions,status,template_version,expire_at,key_version)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < $ROWS)
SELECT
  (n % 10000) + 1,
  IF(n % 2 = 0, 'demand', 'resource'),
  10101 + (n % 30),
  REPEAT('二手闲置物品转让说明标题', 2),
  REPEAT('这是一段接近真实长度的描述正文用于容量测算', 5),
  CONCAT(n % 50, '_', n % 47),
  99.50,
  '元/件',
  116.397428, 39.909187,
  '朝阳区某某街道某号楼',
  JSON_OBJECT('brand','某品牌','condition','九成新','buy_year','2024','warranty','无','reason','闲置'),
  'phone',
  RANDOM_BYTES(40),
  JSON_OBJECT('required_full', true, 'address_precise', true, 'leaf_matched', n % 3 = 0),
  'active', 1, DATE_ADD(NOW(), INTERVAL 7 DAY), 0
FROM seq;"

echo "### 按真实内容长度造 $ROWS 行埋点事件"
q "SET SESSION cte_max_recursion_depth = $ROWS;
INSERT INTO track_event (event_name, interaction_id, user_id, ts, props, leaf_category_id, completeness_level, is_ai_assisted, grid_id)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < $ROWS)
SELECT
  ELT((n % 5) + 1, 'post_published','map_pins_loaded','contact_clicked','category_selected','app_launched'),
  UUID(),
  (n % 10000) + 1,
  NOW(3),
  JSON_OBJECT('page','map','network_type','wifi','duration_ms', n % 3000, 'source','tab'),
  10101 + (n % 30), n % 3, n % 2, CONCAT(n % 50, '_', n % 47)
FROM seq;"

q "ANALYZE TABLE post, track_event;" > /dev/null

echo
echo "### 实测行宽（字节/行）"
q "SELECT table_name,
          table_rows,
          ROUND(data_length/1024/1024,1)  AS data_mb,
          ROUND(index_length/1024/1024,1) AS index_mb,
          ROUND(data_length/$ROWS)        AS data_bytes_per_row,
          ROUND(index_length/$ROWS)       AS index_bytes_per_row,
          ROUND((data_length+index_length)/$ROWS) AS total_bytes_per_row
   FROM information_schema.tables
   WHERE table_schema='$SIZE_DB' ORDER BY table_name;"

echo
echo "### post 各索引体积占比（看 idx_pins_cover 的代价）"
q "SELECT index_name, ROUND(stat_value * @@innodb_page_size / 1024 / 1024, 1) AS size_mb
   FROM mysql.innodb_index_stats
   WHERE database_name='$SIZE_DB' AND table_name='post' AND stat_name='size'
   ORDER BY size_mb DESC;"

echo
echo "### 清理测算库"
qroot "DROP DATABASE $SIZE_DB;"
echo "### DONE"
