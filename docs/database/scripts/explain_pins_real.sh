#!/usr/bin/env bash
# =============================================================================
# /map/pins 覆盖索引复测 —— 真实长尾分布造数版（KTD7 / R15）
#
# 上一轮问题：grid_id = CONCAT(n%1000,'_',n%997) 把帖子打得过散，
#            单网格单类目最多只有 1 行，EXPLAIN 虽命中覆盖索引，
#            但 rows=1 的耗时不足以支撑 P95 性能结论。
#
# 本轮改法：模拟真实地理分布 —— 70% 帖子集中在 5 个热点网格，
#          30% 散落在 45 个长尾网格；类目 10 个、类型 2 个，与网格取模独立。
#          期望热点网格单类目单类型的 active 行数达到千行量级。
#
# 参数：$1 = 容器名（默认 mysql8），$2 = 造数行数（默认 500000）
# 判定：EXPLAIN ANALYZE 输出 "Covering index range scan ... using idx_pins_cover"
#      且在千行量级下 P95 耗时仍在毫秒级
# =============================================================================
set -uo pipefail

CONTAINER="${1:-mysql8}"
ROWS="${2:-500000}"
BIZ_DB="s2s_batch1"
PASS="123456"

# /map/pins 响应契约的真实 SELECT 列表（PRD §6.10 pins[] schema 六项）。
# 关键：必须含 lng/lat —— 上一轮用 "id, user_id, completeness_level" 测出的
# index-only scan 不代表真实查询，坐标不在索引里会回表。
PINS_COLS="id, lng, lat, leaf_category_id, type, completeness_level"

# 执行一段 SQL 并回显结果（过滤 mysql 客户端的密码告警）
q() {
  docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" --default-character-set=utf8mb4 -D "$BIZ_DB" -e "$1" 2>&1 | grep -v 'Using a password'
}
# 执行一段 SQL 只取裸值（-N -B），供 shell 变量捕获
qv() {
  docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" -N -B -D "$BIZ_DB" -e "$1" 2>/dev/null
}

echo "### 清空 post，按长尾分布造 $ROWS 行"
q "TRUNCATE TABLE post;"

# grid：n%10<7 → 落入 5 个热点网格(0..4)；否则落入 45 个长尾网格(5..49)
# category：FLOOR(n/10)%10，与 n%10 独立，避免与网格取模同余耦合
# type：FLOOR(n/100)%2，同理保持独立
q "SET SESSION cte_max_recursion_depth = $ROWS;
INSERT INTO post (user_id,type,leaf_category_id,title,\`desc\`,grid_id,lng,lat,contact_channel,contact_value_enc,completeness_conditions,status,template_version,expire_at,key_version)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < $ROWS)
SELECT
  (n % 10000) + 1,
  IF(FLOOR(n/100) % 2 = 0, 'demand', 'resource'),
  10101 + (FLOOR(n/10) % 10),
  CONCAT('title_', n),
  'desc',
  CONCAT(IF(n % 10 < 7, n % 5, 5 + (n % 45)), '_0'),
  116.0 + (n % 1000) / 10000,
  39.0 + (n % 997) / 10000,
  'phone',
  UNHEX('00'),
  JSON_OBJECT('required_full', n % 2 = 0, 'address_precise', n % 3 = 0, 'leaf_matched', n % 5 = 0),
  ELT((FLOOR(n/1000) % 4) + 1, 'draft', 'active', 'active', 'archived'),
  1,
  DATE_ADD(NOW(), INTERVAL (n % 14) DAY),
  0
FROM seq;"

q "SELECT COUNT(*) AS total_rows FROM post;"
echo "### 更新统计信息"
q "ANALYZE TABLE post;" > /dev/null

echo
echo "### 网格分布检查（前 8 名，验证长尾是否成形）"
q "SELECT grid_id, COUNT(*) AS c FROM post GROUP BY grid_id ORDER BY c DESC LIMIT 8;"

echo
echo "### 热点组合（grid + category + type，status=active 且未过期）"
q "SELECT grid_id, leaf_category_id, type, COUNT(*) AS c
   FROM post WHERE status='active' AND expire_at > NOW()
   GROUP BY grid_id, leaf_category_id, type ORDER BY c DESC LIMIT 5;"

HOT=$(qv "SELECT CONCAT(grid_id,'|',leaf_category_id,'|',type) FROM post
          WHERE status='active' AND expire_at > NOW()
          GROUP BY grid_id, leaf_category_id, type ORDER BY COUNT(*) DESC LIMIT 1;" | tail -1)
GRID=$(echo "$HOT" | cut -d'|' -f1)
CAT=$(echo "$HOT"  | cut -d'|' -f2)
TYP=$(echo "$HOT"  | cut -d'|' -f3)

WHERE="grid_id='$GRID' AND leaf_category_id=$CAT AND type='$TYP' AND status='active' AND expire_at > NOW()"
MATCHED=$(qv "SELECT COUNT(*) FROM post WHERE $WHERE;" | tail -1)
echo
echo "### 选用热点：grid_id=$GRID leaf_category_id=$CAT type=$TYP，命中 $MATCHED 行"
if [ "${MATCHED:-0}" -lt 100 ]; then
  echo "### FAIL：命中行数 < 100，分布仍不真实，EXPLAIN 结论无效"
  exit 1
fi

echo
echo "### EXPLAIN（期望 key=idx_pins_cover，Extra 含 Using index）"
q "EXPLAIN SELECT $PINS_COLS FROM post WHERE $WHERE;"

echo
echo "### EXPLAIN ANALYZE"
q "EXPLAIN ANALYZE SELECT $PINS_COLS FROM post WHERE $WHERE;"

echo
echo "### 反例对照：SELECT * 回表（期望 Extra 不含 Using index）"
q "EXPLAIN SELECT * FROM post WHERE $WHERE;"

echo
echo "### 多网格 IN 查询（真实视野内多格聚合，9 格）"
q "EXPLAIN ANALYZE SELECT $PINS_COLS FROM post
   WHERE grid_id IN ('0_0','1_0','2_0','3_0','4_0','5_0','6_0','7_0','8_0')
     AND leaf_category_id=$CAT AND type='$TYP' AND status='active' AND expire_at > NOW();"

echo
echo "### 耗时采样：连续 15 次 EXPLAIN ANALYZE，取引擎内部 actual time 末值（毫秒）"
SAMPLES=""
for i in $(seq 1 15); do
  ms=$(qv "EXPLAIN ANALYZE SELECT $PINS_COLS FROM post WHERE $WHERE;" \
       | grep -o 'actual time=[0-9.]*\.\.[0-9.]*' | head -1 | sed 's/.*\.\.//')
  SAMPLES="$SAMPLES $ms"
done
echo "samples(ms):$SAMPLES"
echo "$SAMPLES" | tr ' ' '\n' | grep -v '^$' | sort -g | awk '
  { a[NR] = $1 }
  END {
    n = NR
    p50 = a[int(n * 0.5) + 0 < 1 ? 1 : int(n * 0.5)]
    p95 = a[int(n * 0.95) < 1 ? 1 : int(n * 0.95)]
    printf "n=%d  min=%s  p50=%s  p95=%s  max=%s\n", n, a[1], p50, p95, a[n]
  }'

echo
echo "### 表规模与索引体积"
q "SELECT table_rows, ROUND(data_length/1024/1024,1) AS data_mb, ROUND(index_length/1024/1024,1) AS index_mb
   FROM information_schema.tables WHERE table_schema='$BIZ_DB' AND table_name='post';"

echo "### DONE"
