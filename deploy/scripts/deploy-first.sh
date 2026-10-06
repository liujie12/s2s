#!/usr/bin/env bash
# ============================================================================
# S2S 首次部署脚本（一键拉起后端服务）
# ----------------------------------------------------------------------------
# 用途：在已初始化的服务器上（已运行 server-init-centos.sh），一键完成：
#         1. git clone 代码到 /opt/s2s
#         2. 自动生成全部密钥（AEAD/HMAC/JWT/MySQL/Redis）
#         3. 填写 .env.prod（OSS 等外部凭证需你手动补充）
#         4. 刷新镜像基线
#         5. 启动 prod 环境
#         6. 健康检查 + 接口冒烟
#
# 用法：
#   sudo bash deploy-first.sh <git仓库地址> <域名>
#
#   示例：
#   sudo bash deploy-first.sh \
#     https://github.com/your-org/s2s.git \
#     api.example.com
#
# 前置条件：
#   - 已运行 server-init-centos.sh（Docker / JDK / Maven / Git 就绪）
#   - 服务器能联网拉取 git 仓库和 Docker 镜像
#   - 域名 A 记录已指向本服务器公网 IP（如果要 HTTPS）
#
# 注意：
#   - OSS 等第三方凭证不会自动生成，脚本会留出占位，你需要手动编辑
#     /opt/s2s/deploy/env/.env.prod 后重启服务
#   - 未备案域名用 --no-https 模式（Caddy 用自签证书）
# ============================================================================

set -euo pipefail

# ---- 颜色与工具函数 -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BLUE}========== $* ==========${NC}\n"; }

# ---- 参数解析 -----------------------------------------------------------------
usage() {
  sed -n '/^# 用法：/,/^#$/p' "$0" | sed 's/^# \?//'
}

GIT_REPO=""
DOMAIN=""
NO_HTTPS=0
DEPLOY_DIR="/opt/s2s"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-https)  NO_HTTPS=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      -*)          error "未知选项：$1" ;;
      *)
        if [[ -z "${GIT_REPO}" ]]; then
          GIT_REPO="$1"
        elif [[ -z "${DOMAIN}" ]]; then
          DOMAIN="$1"
        else
          error "多余的位置参数：$1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "${GIT_REPO}" ]] || { usage; error "缺少 git 仓库地址"; }
  [[ -n "${DOMAIN}" ]] || { usage; error "缺少域名"; }
}

parse_args "$@"

# ---- 必须 root ---------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  error "请用 root 或 sudo 执行本脚本"
fi

# ---- 前置检查 -----------------------------------------------------------------
step "0. 前置检查"

for cmd in docker git openssl java mvn; do
  command -v "${cmd}" >/dev/null 2>&1 \
    || error "缺少命令：${cmd}。请先运行 server-init-centos.sh"
done

# docker compose 插件
docker compose version >/dev/null 2>&1 \
  || error "缺少 docker compose 插件。请先运行 server-init-centos.sh"

info "全部前置检查通过"
info "  Git 仓库：${GIT_REPO}"
info "  域名：    ${DOMAIN}"
info "  HTTPS：   $([[ ${NO_HTTPS} -eq 1 ]] && echo '否（自签/降级）' || echo '是（ACME）')"
info "  部署目录：${DEPLOY_DIR}"

# ============================================================================
# 第 1 步：拉取代码
# ============================================================================
step "1. 拉取代码"

if [[ -d "${DEPLOY_DIR}/.git" ]]; then
  warn "${DEPLOY_DIR} 已经是 git 仓库，跳过 clone，执行 git pull"
  cd "${DEPLOY_DIR}"
  git pull origin main || git pull origin master || warn "git pull 失败，可能是默认分支名不同"
else
  mkdir -p "$(dirname "${DEPLOY_DIR}")"
  git clone "${GIT_REPO}" "${DEPLOY_DIR}"
  cd "${DEPLOY_DIR}"
  info "代码已拉取到 ${DEPLOY_DIR}"
fi

# 切到 main（如果在其他分支）
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
info "当前分支：${current_branch}"

# ============================================================================
# 第 2 步：生成密钥与配置
# ============================================================================
step "2. 生成密钥与配置"

ENV_FILE="${DEPLOY_DIR}/deploy/env/.env.prod"
ENV_TEMPLATE="${DEPLOY_DIR}/deploy/env/.env.prod.example"

if [[ -f "${ENV_FILE}" ]]; then
  warn "${ENV_FILE} 已存在，跳过密钥生成"
else
  [[ -f "${ENV_TEMPLATE}" ]] || error "找不到模板文件：${ENV_TEMPLATE}"

  cp "${ENV_TEMPLATE}" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"

  # 生成各密钥
  MYSQL_ROOT_PW="$(openssl rand -base64 18 | tr -d '\n/+=' | head -c 24)"
  MYSQL_USER_PW="$(openssl rand -base64 18 | tr -d '\n/+=' | head -c 24)"
  REDIS_PW="$(openssl rand -base64 18 | tr -d '\n/+=' | head -c 24)"
  AEAD_KEY="$(openssl rand -base64 32 | tr -d '\n')"
  HMAC_KEY="$(openssl rand -base64 32 | tr -d '\n')"
  JWT_KEY="$(openssl rand -hex 32 | tr -d '\n')"

  # 写入 .env.prod
  sed -i "s|^SITE_DOMAIN=.*|SITE_DOMAIN=${DOMAIN}|" "${ENV_FILE}"
  sed -i "s|^ACME_EMAIL=.*|ACME_EMAIL=admin@${DOMAIN}|" "${ENV_FILE}"
  sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PW}|" "${ENV_FILE}"
  sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=${MYSQL_USER_PW}|" "${ENV_FILE}"
  sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PW}|" "${ENV_FILE}"
  sed -i "s|^AEAD_MASTER_KEYS_JSON=.*|AEAD_MASTER_KEYS_JSON=[{\"id\":\"k1\",\"key\":\"${AEAD_KEY}\"}]|" "${ENV_FILE}"
  sed -i "s|^HMAC_PEPPERS_JSON=.*|HMAC_PEPPERS_JSON=[{\"id\":\"p1\",\"key\":\"${HMAC_KEY}\"}]|" "${ENV_FILE}"
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_KEY}|" "${ENV_FILE}"

  info "密钥已生成并写入 ${ENV_FILE}"
  info "  ⚠ 这些密钥只在此处生成一次，请妥善备份到密码管理器"
  info "  ⚠ 丢失 = 数据无法解密（AEAD）、全部 Token 失效（JWT）"

  # 检查还有哪些占位符没替换（需要手动填的）
  remaining=$(grep -nE 'change_me|example|YOUR_|placeholder' "${ENV_FILE}" || true)
  if [[ -n "${remaining}" ]]; then
    warn "以下变量仍为占位符，需要你手动编辑 ${ENV_FILE} 后重启："
    echo "${remaining}"
    warn "  OSS 相关（OSS_ENDPOINT / OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET / OSS_BUCKET_NAME）"
    warn "  LLM 相关（LLM_API_KEY，Batch3 再用，可以先不管）"
  fi
fi

# ---- 未备案/无 HTTPS 模式 ---------------------------------------------------
if [[ ${NO_HTTPS} -eq 1 ]]; then
  warn "--no-https 模式：改用 staging 的自签证书配置（备案完成后再切 prod）"
  # 用 staging 环境启动（证书自签，不依赖公网 80 端口）
  ENV_NAME="staging"
  ENV_FILE="${DEPLOY_DIR}/deploy/env/.env.staging"
  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${DEPLOY_DIR}/deploy/env/.env.staging.example" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    # 复用上面生成的密钥（直接从 .env.prod 复制过来）
    for var in SITE_DOMAIN ACME_EMAIL MYSQL_ROOT_PASSWORD MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MYSQL_TRACK_DATABASE REDIS_PASSWORD AEAD_MASTER_KEYS_JSON HMAC_PEPPERS_JSON JWT_SECRET OSS_ENDPOINT OSS_ACCESS_KEY_ID OSS_ACCESS_KEY_SECRET OSS_BUCKET_NAME LLM_API_KEY LLM_API_BASE_URL; do
      val="$(grep "^${var}=" "${DEPLOY_DIR}/deploy/env/.env.prod" 2>/dev/null || true)"
      if [[ -n "${val}" ]]; then
        if grep -q "^${var}=" "${ENV_FILE}"; then
          sed -i "s|^${var}=.*|${val}|" "${ENV_FILE}"
        else
          echo "${val}" >> "${ENV_FILE}"
        fi
      fi
    done
  fi
else
  ENV_NAME="prod"
fi

info "目标环境：${ENV_NAME}"

# ============================================================================
# 第 3 步：刷新镜像基线
# ============================================================================
step "3. 刷新镜像基线"

cd "${DEPLOY_DIR}"
if bash deploy/scripts/image-baseline.sh --refresh 2>&1; then
  info "镜像基线刷新完成"
else
  warn "镜像基线刷新失败（可能是网络问题），不影响启动，跳过"
fi

# ============================================================================
# 第 4 步：启动服务
# ============================================================================
step "4. 启动 ${ENV_NAME} 环境"

cd "${DEPLOY_DIR}"
bash deploy/scripts/env-up.sh "${ENV_NAME}"

info "等待服务启动（最多 3 分钟）..."
# 等 MySQL 和 Redis 先 healthy
for i in $(seq 1 60); do
  if docker ps --format '{{.Names}} {{.Status}}' | grep -q 's2s-mysql.*healthy' \
     && docker ps --format '{{.Names}} {{.Status}}' | grep -q 's2s-redis.*healthy'; then
    break
  fi
  sleep 3
  echo -n "."
done
echo

# 等 app 启动
for i in $(seq 1 60); do
  if docker ps --format '{{.Names}} {{.Status}}' | grep -q 's2s-app.*healthy'; then
    break
  fi
  sleep 3
  echo -n "."
done
echo

# 检查最终状态
info "容器状态："
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

if docker ps --format '{{.Names}} {{.Status}}' | grep -q 's2s-app.*healthy'; then
  info "应用启动成功"
else
  error "应用启动失败。请检查日志：docker logs s2s-app --tail 100"
fi

# ============================================================================
# 第 5 步：接口冒烟
# ============================================================================
step "5. 接口冒烟测试"

if [[ "${ENV_NAME}" == "prod" ]]; then
  BASE_URL="https://${DOMAIN}"
else
  BASE_URL="https://${DOMAIN}:8443"  # staging Caddy 绑定 8443
fi

info "测试基址：${BASE_URL}"

# HTTPS 证书检查（自签跳过严格验证）
CURL_OPTS="-s --max-time 10"
if [[ "${ENV_NAME}" == "staging" ]]; then
  CURL_OPTS="${CURL_OPTS} -k"
fi

# 健康检查
if curl ${CURL_OPTS} "${BASE_URL}/actuator/health" | grep -q '"status":"UP"'; then
  info "✅ /actuator/health 正常"
else
  warn "❌ /actuator/health 异常（可能是证书或网络问题）"
fi

# 分类树接口（核心读接口）
if curl ${CURL_OPTS} "${BASE_URL}/api/v1/categories/tree" | grep -q '"code":0'; then
  info "✅ /api/v1/categories/tree 正常"
else
  warn "❌ /api/v1/categories/tree 异常"
fi

# 地图 pins 接口
if curl ${CURL_OPTS} "${BASE_URL}/api/v1/map/pins?category_id=10100&radius=5&lat=30.2741&lng=120.1551" | grep -q '"code":0'; then
  info "✅ /api/v1/map/pins 正常"
else
  warn "❌ /api/v1/map/pins 异常"
fi

# ============================================================================
# 第 6 步：门禁自检（非阻塞，仅出报告）
# ============================================================================
step "6. 门禁自检（首次运行必有 SKIP，属正常）"

cd "${DEPLOY_DIR}"
set +e
bash deploy/scripts/gate-check.sh "${ENV_NAME}"
GATE_RC=$?
set -e

case ${GATE_RC} in
  0) info "门禁全部通过" ;;
  1) warn "门禁存在 FAIL，请检查上方 [FAIL] 项" ;;
  2) warn "门禁存在 SKIP（首次运行正常），补齐前置条件后重跑" ;;
esac

# ============================================================================
# 收尾
# ============================================================================
echo
echo "=========================================="
echo "  部署完成（${ENV_NAME} 环境）"
echo "=========================================="
echo
echo "📌 访问地址："
echo "   ${BASE_URL}"
echo
echo "📁 部署目录："
echo "   ${DEPLOY_DIR}"
echo
echo "🔐 密钥文件（请立即备份到密码管理器）："
echo "   ${ENV_FILE}"
echo "   权限：$(stat -c %a "${ENV_FILE}")"
echo
echo "📝 后续操作："
if [[ ${NO_HTTPS} -eq 1 ]]; then
  echo "   1. 完成 ICP 备案后，切回 prod 环境（正式 HTTPS）："
  echo "      bash deploy/scripts/env-up.sh staging --down"
  echo "      # 编辑 deploy/env/.env.prod 确认真实配置"
  echo "      bash deploy/scripts/env-up.sh prod"
fi
echo "   1. 编辑 ${DEPLOY_DIR}/deploy/env/.env.${ENV_NAME} 填入 OSS 等第三方凭证"
echo "   2. 重启生效：bash deploy/scripts/deploy.sh ${ENV_NAME} --skip-pull"
echo "   3. 日常发版：sudo bash deploy/scripts/deploy.sh ${ENV_NAME}"
echo
echo "🔧 常用命令："
echo "   看日志：     docker logs -f s2s-app"
echo "   看状态：     docker ps"
echo "   跑门禁：     bash deploy/scripts/gate-check.sh ${ENV_NAME}"
echo "   备份数据库： sudo bash deploy/scripts/backup-mysql.sh ${ENV_NAME}"
echo
echo "⚠  安全提醒："
echo "   - 密钥文件权限已设为 600，但请确认 root 以外用户无法读取"
echo "   - 数据库 root 口令和业务口令不同，都请妥善保管"
echo "   - 服务器重启后服务会自动启动（restart: unless-stopped）"
echo
