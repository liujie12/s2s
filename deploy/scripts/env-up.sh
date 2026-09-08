#!/usr/bin/env bash
# ============================================================================
# S2S 多环境统一启动入口
# ----------------------------------------------------------------------------
# 依据：《部署架构设计文档》§14.2 环境切换、§14.3 三环境差异矩阵
#
# 用途：三套环境唯一的启动入口。它把「base + override + env-file + S2S_ENV」
#       这四件必须严格配套的东西封在一处 —— 手写 docker compose -f ... 命令
#       只要漏掉任意一项（尤其是 S2S_ENV），就会起出一套配置错配的实例：
#       挂着 dev 的 Caddyfile、读着 prod 的密钥，且不会报任何错。
#
# 用法：
#   bash deploy/scripts/env-up.sh dev                  # 启动 dev
#   bash deploy/scripts/env-up.sh staging              # 启动 staging
#   bash deploy/scripts/env-up.sh prod                 # 启动 prod
#   bash deploy/scripts/env-up.sh dev --config-only    # 只做语法校验，不启动
#   bash deploy/scripts/env-up.sh dev --down           # 停止并移除容器（保留卷）
#   bash deploy/scripts/env-up.sh dev --profile tls    # dev 额外拉起 Caddy
#   bash deploy/scripts/env-up.sh prod -- --no-build   # -- 之后的参数原样透传
#
# ⚠ 同一宿主机上三环境【互斥运行】。这是 2核2G 单机 + Profile 切换方案的
#   已知代价：容器名与命名卷都不带环境后缀，起 staging 会直接复用 dev 留下的
#   MySQL 数据卷。本脚本因此在切换环境时强制要求先 --down，见 assert_no_other_env。
#
# 退出码：0 成功 / 1 前置校验失败或 compose 执行失败
# ============================================================================

set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_FILE="${DEPLOY_DIR}/docker-compose.yml"
STATE_FILE="${DEPLOY_DIR}/.current-env"

ENV_NAME=""
CONFIG_ONLY=0
DO_DOWN=0
EXTRA_ARGS=()
COMPOSE_PROFILES=""

# ---------------------------------------------------------------------------
# 函数：die
# 功能：打印错误信息到 stderr 并以退出码 1 终止脚本
# 参数：$* — 错误描述文本
# 返回：不返回（进程退出）
# ---------------------------------------------------------------------------
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 函数：usage
# 功能：打印用法说明（取自本文件头部注释块）
# 参数：无
# 返回：无
# ---------------------------------------------------------------------------
usage() {
  sed -n '/^# 用法：/,/^# ⚠/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

# ---------------------------------------------------------------------------
# 函数：parse_args
# 功能：解析命令行参数：第一个位置参数为环境名，其余为本脚本选项或透传选项
# 参数：$@ — 原始命令行参数
# 返回：无返回值；设置 ENV_NAME / CONFIG_ONLY / DO_DOWN / EXTRA_ARGS / COMPOSE_PROFILES
# 说明：--profile 必须在此单独拦截，不能混进 EXTRA_ARGS 透传。理由：
#       --profile 是 docker compose 的【全局 flag】，只能出现在子命令之前
#       （docker compose --profile tls up），而 EXTRA_ARGS 是拼在子命令之后的
#       （docker compose up -d --wait --profile tls），后者会直接报
#       "unknown flag: --profile" 而失败。故转译为 COMPOSE_PROFILES 环境变量，
#       它对 config / up / down 所有子命令一致生效，无需关心参数位置。
# ---------------------------------------------------------------------------
parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 1; }

  ENV_NAME="$1"
  shift

  case "${ENV_NAME}" in
    dev|staging|prod) ;;
    -h|--help) usage; exit 0 ;;
    *) die "环境名必须是 dev / staging / prod 之一，收到：${ENV_NAME}" ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config-only) CONFIG_ONLY=1; shift ;;
      --down)        DO_DOWN=1;     shift ;;
      # --profile <name> 与 --profile=<name> 两种写法都收，统一并入 COMPOSE_PROFILES
      --profile)
        [[ $# -ge 2 ]] || die "--profile 后必须跟 profile 名，如：--profile tls"
        COMPOSE_PROFILES="${COMPOSE_PROFILES:+${COMPOSE_PROFILES},}$2"
        shift 2 ;;
      --profile=*)
        COMPOSE_PROFILES="${COMPOSE_PROFILES:+${COMPOSE_PROFILES},}${1#--profile=}"
        shift ;;
      # -- 之后的所有参数原样透传给 docker compose，不再解析
      --)            shift; EXTRA_ARGS+=("$@"); break ;;
      *)             EXTRA_ARGS+=("$1"); shift ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 函数：assert_prerequisites
# 功能：校验 override 文件、密钥文件存在，且密钥文件权限为 600
# 参数：$1 — 环境名（dev/staging/prod）
# 返回：无返回值；任一校验失败即退出 1
# 说明：权限校验对 dev 降级为提示。开发机常见 WSL/NTFS 挂载点无法表达
#       Unix 权限位（stat 恒返回 777），在 dev 上硬拦会让脚本完全不可用。
# ---------------------------------------------------------------------------
assert_prerequisites() {
  local env_name="$1"
  local override_file="${DEPLOY_DIR}/compose/docker-compose.${env_name}.yml"
  local env_file="${DEPLOY_DIR}/env/.env.${env_name}"

  [[ -f "${BASE_FILE}" ]]     || die "未找到 base compose：${BASE_FILE}"
  [[ -f "${override_file}" ]] || die "未找到环境 override：${override_file}"

  if [[ ! -f "${env_file}" ]]; then
    die "未找到密钥文件 ${env_file}
      请执行：
        cp deploy/env/.env.${env_name}.example ${env_file}
        chmod 600 ${env_file}
      然后编辑填入真实值。"
  fi

  local perms
  perms="$(stat -c %a "${env_file}" 2>/dev/null || echo unknown)"
  if [[ "${perms}" != "600" ]]; then
    if [[ "${env_name}" == "dev" ]]; then
      echo "[WARN] ${env_file} 权限为 ${perms}（期望 600）。dev 环境不阻断。"
    else
      die "${env_file} 权限为 ${perms}，必须是 600。请执行：chmod 600 ${env_file}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 函数：assert_no_other_env
# 功能：若当前已有另一套环境在运行，拒绝启动，提示先 --down
# 参数：$1 — 即将启动的环境名
# 返回：无返回值；检测到环境冲突即退出 1
# 说明：判据取 .current-env 状态文件而非容器标签。容器名与卷名都不含环境
#       后缀，无法从 docker 侧反查「现在跑的是哪套环境」，只能自己记账。
# ---------------------------------------------------------------------------
assert_no_other_env() {
  local target="$1"
  [[ -f "${STATE_FILE}" ]] || return 0

  local current
  current="$(cat "${STATE_FILE}" 2>/dev/null || true)"
  [[ -z "${current}" || "${current}" == "${target}" ]] && return 0

  # 状态文件说别的环境在跑，再确认容器是否真的还活着 ——
  # 若上次是用 docker compose down 直接停的，状态文件会残留
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^s2s-'; then
    return 0
  fi

  die "当前正在运行 ${current} 环境，不能直接启动 ${target}。
      三环境共用同一批容器名与命名卷，直接切换会让 ${target} 读到
      ${current} 遗留的数据库数据（见《部署架构设计文档》§14.2）。
      请先停止：bash deploy/scripts/env-up.sh ${current} --down
      如需连数据一起清除（不可恢复）：
        docker compose -f ${BASE_FILE} down -v"
}

parse_args "$@"
assert_prerequisites "${ENV_NAME}"

# S2S_ENV 必须 export：base compose 用它插值 env_file 与 Caddyfile 路径
export S2S_ENV="${ENV_NAME}"

# COMPOSE_PROFILES 仅在用户显式传了 --profile 时才 export。
# 不能无条件 export 空值：空字符串会被 compose 当作「显式指定了空 profile 集」，
# 反而干扰默认行为。
if [[ -n "${COMPOSE_PROFILES}" ]]; then
  export COMPOSE_PROFILES
  echo "[INFO] 已激活 compose profile：${COMPOSE_PROFILES}"
fi

COMPOSE_ARGS=(
  -f "${BASE_FILE}"
  -f "${DEPLOY_DIR}/compose/docker-compose.${ENV_NAME}.yml"
  --env-file "${DEPLOY_DIR}/env/.env.${ENV_NAME}"
)

echo "=========================================="
echo "  S2S 环境编排：${ENV_NAME}"
echo "=========================================="

# --- 分支一：仅语法校验 ------------------------------------------------------
if [[ "${CONFIG_ONLY}" -eq 1 ]]; then
  echo "[*] 校验 compose 配置（不启动任何容器）"
  # config -q 只验语法与插值，不输出展开结果
  docker compose "${COMPOSE_ARGS[@]}" config -q || die "compose 配置校验失败"
  echo "[OK] ${ENV_NAME} 环境配置校验通过"
  exit 0
fi

# --- 分支二：停止环境 --------------------------------------------------------
if [[ "${DO_DOWN}" -eq 1 ]]; then
  echo "[*] 停止 ${ENV_NAME} 环境（保留数据卷）"
  docker compose "${COMPOSE_ARGS[@]}" down "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
    || die "停止失败"
  rm -f "${STATE_FILE}"
  echo "[OK] ${ENV_NAME} 已停止。数据卷保留，下次启动同环境将复用。"
  echo "     如需彻底清除数据：docker compose -f ${BASE_FILE} down -v"
  exit 0
fi

# --- 分支三：启动环境 --------------------------------------------------------
assert_no_other_env "${ENV_NAME}"

echo "[1/3] 校验 compose 配置"
docker compose "${COMPOSE_ARGS[@]}" config -q || die "compose 配置校验失败"

echo "[2/3] 校验镜像基线"
# 非阻塞：台账首次使用时全是 PENDING，不应拦住启动
bash "${DEPLOY_DIR}/scripts/image-baseline.sh" --verify || \
  echo "[WARN] 镜像基线校验未完全通过，继续启动（详见上方输出）"

echo "[3/3] 启动 ${ENV_NAME} 环境"
# --wait 阻塞至 healthcheck 转 healthy，让脚本能真正感知启动成败，
# 而不是「up 返回 0 但容器随后崩了」
docker compose "${COMPOSE_ARGS[@]}" up -d --wait \
  "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" || die "启动失败，请查看：docker compose logs"

echo "${ENV_NAME}" > "${STATE_FILE}"

echo ""
echo "=========================================="
echo "  ${ENV_NAME} 环境已就绪"
echo "=========================================="
docker compose "${COMPOSE_ARGS[@]}" ps
echo ""
case "${ENV_NAME}" in
  dev)
    echo "访问：http://localhost:8080"
    echo "数据面（仅 127.0.0.1）：MySQL 3306 / Redis 6379"
    echo "验证 TLS 链路（可选）：bash $0 dev --profile tls"
    ;;
  staging)
    echo "访问：https://localhost:8443（internal 自签证书，浏览器会告警）"
    echo "数据面无端口映射，如需连库：docker exec -it s2s-mysql mysql -u root -p"
    ;;
  prod)
    echo "访问：https://\${SITE_DOMAIN}/（ACME 证书，首次签发需数十秒）"
    # 门禁已由 deploy.sh 步骤 4 强制执行（FAIL 与 SKIP 均中止发版），
    # 故这里不再说「发版前请执行」——那会让人误以为是需要自己记着做的可选步骤。
    # 此处提示的用途只有一个：环境刚起、还没到发版时，先看一眼当前门禁状态。
    echo "查看当前门禁状态（发版时 deploy.sh 会自动强制执行）："
    echo "  bash deploy/scripts/gate-check.sh prod"
    echo "  退出码 0=全部通过 / 1=有 FAIL / 2=有 SKIP（存在未能判定项，同样阻塞发版）"
    ;;
esac
