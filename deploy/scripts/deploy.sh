#!/usr/bin/env bash
# ============================================================================
# S2S 一键发版脚本（多环境）
# ----------------------------------------------------------------------------
# 依据：《部署架构设计文档》§9 发版与回滚流程、§14.2 环境切换
#
# 功能：拉取代码 → Maven 构建 → 构建应用镜像 → 门禁自查 → 备份数据库 → 滚动重启 app → 健康校验
# 执行时机：发版时在目标机器上执行
#
# 用法：
#   sudo bash deploy/scripts/deploy.sh prod        # 发版到 prod
#   sudo bash deploy/scripts/deploy.sh staging     # 发版到 staging
#   bash deploy/scripts/deploy.sh dev              # dev 免 root
#   sudo bash deploy/scripts/deploy.sh prod --skip-pull   # 跳过 git pull（已手动切分支时）
#   sudo GATE_MANUAL_CONFIRMED="G5,G7" bash deploy/scripts/deploy.sh prod
#                                                  # 声明人工确认项已验证（见 gate-check.sh）
#   sudo bash deploy/scripts/deploy.sh prod --gate-allow-skip="ECS 无公网出口，G11 无法拉取镜像校验 digest"
#                                                  # 门禁存在 SKIP 时带理由放行（理由必填，写入发版日志）
#   环境名省略时读取 deploy/.current-env（由 env-up.sh 写入）
#
# ⚠ 本脚本只重启 app 单个服务（--no-deps），不动 mysql / redis / caddy。
#   首次启动或环境切换请用 env-up.sh，它才负责完整编排与环境互斥校验。
#
# ⚠ 门禁是硬卡点，不是提示。gate-check.sh 退出码 1（有 FAIL）与 2（有 SKIP，
#   即存在未能判定的项）都会中止发版。原实现只在末尾 echo 一句「建议执行门禁自检」
#   而从不读退出码，等于门禁形同不存在 —— 判据写得再严，没有调用方消费就不是卡点。
#
# 退出码：0 成功 / 1 前置校验失败、门禁未通过或任一发版步骤失败
# ============================================================================

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
BASE_FILE="${DEPLOY_DIR}/docker-compose.yml"
STATE_FILE="${DEPLOY_DIR}/.current-env"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

SKIP_PULL=0
GATE_ALLOW_SKIP=0
GATE_ALLOW_SKIP_REASON=""

# ---------------------------------------------------------------------------
# 函数：die
# 功能：打印错误信息到 stderr 并以退出码 1 终止脚本
# 参数：$* — 错误描述文本
# 返回：不返回（进程退出）
# ---------------------------------------------------------------------------
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 函数：resolve_env
# 功能：确定本次发版的目标环境。优先取位置参数，缺省则读 .current-env 状态文件
# 参数：$1 — 可选的环境名（dev/staging/prod）
# 返回：向 stdout 输出合法环境名；无法确定或非法时退出 1
# 说明：与 env-up.sh / gate-check.sh / backup-mysql.sh 保持完全一致的解析逻辑，
#       避免「用 A 环境的凭据往 B 环境发版」这类无声事故。
# ---------------------------------------------------------------------------
resolve_env() {
  local candidate="${1:-}"

  if [[ -z "${candidate}" && -f "${STATE_FILE}" ]]; then
    candidate="$(cat "${STATE_FILE}" 2>/dev/null || true)"
  fi

  if [[ -z "${candidate}" ]]; then
    echo "[ERROR] 未指定环境，且 ${STATE_FILE} 不存在。" >&2
    echo "        用法：sudo bash deploy/scripts/deploy.sh <dev|staging|prod>" >&2
    exit 1
  fi

  case "${candidate}" in
    dev|staging|prod) echo "${candidate}" ;;
    *) echo "[ERROR] 环境名必须是 dev / staging / prod 之一，收到：${candidate}" >&2; exit 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 函数：parse_args
# 功能：解析命令行参数，分离环境名与本脚本选项
# 参数：$@ — 原始命令行参数
# 返回：无返回值；设置全局 ENV_NAME / SKIP_PULL / GATE_ALLOW_SKIP / GATE_ALLOW_SKIP_REASON
# 说明：--gate-allow-skip 强制要求附带理由（=后面的文本），不接受裸开关形式。
#       裸开关会退化成肌肉记忆——顺手一敲就过，与 `|| true` 无异；而必须现场
#       写一句话说明「为什么这次可以不判定」，会让人重新看一眼 SKIP 的是哪几项。
#       该理由随后写进发版日志，构成事后可追溯的留证（对应 §3.2 四要素的留证方式）。
# ---------------------------------------------------------------------------
parse_args() {
  local positional=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-pull) SKIP_PULL=1; shift ;;
      --gate-allow-skip=*)
        GATE_ALLOW_SKIP_REASON="${1#--gate-allow-skip=}"
        [[ -n "${GATE_ALLOW_SKIP_REASON}" ]] || die "--gate-allow-skip 必须附带理由，例如：
      --gate-allow-skip=\"ECS 无公网出口，G11 无法拉取镜像校验 digest\""
        GATE_ALLOW_SKIP=1
        shift
        ;;
      --gate-allow-skip)
        die "--gate-allow-skip 必须以 = 附带理由，不接受裸开关形式：
      --gate-allow-skip=\"这次为什么可以不判定那几项\"
      理由会写入发版日志。不写理由的放行开关，用两次就变成默认动作了。"
        ;;
      -h|--help)
        sed -n '/^# 用法：/,/^# ⚠/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
        exit 0
        ;;
      -*) die "未知选项：$1" ;;
      *)  positional="$1"; shift ;;
    esac
  done

  ENV_NAME="$(resolve_env "${positional}")"
}

# ---------------------------------------------------------------------------
# 函数：assert_prerequisites
# 功能：校验执行权限、密钥文件存在性与权限、环境是否与当前运行环境一致
# 参数：无（使用全局 ENV_NAME / ENV_FILE）
# 返回：无返回值；任一校验失败即退出 1
# 说明：dev 免 root 且权限校验降级 —— 开发机常见 WSL/NTFS 挂载点无法表达
#       Unix 权限位（stat 恒返回 777），硬拦会让脚本在 dev 上完全不可用。
# ---------------------------------------------------------------------------
assert_prerequisites() {
  if [[ "${ENV_NAME}" != "dev" && "${EUID}" -ne 0 ]]; then
    die "${ENV_NAME} 环境发版需要 root 权限，请用 sudo 执行"
  fi

  [[ -f "${BASE_FILE}" ]]      || die "未找到 base compose：${BASE_FILE}"
  [[ -f "${OVERRIDE_FILE}" ]]  || die "未找到环境 override：${OVERRIDE_FILE}"

  if [[ ! -f "${ENV_FILE}" ]]; then
    die "未找到密钥文件 ${ENV_FILE}
      请执行：
        cp deploy/env/.env.${ENV_NAME}.example ${ENV_FILE}
        chmod 600 ${ENV_FILE}
      然后编辑填入真实值。"
  fi

  local perms
  perms="$(stat -c %a "${ENV_FILE}" 2>/dev/null || echo unknown)"
  if [[ "${perms}" != "600" ]]; then
    if [[ "${ENV_NAME}" == "dev" ]]; then
      echo "[WARN] ${ENV_FILE} 权限为 ${perms}（期望 600）。dev 环境不阻断。"
    else
      die "${ENV_FILE} 权限为 ${perms}，必须是 600。请执行：chmod 600 ${ENV_FILE}"
    fi
  fi

  # 三环境共用容器名与命名卷，若当前跑的是别的环境，本次「滚动重启 app」
  # 会把新 app 接到上一套环境的数据库上 —— 必须硬拦。
  if [[ -f "${STATE_FILE}" ]]; then
    local current
    current="$(cat "${STATE_FILE}" 2>/dev/null || true)"
    if [[ -n "${current}" && "${current}" != "${ENV_NAME}" ]]; then
      die "当前运行的是 ${current} 环境，不能向 ${ENV_NAME} 发版。
      三环境共用同一批容器与命名卷（见《部署架构设计文档》§14.2）。
      请先切换环境：
        bash deploy/scripts/env-up.sh ${current} --down
        bash deploy/scripts/env-up.sh ${ENV_NAME}"
    fi
  fi

  # 数据面未起时不存在「滚动重启 app」的语义，应走完整编排
  if ! docker ps --format '{{.Names}}' | grep -q '^s2s-mysql$'; then
    die "s2s-mysql 未在运行，本脚本只做 app 滚动重启。
      首次启动请执行：bash deploy/scripts/env-up.sh ${ENV_NAME}"
  fi
}

# ---------------------------------------------------------------------------
# 函数：resolve_log_file
# 功能：确定发版日志路径，/var/log 不可写时回退到系统临时目录
# 参数：无（使用全局 ENV_NAME / TIMESTAMP）
# 返回：向 stdout 输出日志文件绝对路径
# ---------------------------------------------------------------------------
resolve_log_file() {
  local name="s2s-deploy-${ENV_NAME}-${TIMESTAMP}.log"
  if [[ -w /var/log ]]; then
    echo "/var/log/${name}"
  else
    echo "${TMPDIR:-/tmp}/${name}"
  fi
}

# ---------------------------------------------------------------------------
# 函数：log
# 功能：带时间戳输出到终端并追加写入发版日志
# 参数：$* — 日志正文
# 返回：无
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

# ---------------------------------------------------------------------------
# 函数：check_app_health
# 功能：校验应用健康端点是否返回 status:UP
# 参数：无
# 返回：0 健康 / 1 不健康
# 说明：必须用 docker exec 而非宿主机 curl localhost:8080 —— staging / prod
#       的 app 服务【没有】ports 映射（门禁 G1 强制），宿主机上那个端口根本
#       不存在，用 curl 判定会在正常情况下也报失败。
# ---------------------------------------------------------------------------
check_app_health() {
  docker exec s2s-app \
    curl -sf http://localhost:8080/actuator/health 2>/dev/null \
    | grep -q '"status":"UP"'
}

# ---------------------------------------------------------------------------
# 函数：run_gate_check
# 功能：执行部署面安全门禁自查，按 gate-check.sh 的退出码决定是否继续发版
# 参数：无（使用全局 ENV_NAME / DEPLOY_DIR / GATE_ALLOW_SKIP）
# 返回：无返回值；门禁未通过时以退出码 1 终止发版
# 说明：gate-check.sh 是四态门禁，退出码三档，此处必须逐档处置，
#       【不可】写成 `if bash gate-check.sh; then` —— 那样只能分辨 0 与非 0，
#       会把「有 FAIL」和「有 SKIP」两种性质不同的结果混为一谈，
#       诊断信息全部丢失（见《部署架构设计文档》§14.5）。
#         0 → 全部应判定项均已判定合格，放行
#         1 → 存在 FAIL，判据被判定为不合格，硬拦
#         2 → 存在 SKIP，即有判据未能判定，结论是「不知道」。默认同样硬拦：
#             把「没查过」当作「可以发」正是失效门禁的成因。确有正当原因时
#             用 --gate-allow-skip="理由" 显式放行，理由入日志。
# ---------------------------------------------------------------------------
run_gate_check() {
  local gate_script="${DEPLOY_DIR}/scripts/gate-check.sh"

  if [[ ! -f "${gate_script}" ]]; then
    # 门禁脚本本身缺失必须硬拦，不能降级为警告后继续。
    # 「门禁文件不在 → 跳过门禁 → 发版成功」是本项目反复出现的那类假阴性
    # 在流程层的翻版：待判对象缺失被当成了判定通过。
    die "未找到门禁脚本 ${gate_script}，无法执行发版前自查。
      门禁缺失不等于门禁通过，发版中止。"
  fi

  # ⚠ 这三行的写法有两个坑，都实测踩过，改动前务必读完：
  #   坑一：本脚本开头是 set -euo pipefail。直接写 `bash gate-check.sh | tee`，
  #     门禁返回 1 或 2 时 pipefail 让整条管道非 0，-e 随即终止脚本，
  #     后面的 case 分档一次都跑不到 —— 用户只看到脚本无声退出，
  #     拿不到「是 FAIL 还是 SKIP」「该怎么办」这些唯一有用的信息。
  #   坑二：为规避坑一而写成 `| tee ... || true` 会让门禁彻底失效。
  #     `|| true` 一旦执行，PIPESTATUS 就被 true 的结果覆盖成 (0)，
  #     gate_rc 恒为 0，所有 FAIL/SKIP 都被判成通过。此坑已实测复现：
  #     替身门禁分别返回 0/1/2，四种情况全部打印「门禁全部通过」并继续发版。
  #   故只能临时关闭 pipefail：关闭后管道退出码取末位命令（tee，恒 0），
  #   -e 不触发，而 PIPESTATUS[0] 仍保留门禁脚本的真实退出码。
  local gate_rc=0
  set +o pipefail
  bash "${gate_script}" "${ENV_NAME}" 2>&1 | tee -a "${LOG_FILE}"
  # 取 PIPESTATUS[0] 而非 $?：管道尾是 tee，$? 是 tee 的退出码、恒为 0。
  gate_rc="${PIPESTATUS[0]}"
  set -o pipefail

  case "${gate_rc}" in
    0)
      log "[OK] 门禁全部通过（无 FAIL、无 SKIP）"
      ;;
    2)
      if [[ "${GATE_ALLOW_SKIP}" -eq 1 ]]; then
        log "[WARN] 门禁存在 SKIP（未能判定项），已按 --gate-allow-skip 放行"
        log "       放行理由：${GATE_ALLOW_SKIP_REASON}"
        log "       ⚠ 上方 SKIP 清单中的判据本次【未被验证】，其风险由本次放行承担"
      else
        log "[FAIL] 门禁存在 SKIP：有判据未能判定，结论是「不知道」，不是「合格」"
        die "发版中止。请按上方 SKIP 清单补齐前置条件后重跑，或：
      - 人工确认项（G5/G7）验证后声明：
          sudo GATE_MANUAL_CONFIRMED=\"G5,G7\" bash deploy/scripts/deploy.sh ${ENV_NAME}
      - 确有正当原因无法判定时，带理由显式放行（理由写入发版日志）：
          sudo bash deploy/scripts/deploy.sh ${ENV_NAME} \\
            --gate-allow-skip=\"这次为什么可以不判定那几项\""
      fi
      ;;
    *)
      log "[FAIL] 门禁存在 FAIL 项（退出码 ${gate_rc}）"
      die "发版中止。请修复上方 [FAIL] 项后重跑。
      FAIL 表示判据已执行且结果不合格，【没有】放行开关 ——
      --gate-allow-skip 只对 SKIP（未能判定）生效，不能用来绕过 FAIL。"
      ;;
  esac
}

parse_args "$@"

OVERRIDE_FILE="${DEPLOY_DIR}/compose/docker-compose.${ENV_NAME}.yml"
ENV_FILE="${DEPLOY_DIR}/env/.env.${ENV_NAME}"
LOG_FILE="$(resolve_log_file)"

echo "=========================================="
echo "  S2S 发版脚本 v2.0"
echo "  环境：${ENV_NAME}"
echo "  时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

assert_prerequisites

# S2S_ENV 必须 export：base compose 用它插值 env_file 与 Caddyfile 路径。
# 漏掉它会静默落到默认 prod 分支，构建出的实例挂着 prod 的密钥文件。
export S2S_ENV="${ENV_NAME}"
export APP_VERSION="${TIMESTAMP}"

COMPOSE_ARGS=(
  -f "${BASE_FILE}"
  -f "${OVERRIDE_FILE}"
  --env-file "${ENV_FILE}"
)

# --- 步骤 1：拉取最新代码 ----------------------------------------------------
if [[ "${SKIP_PULL}" -eq 1 ]]; then
  log "[1/6] 跳过 git pull（--skip-pull）"
else
  log "[1/6] 拉取最新代码"
  cd "${PROJECT_DIR}"
  git pull origin main
fi

# --- 步骤 2：Maven 构建 -------------------------------------------------------
log "[2/6] Maven 构建应用"
cd "${PROJECT_DIR}"
mvn -DskipTests clean package -B -q
log "      构建完成"

# --- 步骤 3：构建 Docker 镜像 -------------------------------------------------
log "[3/6] 构建 Docker 镜像"
cd "${DEPLOY_DIR}"
docker compose "${COMPOSE_ARGS[@]}" build app
log "      镜像构建完成：s2s-app:${APP_VERSION}"

# --- 步骤 4：门禁自查（硬卡点）------------------------------------------------
# 位置的选择是刻意的：必须在镜像已构建之后、在备份与重启之前。
#   放在镜像构建【前】：G2 镜像层检查无从判定刚构建出的那个 tag（APP_VERSION
#     此时还没有对应镜像），只能 SKIP，等于放过了「新镜像里打进了 .env」这一类问题
#     —— 而这恰恰是本次发版新引入的风险。
#   放在滚动重启【后】：门禁再怎么 FAIL 也拦不住了，新版本已经在线上跑着，
#     门禁退化为「事后告知」。备份也已经做过，白花 2核2G 上宝贵的 IO。
# 此处 export 的 APP_VERSION 会被 gate-check.sh 的 G2 段读取，用于精确定位
# 本次构建的镜像 tag（deploy.sh 产出的 tag 是时间戳，从不生成 latest）。
log "[4/6] 部署面安全门禁自查"
run_gate_check

# --- 步骤 5：备份数据库（发版前快照）------------------------------------------
# dev 数据可随时重建，备份纯属浪费 2核2G 上宝贵的 IO 与磁盘。
if [[ "${ENV_NAME}" == "dev" ]]; then
  log "[5/6] 跳过数据库备份（dev 环境）"
else
  log "[5/6] 备份数据库（发版前快照）"
  bash "${DEPLOY_DIR}/scripts/backup-mysql.sh" "${ENV_NAME}"
  log "      数据库备份完成"
fi

# --- 步骤 6：滚动重启 app -----------------------------------------------------
log "[6/6] 重启应用服务"
cd "${DEPLOY_DIR}"
# --wait 放在 service 名之前：把 flag 写在位置参数之后属于易碎写法，
# 不同 Compose 版本行为不保证一致。
# --wait 会阻塞直到 healthcheck 转 healthy（或超时），使脚本能真正感知启动成败。
# --no-deps 保证只重建 app，不波及 mysql / redis（重启数据库不属于发版动作）。
docker compose "${COMPOSE_ARGS[@]}" up -d --no-deps --wait app
log "      应用重启完成"

# --- 验证 --------------------------------------------------------------------
log "[+] 验证应用健康状态"
if check_app_health; then
  log "[OK] 应用健康检查通过（status: UP）"
else
  log "[WARN] 健康检查未返回 UP，请人工确认"
  log "      命令：docker exec s2s-app curl -s http://localhost:8080/actuator/health"
  log "      日志：docker compose -f ${BASE_FILE} -f ${OVERRIDE_FILE} logs app --tail 50"
fi

echo
echo "=========================================="
echo "  ${ENV_NAME} 环境发版完成"
echo "  版本：${APP_VERSION}"
echo "  日志：${LOG_FILE}"
echo "=========================================="
if [[ "${ENV_NAME}" != "dev" ]]; then
  # 门禁已在步骤 4 作为硬卡点执行过（未通过则脚本已中止，走不到这里），
  # 故此处不再写「建议执行门禁自检」—— 那句提示是旧版遗留，
  # 它把一个卡点描述成了可选动作，看的人自然不会当回事。
  echo "本次发版已通过门禁自查（详见日志 ${LOG_FILE}）。"
  if [[ "${GATE_ALLOW_SKIP}" -eq 1 ]]; then
    echo "⚠ 注意：本次带 --gate-allow-skip 放行，存在未被验证的判据。"
    echo "  放行理由：${GATE_ALLOW_SKIP_REASON}"
    echo "  建议尽快补齐前置条件后重跑：bash deploy/scripts/gate-check.sh ${ENV_NAME}"
  fi
  echo
  echo "回滚提示："
  echo "  1. 回滚到上一个镜像 tag（镜像仍在本机时最快）："
  echo "     APP_VERSION=<上一个时间戳> S2S_ENV=${ENV_NAME} docker compose \\"
  echo "       -f ${BASE_FILE} -f ${OVERRIDE_FILE} \\"
  echo "       --env-file ${ENV_FILE} up -d --no-deps app"
  echo "     可用 tag 列表：docker images s2s-app --format '{{.Tag}}'"
  echo "  2. 若数据结构已变更且需回滚数据，到阿里云控制台回滚系统盘快照"
  echo "     （快照名称：s2s-pre-rollback-YYYYMMDD）"
  echo "=========================================="
fi
