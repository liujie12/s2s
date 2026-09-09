#!/usr/bin/env bash
# =============================================================================
# Batch1 schema 落库验证脚本
# 用途：在 WSL Docker 的 MySQL 容器内建库、执行 DDL、跑验收断言
# 参数：$1 = 容器名（默认 mysql8）
# 说明：本脚本只操作 s2s_batch1 / s2s_track_batch1 两个验证库，不动其他数据
# =============================================================================
set -uo pipefail

CONTAINER="${1:-mysql8}"
BIZ_DB="s2s_batch1"
TRACK_DB="s2s_track_batch1"
PASS="123456"

# 在容器内执行 SQL，屏蔽明文密码告警
# $1 = 目标 database（空串表示不指定库）
# $2 = SQL 文本
run_sql() {
  local db="$1"; shift
  local sql="$1"
  if [ -z "$db" ]; then
    docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" --default-character-set=utf8mb4 -e "$sql" 2>&1 | grep -v 'Using a password'
  else
    docker exec -i "$CONTAINER" mysql -uroot -p"$PASS" --default-character-set=utf8mb4 -D "$db" -e "$sql" 2>&1 | grep -v 'Using a password'
  fi
}

# 把宿主机 SQL 文件导入容器内指定库
# $1 = 目标 database，$2 = 容器内 SQL 文件路径
run_file() {
  docker exec -i "$CONTAINER" bash -c "mysql -uroot -p$PASS --default-character-set=utf8mb4 -D $1 < $2" 2>&1 | grep -v 'Using a password'
}

echo "=== [0] 版本与环境 ==="
run_sql "" "SELECT VERSION() AS mysql_version;"

echo "=== [1] 重建验证库 ==="
run_sql "" "DROP DATABASE IF EXISTS $BIZ_DB; CREATE DATABASE $BIZ_DB DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
run_sql "" "DROP DATABASE IF EXISTS $TRACK_DB; CREATE DATABASE $TRACK_DB DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"

echo "=== [2] 执行业务库 DDL ==="
run_file "$BIZ_DB" /tmp/s2s/V1__init_schema.sql
echo "biz_ddl_exit=$?"

echo "=== [3] 执行埋点库 DDL ==="
run_file "$TRACK_DB" /tmp/s2s/V1__init_track_schema.sql
echo "track_ddl_exit=$?"

echo "=== [4] 业务库表数量（期望 15）==="
run_sql "$BIZ_DB" "SELECT COUNT(*) AS biz_table_count FROM information_schema.tables WHERE table_schema='$BIZ_DB';"
run_sql "$BIZ_DB" "SELECT table_name, engine, table_collation FROM information_schema.tables WHERE table_schema='$BIZ_DB' ORDER BY table_name;"

echo "=== [5] 埋点库表数量（期望 2）==="
run_sql "$TRACK_DB" "SELECT COUNT(*) AS track_table_count FROM information_schema.tables WHERE table_schema='$TRACK_DB';"

echo "=== [6] 非 InnoDB 或非 utf8mb4 的表（期望空）==="
run_sql "$BIZ_DB" "SELECT table_name, engine, table_collation FROM information_schema.tables WHERE table_schema='$BIZ_DB' AND (engine <> 'InnoDB' OR table_collation NOT LIKE 'utf8mb4%');"

echo "=== [7] 无 COMMENT 的列（期望空）==="
run_sql "$BIZ_DB" "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema='$BIZ_DB' AND (column_comment IS NULL OR column_comment='');"

echo "=== [8] 生成列落地情况 ==="
run_sql "$BIZ_DB" "SELECT table_name, column_name, extra FROM information_schema.columns WHERE table_schema='$BIZ_DB' AND generation_expression <> '';"

echo "=== [9] favorite 唯一索引 ==="
run_sql "$BIZ_DB" "SHOW INDEX FROM favorite;"

echo "=== [10] system_config 初始数据 ==="
run_sql "$BIZ_DB" "SELECT config_key, config_value FROM system_config;"

echo "=== ALL DONE ==="
