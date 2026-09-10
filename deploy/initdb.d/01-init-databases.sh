#!/bin/bash
# ============================================================================
# 01-init-databases.sh — MySQL 容器首启初始化：只建库授权、不建表（KTD-4 定案）
# ----------------------------------------------------------------------------
# 口径（KTD-4）：
#   · 本脚本【只】做两件事：幂等建库（CREATE DATABASE IF NOT EXISTS）+ 授权（GRANT）。
#     表结构一律由应用内 Flyway 迁移管理（编码规范 §4.9），本脚本不出现任何 CREATE TABLE。
#   · 原 docker-entrypoint-initdb.d 挂载的 .sql DDL 脚本（docs/database/ddl/）已改写为
#     本 .sh：MySQL initdb 机制对 .sql 不做变量展开，库名/账号写死会与 .env 脱耦；
#     .sh 内可用 $MYSQL_DATABASE / $MYSQL_TRACK_DATABASE / $MYSQL_USER 按环境展开。
#   · 两份 V1 DDL 已按 KTD-5 复制进工程 src/main/resources/db/migration{,_track}/，
#     由 Flyway 以应用账号执行；docs/database/ddl/ 仅存档 V1 快照。
#
# 幂等性：CREATE DATABASE IF NOT EXISTS 与 GRANT 重复执行均无副作用；
#   initdb.d 本身也只在数据卷为空的首启执行一次。
#
# 权限模型（与 FlywayTrackConfig 注释互证）：
#   · 本脚本以 root 经 unix socket 执行（initdb 阶段临时 mysqld 为 skip-networking，
#     只能走 socket；SOCKET 变量与官方 entrypoint 的 docker_temp_server_start 同源）；
#   · 应用账号持两库 ALL PRIVILEGES（含 DDL）——Flyway 迁移与埋点月表预建
#     （详设 §6 #2，CREATE TABLE ... LIKE）均以应用账号执行；早期「只授 DML、
#     月表预建由运维 root 执行」的口径随 KTD-4 作废。
#   · 账号经官方 entrypoint 以 $MYSQL_USER@'%' 创建，本脚本不再 CREATE USER，
#     只对同一账号补 track 库授权并对业务库授权做幂等复核。
#
# 变量来源：mysql 服务 env_file（deploy/env/.env.<env>）全量注入容器环境，
#   含 MYSQL_DATABASE / MYSQL_TRACK_DATABASE / MYSQL_USER / MYSQL_ROOT_PASSWORD；
#   变量值属运维可信源，库名以反引号包裹防标识符断裂。
#
# 执行形态（G-Q3 口径：模式位 100755）：
#   · Windows 工作树无法携带执行位，由部署机保证（git update-index --chmod=+x
#     或 env-up.sh 前置 chmod +x）；
#   · 有可执行位时 MySQL entrypoint 直接执行本脚本；无执行位时退化为 source，
#     故主体包在子 shell 内（set -u / 变量不污染 entrypoint 的 shell 状态，
#     失败退出码经子 shell 传给 entrypoint 的 set -e 中止首启）。
# ============================================================================

(
  set -euo pipefail

  # initdb 阶段临时 mysqld 仅监听 unix socket（--skip-networking）
  SOCKET_PATH="${SOCKET:-/var/run/mysqld/mysqld.sock}"

  echo "[initdb] KTD-4：开始建库授权（只建库授权、不建表）..."
  echo "[initdb] 业务库=$MYSQL_DATABASE 埋点库=$MYSQL_TRACK_DATABASE 应用账号=$MYSQL_USER"

  # MYSQL_PWD 经环境传给 mysql 客户端，避免口令出现在进程参数表
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -u root -S "$SOCKET_PATH" <<SQL
CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS \`$MYSQL_TRACK_DATABASE\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
GRANT ALL PRIVILEGES ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%';
GRANT ALL PRIVILEGES ON \`$MYSQL_TRACK_DATABASE\`.* TO '$MYSQL_USER'@'%';
FLUSH PRIVILEGES;
SQL

  echo "[initdb] 完成：$MYSQL_DATABASE / $MYSQL_TRACK_DATABASE 已建库并授权给 $MYSQL_USER；表结构由应用 Flyway 迁移接管"
)
