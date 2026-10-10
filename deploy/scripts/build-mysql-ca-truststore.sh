#!/usr/bin/env bash
# ============================================================================
# S2S MySQL CA 信任库生成脚本（多环境）
# ----------------------------------------------------------------------------
# 依据：《系统安全设计方案》§10.1（数据面 TLS 的服务端身份校验）
#       《部署架构设计文档》§14.4（数据源 URL 拼装）/ §7.3（密钥纪律）
#       说明文档 §2.9 DEC-05（2026-10-10 裁定：sslMode 由 REQUIRED 收紧为 VERIFY_CA）
#
# 功能：从运行中的 MySQL 容器取出其自签 CA 证书 → 转成 Java 可读的 PKCS12
#       信任库 → 落到 deploy/certs/<env>/mysql-ca.p12，供 app 容器只读挂载。
#
# 用法：bash deploy/scripts/build-mysql-ca-truststore.sh <env>
#       env 省略时默认取 deploy/.current-env（env-up.sh 记录的当前环境）
#
# 为什么必须造信任库（而不是「指一个 pem」）：
#   Connector/J 的 VERIFY_CA 只认 JKS / PKCS12 信任库（由
#   trustCertificateKeyStoreUrl / Type / Password 三个属性指定）；
#   官方属性表（MySQL Connector/J Developer Guide §6.3.5 Security）无 PEM 入口。
#
# 纪律：
#   1. 【禁止】把 CA 私钥（ca-key.pem）带出容器 —— 本脚本只取 ca.pem（公钥证书）
#   2. 落盘 .p12 权限 644：内含只有公开 CA 证书，口令只防篡改、不防读取；
#      而 app 容器以非 root（s2s）运行，600 会让它读不到 → 启动即失败
#   3. 信任库【不入库】（.gitignore 已忽略 deploy/certs/）
#   4. 口令只从 env 文件读，【禁止】写死在命令行或本脚本里
#
# ⚠ 运维陷阱（务必知悉）：CA 由 MySQL 首次初始化时生成在 mysql_data 卷内。
#   该卷一旦被清空重建（`down -v` / 换宿主机 / 手工删卷），CA 即变化，
#   本脚本必须重跑 —— 否则 app 会以「证书链校验失败」起不来。
#   判据：重跑后 .p12 的 sha256 变了，就说明 CA 换过。
#
# 前置：① 目标环境的 MySQL 容器已运行；
#       ② deploy/env/.env.<env> 已含 MYSQL_SSL_MODE 与 MYSQL_TLS_TRUSTSTORE_PASSWORD
# ============================================================================

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${DEPLOY_DIR}/.current-env"
MYSQL_CONTAINER="s2s-mysql"
APP_CONTAINER="s2s-app"
CA_IN_CONTAINER="/var/lib/mysql/ca.pem"
# keytool 兜底来源：本仓库 Dockerfile 的 builder 阶段镜像（必带完整 JDK）
KEYTOOL_BUILDER_IMAGE="maven:3.9-eclipse-temurin-21"

# ---------------------------------------------------------------------------
# 函数：resolve_env
# 功能：确定目标环境。优先取位置参数，其次取 env-up.sh 的记账文件
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
    echo "        用法：bash deploy/scripts/build-mysql-ca-truststore.sh <dev|staging|prod>" >&2
    exit 1
  fi

  case "${candidate}" in
    dev|staging|prod) echo "${candidate}" ;;
    *) echo "[ERROR] 环境名必须是 dev / staging / prod 之一，收到：${candidate}" >&2; exit 1 ;;
  esac
}

ENV_NAME="$(resolve_env "${1:-}")"
ENV_FILE="${DEPLOY_DIR}/env/.env.${ENV_NAME}"
CERT_DIR="${DEPLOY_DIR}/certs/${ENV_NAME}"
CA_FILE="${CERT_DIR}/ca.pem"
P12_FILE="${CERT_DIR}/mysql-ca.p12"

# ---------------------------------------------------------------------------
# 函数：log
# 功能：带环境前缀与时间戳打印一行进度
# 参数：$* — 日志内容
# 返回：无（写 stdout）
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${ENV_NAME}] $*"; }

# --- 前置校验 -----------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  log "[ERROR] 未找到 ${ENV_FILE}，无法获取信任库口令"
  log "        先按 deploy/env/.env.${ENV_NAME}.example 补齐该文件"
  exit 1
fi

# 容器名三环境共用，先确认当前跑的确实是目标环境，
# 否则会把 dev 的 CA 写进 prod 目录（同 backup-mysql.sh 的理由）
if [[ -f "${STATE_FILE}" ]]; then
  RUNNING_ENV="$(cat "${STATE_FILE}" 2>/dev/null || true)"
  if [[ -n "${RUNNING_ENV}" && "${RUNNING_ENV}" != "${ENV_NAME}" ]]; then
    log "[ERROR] 当前运行的是 ${RUNNING_ENV} 环境，拒绝为其生成 ${ENV_NAME} 的信任库"
    exit 1
  fi
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER}$"; then
  log "[ERROR] 容器 ${MYSQL_CONTAINER} 未运行。先启动该环境："
  log "        bash deploy/scripts/env-up.sh ${ENV_NAME}"
  exit 1
fi

# 只读所需变量，避免把全部密钥（AEAD/HMAC/JWT 等）灌进当前 shell 环境
MYSQL_SSL_MODE="$(grep -oP '^MYSQL_SSL_MODE=\K.*' "${ENV_FILE}" 2>/dev/null || true)"
TRUSTSTORE_PASSWORD="$(grep -oP '^MYSQL_TLS_TRUSTSTORE_PASSWORD=\K.*' "${ENV_FILE}" 2>/dev/null || true)"

: "${MYSQL_SSL_MODE:?[ERROR] ${ENV_FILE} 中缺少 MYSQL_SSL_MODE（本仓库期望 VERIFY_CA）}"
: "${TRUSTSTORE_PASSWORD:?[ERROR] ${ENV_FILE} 中缺少 MYSQL_TLS_TRUSTSTORE_PASSWORD}"

if [[ "${MYSQL_SSL_MODE}" != "VERIFY_CA" ]]; then
  log "[WARN] MYSQL_SSL_MODE=${MYSQL_SSL_MODE}（非 VERIFY_CA）——信任库仍会生成，但当前连接不校验证书链"
fi

# 口令规则：① 太短无意义；② 只允许字母数字 —— 它会拼进 JDBC URL 的查询串，
# 含 & = ? # 等字符会被判为参数边界或被 URL 转义规则吃掉
if [[ ${#TRUSTSTORE_PASSWORD} -lt 6 ]]; then
  log "[ERROR] MYSQL_TLS_TRUSTSTORE_PASSWORD 少于 6 字符，请换成更长的口令"
  exit 1
fi
if [[ ! "${TRUSTSTORE_PASSWORD}" =~ ^[A-Za-z0-9]+$ ]]; then
  log "[ERROR] MYSQL_TLS_TRUSTSTORE_PASSWORD 只允许字母与数字（会进 JDBC URL 查询串）"
  log "        生成建议：openssl rand -base64 18 | tr -d '/+=' | cut -c1-24"
  exit 1
fi

# --- 1. 取 CA 证书 ------------------------------------------------------------
log "[1/3] 从 ${MYSQL_CONTAINER} 取 CA 证书（只取公钥证书，不碰 ca-key.pem）"

mkdir -p "${CERT_DIR}"
chmod 700 "${CERT_DIR}"

if ! docker exec "${MYSQL_CONTAINER}" sh -c "test -s ${CA_IN_CONTAINER}" 2>/dev/null; then
  log "[ERROR] 容器内 ${CA_IN_CONTAINER} 不存在或为空"
  log "        MySQL 8 首次初始化时会自动生成自签证书；缺失说明该数据卷不是由"
  log "        本仓库 compose 初始化的，或被替换过。排查："
  log "        docker exec ${MYSQL_CONTAINER} ls -l /var/lib/mysql/*.pem"
  exit 1
fi

docker exec "${MYSQL_CONTAINER}" cat "${CA_IN_CONTAINER}" > "${CA_FILE}"
chmod 644 "${CA_FILE}"

if ! grep -q 'BEGIN CERTIFICATE' "${CA_FILE}"; then
  log "[ERROR] 取到的 ${CA_FILE} 不是 PEM 证书，请人工检查"
  exit 1
fi
log "        CA 证书：${CA_FILE}（$(wc -c < "${CA_FILE}") 字节）"

# --- 2. 定位 keytool 并生成 PKCS12 信任库 -------------------------------------
# 探测顺序：宿主 → app 容器所用镜像 → builder 镜像。
# 不写死任何一条：宿主是否装 JDK、app 镜像是 JRE（未必含 keytool）、
# builder 镜像是否已被 build 拉取过，三者都随部署形态变化。
log "[2/3] 定位 keytool"
KEYTOOL_MODE=""
APP_IMAGE="$(docker inspect -f '{{.Config.Image}}' "${APP_CONTAINER}" 2>/dev/null || true)"

if command -v keytool >/dev/null 2>&1; then
  KEYTOOL_MODE="host"
elif [[ -n "${APP_IMAGE}" ]] \
     && docker run --rm --entrypoint sh "${APP_IMAGE}" -c 'command -v keytool' >/dev/null 2>&1; then
  KEYTOOL_MODE="app-image"
elif docker image inspect "${KEYTOOL_BUILDER_IMAGE}" >/dev/null 2>&1 \
     && docker run --rm --entrypoint sh "${KEYTOOL_BUILDER_IMAGE}" -c 'command -v keytool' >/dev/null 2>&1; then
  KEYTOOL_MODE="builder-image"
fi

if [[ -z "${KEYTOOL_MODE}" ]]; then
  log "[ERROR] 找不到可用的 keytool（宿主没有，app / builder 镜像里也没有）"
  log "        先跑一次镜像构建即可拉取 builder 镜像，再重试本脚本"
  exit 1
fi
log "        keytool 来源：${KEYTOOL_MODE}"

rm -f "${P12_FILE}"

# ---------------------------------------------------------------------------
# 函数：run_keytool
# 功能：用探测到的 keytool 执行一次命令。host 模式直接调用；容器模式把
#       ${CERT_DIR} 挂到 /certs 并以 root 运行 —— 否则 app 镜像的非 root
#       USER（s2s）无法往宿主目录写文件
# 参数：$* — 传给 keytool 的参数（容器模式下路径用 /certs/...）
# 返回：keytool 的退出码
# ---------------------------------------------------------------------------
run_keytool() {
  case "${KEYTOOL_MODE}" in
    host)          keytool "$@" ;;
    app-image)     docker run --rm --user 0 -v "${CERT_DIR}:/certs" --entrypoint keytool "${APP_IMAGE}" "$@" ;;
    builder-image) docker run --rm --user 0 -v "${CERT_DIR}:/certs" --entrypoint keytool "${KEYTOOL_BUILDER_IMAGE}" "$@" ;;
  esac
}

run_keytool -importcert -noprompt -alias mysql-ca \
  -file /certs/ca.pem \
  -keystore /certs/mysql-ca.p12 \
  -storetype PKCS12 \
  -storepass "${TRUSTSTORE_PASSWORD}"

# --- 3. 校验并收尾 ------------------------------------------------------------
log "[3/3] 校验信任库"

if [[ ! -s "${P12_FILE}" ]]; then
  log "[ERROR] ${P12_FILE} 未生成"
  exit 1
fi

# 期望：含 1 个 trustedCertEntry（条目类型若是 PrivateKeyEntry 说明拿错了文件）
run_keytool -list -keystore /certs/mysql-ca.p12 -storetype PKCS12 \
  -storepass "${TRUSTSTORE_PASSWORD}" | sed 's/^/        /'

# 644 而非 600：app 容器以非 root 读取；内含只有公开 CA 证书
chmod 644 "${P12_FILE}"

log "[DONE] 信任库就绪：${P12_FILE}"
log "       sha256：$(sha256sum "${P12_FILE}" | cut -d' ' -f1)"
log "       MYSQL_SSL_MODE=${MYSQL_SSL_MODE}"
log ""
log "下一步（改了 .env 或本文件后）："
log "  cd deploy && S2S_ENV=${ENV_NAME} APP_VERSION=<tag> docker compose \\"
log "    -f docker-compose.yml -f compose/docker-compose.${ENV_NAME}.yml \\"
log "    --env-file env/.env.${ENV_NAME} up -d --no-deps app"
log ""
log "回滚为「只加密不校验」：把 ${ENV_FILE} 的 MYSQL_SSL_MODE 改成 REQUIRED 后重启 app"
