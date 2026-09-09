#!/usr/bin/env bash
# =============================================================================
# /map/pins 覆盖索引 EXPLAIN 复测：用真实存在的热点数据验证 index-only scan
# 上一轮用了臆造的 grid_id 组合导致 COUNT=0，结论不足以采信，本脚本取实际热点
# =============================================================================
set -uo pipefail
BIZ_DB="s2s_batch1"

q() {
  docker exec -i mysql8 mysql -uroot -p123456 --default-character-set=utf8mb4 -D "$BIZ_DB" -e "$1" 2>&1 | grep -v 'Using a password'
}

echo "### 取实际存在的热点组合（按行数降序）"
q "SELECT grid_id, leaf_category_id, type, COUNT(*) AS c
   FROM post WHERE status='active' AND expire_at > NOW()
   GROUP BY grid_id, leaf_category_id, type ORDER BY c DESC LIMIT 5;"

# 取排名第一的组合，注入后续 EXPLAIN
HOT=$(docker exec -i mysql8 mysql -uroot -p123456 -N -B -D "$BIZ_DB" -e \
  "SELECT CONCAT(grid_id,'|',leaf_category_id,'|',type) FROM post
   WHERE status='active' AND expire_at > NOW()
   GROUP BY grid_id, leaf_category_id, type ORDER BY COUNT(*) DESC LIMIT 1;" 2>/dev/null | tail -1)

GRID=$(echo "$HOT" | cut -d'|' -f1)
CAT=$(echo "$HOT"  | cut -d'|' -f2)
TYP=$(echo "$HOT"  | cut -d'|' -f3)
echo "### 选用热点：grid_id=$GRID leaf_category_id=$CAT type=$TYP"

echo
echo "### 命中行数（必须 > 0，否则 EXPLAIN 结论无意义）"
q "SELECT COUNT(*) AS matched_rows FROM post
   WHERE grid_id='$GRID' AND leaf_category_id=$CAT AND type='$TYP'
     AND status='active' AND expire_at > NOW();"

echo
echo "### EXPLAIN（期望 key=idx_pins_cover，Extra 含 Using index）"
q "EXPLAIN SELECT id, user_id, completeness_level FROM post
   WHERE grid_id='$GRID' AND leaf_category_id=$CAT AND type='$TYP'
     AND status='active' AND expire_at > NOW();"

echo
echo "### EXPLAIN ANALYZE（真实执行，看实际行数与耗时）"
q "EXPLAIN ANALYZE SELECT id, user_id, completeness_level FROM post
   WHERE grid_id='$GRID' AND leaf_category_id=$CAT AND type='$TYP'
     AND status='active' AND expire_at > NOW();"

echo
echo "### 反例对照：SELECT * 触发回表（期望 Extra 不含 Using index）"
q "EXPLAIN SELECT * FROM post
   WHERE grid_id='$GRID' AND leaf_category_id=$CAT AND type='$TYP'
     AND status='active' AND expire_at > NOW();"

echo
echo "### 表规模与索引体积"
q "SELECT table_rows, ROUND(data_length/1024/1024,1) AS data_mb, ROUND(index_length/1024/1024,1) AS index_mb
   FROM information_schema.tables WHERE table_schema='$BIZ_DB' AND table_name='post';"

echo "### DONE"
