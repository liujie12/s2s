#!/usr/bin/env bash
# ============================================================================
# S2S MySQL 备份脚本（多环境）
# ----------------------------------------------------------------------------
# 依据：《部署架构设计文档》§8 备份与恢复、§14.2 环境切换
#       《系统总体架构设计文档》§4.5（mysqldump 日备 + OSS 7 份 + 本地 1 份）
#       《系统安全设计方案》§10（备份文件权限 600、pepper 与备份物理分离）
#
# 功能：全库逻辑备份 → gzip 压缩 → 上传 OSS → 清理本地旧备份
# 用法：bash deploy/scripts/backup-mysql.sh <env>
#       env 省略时默认取 deploy/.current-env（env-up.sh 记录的当前环境），
#       两者都没有则报错退出 —— 刻意不默认 prod：
#       在 dev 机器上误跑出一份「以为是 dev 其实读的是 prod 凭据」的备份，
#       等于把生产数据落到了开发机磁盘上。
#
# 执行时机：每日一次，由 crontab 触发（见文末 crontab 示例）
#
# 纪律：
#   1. 用 --single-transaction 保证一致性快照且不锁表
#   2. 备份文件权限 600（备份含全量加密列密文，泄露即等于数据库泄露）
#   3. 【禁止】把 env 文件一起打进备份包（pepper 与备份必须物理分离，
#      两者同时泄露 = 盲索引可被离线穷举反推手机号）
#   4. 本地只留最近 1 份（40G 盘放不下更多），OSS 保留 7 份靠桶 lifecycle 规则
#   5. 备份目录按环境分开，避免 dev 备份把 prod 的那一份挤掉
# ============================================================================

set -euo pipefail

# --- 路径与常量 ---------------------------------------------------------------
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${DEPLOY_DIR}/.current-env"

# ---------------------------------------------------------------------------
# 函数：resolve_env
# 功能：确定备份目标环境。优先取位置参数，其次取 env-up.sh 的记账文件
# 参数：$1 — 可选的环境名（dev/staging/prod）
# 返回：向 stdout 输出环境名；无法确定或取值非法时退出 1
# ---------------------------------------------------------------------------
resolve_env() {
  local candidate="${1:-}"

  if [[ -z "${candidate}" && -f "${STATE_FILE}" ]]; then
    candidate="$(cat "${STATE_FILE}" 2>/dev/null || true)"
  fi

  if [[ -z "${candidate}" ]]; then
    echo "[ERROR] 未指定环境，且 ${STATE_FILE} 不存在。" >&2
    echo "        用法：bash deploy/scripts/backup-mysql.sh <dev|staging|prod>" >&2
    exit 1
  fi

  case "${candidate}" in
    dev|staging|prod) echo "${candidate}" ;;
    *) echo "[ERROR] 环境名必须是 dev / staging / prod 之一，收到：${candidate}" >&2; exit 1 ;;
  esac
}

ENV_NAME="$(resolve_env "${1:-}")"
ENV_FILE="${DEPLOY_DIR}/env/.env.${ENV_NAME}"
BACKUP_DIR="/var/backups/s2s/${ENV_NAME}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/s2s-${ENV_NAME}-${TIMESTAMP}.sql.gz"
LOG_FILE="/var/log/s2s-backup.log"
MYSQL_CONTAINER="s2s-mysql"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${ENV_NAME}] $*" | tee -a "${LOG_FILE}"; }

# --- 前置校验 -----------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  log "[ERROR] 未找到 ${ENV_FILE}，无法获取数据库凭据"
  exit 1
fi

# 容器名不带环境后缀（三环境共用），因此必须确认当前跑的确实是目标环境，
# 否则会用 dev 的凭据去 dump 一个实际装着 prod 数据的容器
if [[ -f "${STATE_FILE}" ]]; then
  RUNNING_ENV="$(cat "${STATE_FILE}" 2>/dev/null || true)"
  if [[ -n "${RUNNING_ENV}" && "${RUNNING_ENV}" != "${ENV_NAME}" ]]; then
    log "[ERROR] 当前运行的是 ${RUNNING_ENV} 环境，拒绝以 ${ENV_NAME} 的凭据备份。"
    log "        容器名三环境共用，此时 dump 到的数据属于 ${RUNNING_ENV}。"
    exit 1
  fi
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER}$"; then
  log "[ERROR] 容器 ${MYSQL_CONTAINER} 未运行，无法备份"
  exit 1
fi

# 只读取需要的变量，避免把全部密钥（AEAD/HMAC/JWT 等）灌进当前 shell 环境。
# 逐变量提取替代 set -a + source：set -a 会在 shell 中暴露所有环境变量，
# 包括不应在备份脚本临时进程中暴露的加密密钥。
MYSQL_ROOT_PASSWORD="$(grep -oP '^MYSQL_ROOT_PASSWORD=\K.*' "${ENV_FILE}" 2>/dev/null || true)"
MYSQL_DATABASE="$(grep -oP '^MYSQL_DATABASE=\K.*' "${ENV_FILE}" 2>/dev/null || true)"
MYSQL_TRACK_DATABASE="$(grep -oP '^MYSQL_TRACK_DATABASE=\K.*' "${ENV_FILE}" 2>/dev/null || true)"
OSS_BUCKET_NAME="$(grep -oP '^OSS_BUCKET_NAME=\K.*' "${ENV_FILE}" 2>/dev/null || true)"

: "${MYSQL_ROOT_PASSWORD:?[ERROR] ${ENV_FILE} 中缺少 MYSQL_ROOT_PASSWORD}"
: "${MYSQL_DATABASE:?[ERROR] ${ENV_FILE} 中缺少 MYSQL_DATABASE}"
: "${MYSQL_TRACK_DATABASE:?[ERROR] ${ENV_FILE} 中缺少 MYSQL_TRACK_DATABASE}"

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

# --- 1. 逻辑备份 --------------------------------------------------------------
# --single-transaction：InnoDB 一致性快照，不锁表（线上业务无感）
# --routines --triggers --events：存储过程、触发器、定时事件一并导出
# --databases 显式列出业务库与埋点库，不用 --all-databases（避免把 mysql 系统库
#   的用户表一起导出，恢复时会覆盖目标实例的账号体系）
log "[1/4] 开始 mysqldump（业务库 ${MYSQL_DATABASE} + 埋点库 ${MYSQL_TRACK_DATABASE}）"
docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "${MYSQL_CONTAINER}" \
  mysqldump \
    --single-transaction \
    --routines --triggers --events \
    --default-character-set=utf8mb4 \
    -u root \
    --databases "${MYSQL_DATABASE}" "${MYSQL_TRACK_DATABASE}" \
  | gzip -6 > "${BACKUP_FILE}"

# --- 2. 权限收紧 --------------------------------------------------------------
# 备份含全量加密列密文，权限必须 600
log "[2/4] 设置备份文件权限 600"
chmod 600 "${BACKUP_FILE}"

BACKUP_SIZE="$(du -h "${BACKUP_FILE}" | cut -f1)"
log "      备份完成：${BACKUP_FILE}（${BACKUP_SIZE}）"

# --- 3. 上传 OSS --------------------------------------------------------------
# 仅 prod 上传异地：dev/staging 的数据是可重建的测试数据，上传只是白占存储费用，
# 而且会让 OSS 桶里混进无法与生产备份区分的文件，恢复时容易取错。
# OSS 侧保留 7 份靠桶的 lifecycle 规则实现（前缀 backup/，过期天数 7），
# 不在脚本里删远端文件：脚本删远端一旦有 bug 会把备份全清掉。
if [[ "${ENV_NAME}" == "prod" ]]; then
  : "${OSS_BUCKET_NAME:?[ERROR] ${ENV_FILE} 中缺少 OSS_BUCKET_NAME}"
  log "[3/4] 上传至 OSS：oss://${OSS_BUCKET_NAME}/backup/"
  if command -v ossutil >/dev/null 2>&1; then
    ossutil cp "${BACKUP_FILE}" "oss://${OSS_BUCKET_NAME}/backup/" --force
    log "      上传成功"
  else
    log "[WARN] 未安装 ossutil，跳过上传。备份仅存本地，不满足异地要求"
    log "[WARN] 安装：curl https://gosspublic.alicdn.com/ossutil/install.sh | bash"
  fi
else
  log "[3/4] ${ENV_NAME} 环境不上传 OSS（仅 prod 需要异地备份）"
fi

# --- 4. 清理本地旧备份 --------------------------------------------------------
# 本地只留最近 1 份：40G 盘的「未分配缓冲 5GB」要留给 mysqldump 中间产物，
# 堆积多份会挤占这块缓冲（《可观测性架构方案》§7）
log "[4/4] 清理本地旧备份（保留最近 1 份）"
find "${BACKUP_DIR}" -name "s2s-${ENV_NAME}-*.sql.gz" -type f -printf '%T@ %p\n' \
  | sort -rn | tail -n +2 | cut -d' ' -f2- \
  | while read -r old; do
      log "      删除 ${old}"
      rm -f "${old}"
    done

log "[DONE] 备份流程完成"

# ============================================================================
# crontab 安装示例（生产环境每日 03:30 执行，避开业务高峰）：
#   crontab -e
#   30 3 * * * /usr/bin/bash /srv/s2s/deploy/scripts/backup-mysql.sh prod
#
# 恢复演练命令（《部署架构设计文档》§8.1：未演练的备份不算备份）：
#   1. 从 OSS 拉取备份
#      ossutil cp oss://${OSS_BUCKET_NAME}/backup/s2s-prod-YYYYMMDD-HHMMSS.sql.gz /tmp/
#   2. 导入到 staging 验证（不要直接导进生产库）
#      gunzip -c /tmp/s2s-prod-*.sql.gz | docker exec -i s2s-mysql mysql -u root -p
#   3. 验证关键表行数与业务连通性
#   4. 演练后删除临时库与本地临时文件
# ============================================================================
