#!/usr/bin/env bash
# ============================================================================
# S2S 部署面安全门禁自查脚本（多环境）
# ----------------------------------------------------------------------------
# 依据：《部署架构设计文档》§10 部署面安全门禁与验收清单（G1–G10）
#       《部署架构设计文档》§14.5 门禁的环境分级判定
#       《DevSecOps 接入方案》§8（G1–G7 对应七条检查命令）
#       《系统安全设计方案》§10（S2/S4/S10 自检项）
#       《可观测性架构方案》§10.1（G9 日志脱敏）
#
# 功能：每项检查给出 PASS / FAIL / SKIP / N/A 四态判定，
#       FAIL 与 SKIP 均阻塞发版（未检查不等于合格）
# 用法：bash deploy/scripts/gate-check.sh <env>
#       env 省略时取 deploy/.current-env
#
# 四态语义（不可混用，混用即退化为「静默 PASS」）：
#   PASS —— 已执行判定，结果合格
#   FAIL —— 已执行判定，结果不合格
#   SKIP —— 本项应当判定，但本次运行缺少前置条件而未能判定（如 docker 未装、
#           容器未起、域名未配）。它既不是通过也不是不通过，是「不知道」。
#   N/A  —— 本项按环境设计就不适用（如 G7 安全组在本地 dev 无对应物）。
#           与 SKIP 的区别：N/A 不代表缺失判定，故不影响退出码。
#           若把不适用项也计入 SKIP，prod 每次跑必然 SKIP≥1、退出码恒为 2，
#           这条规则第一天就会被 `|| true` 绕过。
#
# 人工确认项（G5 / G7）：脚本无法自动判定。人工验证后须通过环境变量声明，
#   门禁才认账，否则记 SKIP：
#       GATE_MANUAL_CONFIRMED="G5,G7" bash deploy/scripts/gate-check.sh prod
#   原实现无条件记 PASS，等于把「没查」写成「查过且合格」，比 SKIP 更坏。
#
# 环境分级（§14.5）：
#   G1（数据面端口暴露）在 dev 下降级 —— dev 刻意映射 3306/6379 到
#   127.0.0.1 以便本地连库，见 docker-compose.dev.yml。staging/prod 仍强制 FAIL。
#   除 G1 外所有检查项三环境判据完全一致：门禁一旦按环境放水，
#   staging 通过就不再能代表 prod 能过，整套多环境的意义也就没了。
#
# 退出码：0 = 全部判定且通过；1 = 存在 FAIL；2 = 无 FAIL 但存在 SKIP（判定不完整）
# ============================================================================

set -u

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${DEPLOY_DIR}/.current-env"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
NA_COUNT=0
# SKIP 项名单，供汇总处逐条列出 —— 只报数字而不报是哪几项，
# 看的人无从判断「这次跳过的是否恰好是挡住核心风险的那一项」。
SKIP_ITEMS=""

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  [PASS] $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  [FAIL] $1"; }

# ---------------------------------------------------------------------------
# 函数：skip
# 功能：记录一项「应当判定但本次未能判定」的检查，计入 SKIP_COUNT 并阻塞发版
# 参数：$1 — 检查项编号（如 G4）；$2 — 未能判定的原因（须写明缺什么前置条件）
# 返回：无返回值，副作用为递增 SKIP_COUNT 与追加 SKIP_ITEMS
# 说明：SKIP 不是 PASS 的温和版本。凡走到本函数，即表示该项风险状态未知，
#       退出码必须体现这一点，否则「没检查」与「检查通过」在调用方眼里等价。
# ---------------------------------------------------------------------------
skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  SKIP_ITEMS="${SKIP_ITEMS}
    - $1：$2"
  echo "  [SKIP] $2"
}

# ---------------------------------------------------------------------------
# 函数：not_applicable
# 功能：记录一项「按当前环境设计本就不存在」的检查，计入 NA_COUNT，不影响退出码
# 参数：$1 — 检查项编号（如 G7）；$2 — 不适用的原因（须说明该环境为何无此对象）
# 返回：无返回值，副作用为递增 NA_COUNT
# 说明：与 skip 的分界线是「有没有可判定的对象」——
#       dev 本地机没有云安全组，G7 无对象可判，是 N/A；
#       prod 上 docker 没装导致 G4 判不了，对象存在只是够不着，是 SKIP。
#       判据本身在 §14.5 已按环境固化，此处不得用于临时豁免某项检查。
# ---------------------------------------------------------------------------
not_applicable() {
  NA_COUNT=$((NA_COUNT + 1))
  echo "  [N/A ] $2"
}

# ---------------------------------------------------------------------------
# 函数：manual_confirmed
# 功能：判断某项人工确认项是否已由调用方通过 GATE_MANUAL_CONFIRMED 显式声明
# 参数：$1 — 检查项编号（如 G5）
# 返回：已声明返回 0，未声明返回 1
# 说明：环境变量格式为逗号分隔的编号列表，如 GATE_MANUAL_CONFIRMED="G5,G7"。
#       这个声明本身会随 stdout 进入发版留证，事后可追溯是谁在哪一次发版
#       声称做过人工验证 —— 这正是 §3.2 四要素中的「留证方式」。
# ---------------------------------------------------------------------------
manual_confirmed() {
  local item="$1"
  [[ ",${GATE_MANUAL_CONFIRMED:-}," == *",${item},"* ]]
}

# ---------------------------------------------------------------------------
# 函数：resolve_env
# 功能：确定检查目标环境。优先取位置参数，其次取 env-up.sh 的记账文件
# 参数：$1 — 可选的环境名（dev/staging/prod）
# 返回：向 stdout 输出环境名；无法确定或取值非法时退出 1
# ⚠ 本函数在命令替换 $( ) 中被调用，其 exit 1 只能终止子 shell，无法终止主脚本。
#   而本脚本【刻意不用 set -e】—— 门禁必须把 G1~G11 全部跑完再汇总，
#   用了 -e 会在第一个 FAIL 处直接退出、后面的项永远不被检查。
#   因此调用点必须显式 `|| exit 1`，否则非法环境名会让 ENV_NAME 变成空串，
#   后续所有检查基于空环境名执行，结果全部无意义（曾实测到这个缺陷）。
# ---------------------------------------------------------------------------
resolve_env() {
  local candidate="${1:-}"

  if [[ -z "${candidate}" && -f "${STATE_FILE}" ]]; then
    candidate="$(cat "${STATE_FILE}" 2>/dev/null || true)"
  fi

  if [[ -z "${candidate}" ]]; then
    echo "[ERROR] 未指定环境，且 ${STATE_FILE} 不存在。" >&2
    echo "        用法：bash deploy/scripts/gate-check.sh <dev|staging|prod>" >&2
    exit 1
  fi

  case "${candidate}" in
    dev|staging|prod) echo "${candidate}" ;;
    *) echo "[ERROR] 环境名必须是 dev / staging / prod 之一，收到：${candidate}" >&2; exit 1 ;;
  esac
}

ENV_NAME="$(resolve_env "${1:-}")" || exit 1
ENV_FILE="${DEPLOY_DIR}/env/.env.${ENV_NAME}"
OVERRIDE_FILE="${DEPLOY_DIR}/compose/docker-compose.${ENV_NAME}.yml"

echo "=========================================="
echo "  S2S 部署面安全门禁检查"
echo "  目标环境：${ENV_NAME}"
echo "=========================================="
echo ""

# --- G1: Compose 无数据面端口映射 --------------------------------------------
echo "[G1] Compose 无数据面端口映射"
# 用 docker compose config 展开后的规范化输出判定，而不是 grep 原始 yml：
# 原始 yml 里 ports: 那一行不含服务名，grep 无法区分它属于哪个服务。
# 用 awk 替代 python3 以避免依赖问题（ECS 上可能未安装 python3）。
if command -v docker >/dev/null 2>&1; then
  G1_VIOLATION=""
  G1_DECIDED=1   # 判据是否真正执行过。config 失败时置 0，避免走到下方「无违规即 PASS」
  # config 只调一次，后续对同一份文本反复解析，避免每个服务都起一次 docker。
  # 必须带上 override 与 S2S_ENV，否则展开的是「无环境」的半成品配置，
  # 判出来的端口暴露面跟实际跑的那套没有关系。
  COMPOSE_CONFIG=$(S2S_ENV="${ENV_NAME}" docker compose \
    -f "${DEPLOY_DIR}/docker-compose.yml" \
    -f "${OVERRIDE_FILE}" \
    --env-file "${ENV_FILE}" config 2>/dev/null || true)
  if [[ -z "${COMPOSE_CONFIG}" ]]; then
    # ⚠ 此处原本只 fail 而不中断后续分支，G1_VIOLATION 保持空串，
    #   会一路落到下面的 else 再记一次 pass —— 同一项同时 FAIL 和 PASS，
    #   PASS_COUNT 被污染。故用 G1_DECIDED 标记，跳过后续判定。
    G1_DECIDED=0
    fail "docker compose config 执行失败，无法判定端口暴露面（先修 compose 语法）"
  else
    for svc in app mysql redis; do
      # awk 逐服务定位：服务块以 2 空格缩进的键开始，块内 ports: 为 4 空格缩进，
      # published: 出现在 ports 块内即视为该服务对外映射了端口。
      PUB=$(echo "${COMPOSE_CONFIG}" | awk -v svc="${svc}:" '
        /^  [a-zA-Z]/ { current = $1; in_ports = 0 }
        current == svc {
          if ($0 ~ /^    ports:/)          { in_ports = 1; next }
          if ($0 ~ /^    [a-zA-Z]/)        { in_ports = 0 }
          if (in_ports && $0 ~ /published:/) { found = 1 }
        }
        END { print found + 0 }
      ')
      if [[ "${PUB}" != "0" ]]; then
        G1_VIOLATION="${G1_VIOLATION} ${svc}"
      fi
    done
  fi
  if [[ "${G1_DECIDED}" -eq 0 ]]; then
    :   # 已在上方记 FAIL，不再重复判定
  elif [[ -n "${G1_VIOLATION}" ]]; then
    if [[ "${ENV_NAME}" == "dev" ]]; then
      # dev 的映射是刻意设计（绑定 127.0.0.1，见 docker-compose.dev.yml 头部），
      # 不计入 FAIL；但仍打印出来，防止有人把这份 override 抄到 staging。
      # 这里记 PASS 是成立的：判据确实执行了，只是 dev 的判据本身不同（§14.5），
      # 且其合法性由 G1b 硬拦兜底。
      echo "  [INFO] dev 环境刻意映射数据面端口：${G1_VIOLATION}"
      echo "         这些映射必须绑定 127.0.0.1，且【禁止】复制到 staging/prod。"
      pass "dev 环境端口映射符合预期（判据按 §14.5 降级，合法性由 G1b 兜底）"
    else
      fail "数据面服务出现端口映射：${G1_VIOLATION}"
    fi
  else
    pass "app / mysql / redis 均无端口映射，仅 Caddy 对外暴露 80/443"
  fi
else
  skip "G1" "docker 未安装，端口暴露面未判定"
fi

# --- G1b: dev 端口必须绑定 127.0.0.1 -----------------------------------------
# 仅 dev 需要这一项：它是 G1 降级的前提条件。若 dev 把端口绑到 0.0.0.0，
# 开发机在公网/办公网下数据库直接可达，降级判据不再成立。
echo ""
echo "[G1b] dev 端口映射绑定 127.0.0.1"
if [[ "${ENV_NAME}" != "dev" ]]; then
  # 原实现用 if [[ dev ]] 把整段（含标题）包住，staging/prod 下这一项在输出里
  # 完全不出现。读日志的人无从分辨「这项不适用」与「这项被人删了」。
  not_applicable "G1b" "${ENV_NAME} 环境本就不允许任何数据面端口映射（由 G1 硬拦），无映射可校验绑定地址"
elif [[ -z "${COMPOSE_CONFIG:-}" ]]; then
  skip "G1b" "无法获取 compose 展开结果（见 G1），端口绑定地址未判定"
else
  # 判据与 G1 同源：复用已展开的 COMPOSE_CONFIG，逐条比对 host_ip 字段。
  # ⚠ 不能用「黑名单正则」匹配原始 yml 找 0.0.0.0 或省略 host_ip 的写法 ——
  #   那样 - "192.168.1.5:3306:3306" 这类绑到具体外网卡的写法会漏检。
  #   改为白名单：展开后每个 published 端口的 host_ip 必须恰为 127.0.0.1。
  #
  # compose config 展开后，ports 每一项形如（注意 host_ip 行不带 "- " 前缀，
  # "- " 出现在该项的首个键上，通常是 mode:）：
  #     ports:
  #       - mode: ingress
  #         host_ip: 127.0.0.1
  #         target: 3306
  #         published: "3306"
  # 故按 host_ip 出现处记录、published 出现处结算，不能要求 host_ip 带 "- "。
  BAD_BIND=$(echo "${COMPOSE_CONFIG}" | awk '
    /^[[:space:]]*(-[[:space:]]+)?host_ip:[[:space:]]/ { ip = $NF; next }
    /^[[:space:]]*(-[[:space:]]+)?published:[[:space:]]/ {
      port = $NF
      gsub(/"/, "", port)
      if (ip != "127.0.0.1") printf "  published=%s host_ip=%s\n", port, (ip == "" ? "(未设置)" : ip)
      ip = ""
    }
  ')
  if [[ -n "${BAD_BIND}" ]]; then
    fail "存在未绑定 127.0.0.1 的端口映射：
${BAD_BIND}"
  else
    pass "所有端口映射均绑定 127.0.0.1"
  fi
fi

# --- G2: 镜像无 COPY .env ----------------------------------------------------
echo ""
echo "[G2] Dockerfile 中无 COPY .env"
# 排除注释行：Dockerfile 头部的纪律说明里就写着「禁止 COPY .env」，
# 不排除注释会把说明文字本身判成违规。
# ⚠ 与下方镜像段同构的假阴性，必须先判文件是否存在：
#   Dockerfile 不存在时 grep 返回非 0，if 条件不成立 → 直接落到 else 打印 [PASS]，
#   于是「文件不存在」被判成了「文件里没有违规」。原先那个 2>/dev/null 还会把
#   grep 的 "No such file or directory" 一并吞掉，连线索都不留。
#   判据成立的前提是存在可判定对象，对象缺失应当是 SKIP（不知道），不是 PASS。
if [[ ! -f "${DEPLOY_DIR}/Dockerfile" ]]; then
  skip "G2" "未找到 ${DEPLOY_DIR}/Dockerfile，Dockerfile 文本层未检查"
elif grep -nE '^[[:space:]]*COPY[[:space:]].*\.env' "${DEPLOY_DIR}/Dockerfile"; then
  fail "Dockerfile 中包含 COPY .env 指令"
else
  pass "Dockerfile 中无 COPY .env 指令"
fi

# 更严谨的检查：查看已构建镜像的 history
# ⚠ 不能写死 s2s-app:latest —— deploy.sh 构建出的 tag 是时间戳（s2s-app:20260907-1430），
#   从不生成 latest。对不存在的镜像执行 docker history 会返回非 0，
#   grep -q 同样非 0，if 条件不成立 → 直接落到 else 打印 [PASS]，
#   于是这项检查在「镜像根本不存在」时也报通过，是假阴性（曾实测到）。
#   故必须先确认镜像存在，取不到就明确 SKIP。
if command -v docker >/dev/null 2>&1; then
  # 优先用调用方指定的 tag，否则取最近构建的一个 s2s-app 镜像
  # ${APP_VERSION:-} 的 :- 不可省：本脚本用 set -u，直接引用未定义变量会报错退出
  G2_IMAGE="${APP_VERSION:-}"
  G2_IMAGE="${G2_IMAGE:+s2s-app:${G2_IMAGE}}"
  if [[ -z "${G2_IMAGE}" ]]; then
    G2_IMAGE=$(docker images 's2s-app' \
      --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' 2>/dev/null \
      | sort -k2 -r | head -1 | cut -f1)
  fi

  if [[ -z "${G2_IMAGE}" ]] || ! docker image inspect "${G2_IMAGE}" >/dev/null 2>&1; then
    skip "G2" "本机无 s2s-app 镜像，镜像层未检查（如需指定版本：APP_VERSION=<tag> bash $0 ${ENV_NAME}）"
  elif docker history "${G2_IMAGE}" 2>/dev/null | grep -q 'COPY.*\.env'; then
    fail "镜像 ${G2_IMAGE} 的 history 中发现 COPY .env 层"
  else
    pass "镜像 ${G2_IMAGE} 的 history 中无 COPY .env 层"
  fi
else
  skip "G2" "docker 未安装，镜像层未检查"
fi

# --- G3: 密钥文件权限 600 ----------------------------------------------------
echo ""
echo "[G3] 密钥文件权限检查"
if [[ -f "${ENV_FILE}" ]]; then
  ENV_PERMS=$(stat -c %a "${ENV_FILE}" 2>/dev/null || echo unknown)
  if [[ "${ENV_PERMS}" == "600" ]]; then
    pass "${ENV_FILE} 权限为 ${ENV_PERMS}"
  elif [[ "${ENV_NAME}" == "dev" ]]; then
    # ⚠ 原实现在此记 pass "（dev 环境权限检查降级）" —— 那是伪 PASS：
    #   开发机常在 WSL/NTFS 挂载点上，stat -c %a 恒返回 777，
    #   文件系统层面无法表达 Unix 权限位，即【判定从未发生】。
    #   把「判不了」记成「合格」，等于让 dev 的门禁在这一项上永远绿灯。
    #   现改为 SKIP：dev 下退出码变 2，如实反映「这项没查出结论」。
    skip "G3" "dev 权限为 ${ENV_PERMS}，WSL/NTFS 挂载点无法表达 Unix 权限位，权限未判定"
  else
    fail "${ENV_FILE} 权限应为 600，当前为 ${ENV_PERMS}。请执行 chmod 600 ${ENV_FILE}"
  fi
else
  fail "${ENV_FILE} 不存在，请先通过 .env.${ENV_NAME}.example 创建"
fi

# --- G3b: 密钥文件未被 git 跟踪 ----------------------------------------------
echo ""
echo "[G3b] 密钥文件未进入 git 索引"
# 权限对了但文件被 git add 过，密钥照样会随下次 push 泄露到远端仓库，
# 且 history 里删不干净。这一项检查的是比权限更严重的失误。
if command -v git >/dev/null 2>&1 && [[ -d "${DEPLOY_DIR}/../.git" ]]; then
  TRACKED=$(cd "${DEPLOY_DIR}/.." && git ls-files 'deploy/env/.env.*' 2>/dev/null \
    | grep -v '\.example$' || true)
  if [[ -n "${TRACKED}" ]]; then
    fail "以下密钥文件已被 git 跟踪，必须立即 git rm --cached 并轮换密钥：
${TRACKED}"
  else
    pass "无真实密钥文件被 git 跟踪"
  fi
else
  skip "G3b" "非 git 仓库或未安装 git，密钥入库情况未判定"
fi

# --- G4: Redis 无口令被拒 ----------------------------------------------------
echo ""
echo "[G4] Redis 无口令访问被拒"
if ! command -v docker >/dev/null 2>&1; then
  skip "G4" "docker 未安装，Redis 认证未判定"
elif docker ps --format '{{.Names}}' | grep -q 's2s-redis'; then
  REDIS_CHECK=$(docker exec s2s-redis redis-cli -h 127.0.0.1 ping 2>&1 || true)
  if echo "${REDIS_CHECK}" | grep -q 'NOAUTH'; then
    pass "无口令访问被拒（NOAUTH）"
  else
    fail "Redis 无口令也可访问，请检查 requirepass 配置"
  fi
else
  skip "G4" "s2s-redis 容器未运行，Redis 认证未判定"
fi

# --- G5: 删 pepper 后启动失败 ------------------------------------------------
echo ""
echo "[G5] 密钥缺失时快速失败（人工确认项）"
# ⚠ 原实现无条件 pass "（人工确认项）"：脚本只是把手动命令打印出来，
#   人到底做没做过它一无所知，却给 PASS_COUNT 加了 1。
#   这是把「没查」写成「查过且合格」，比 SKIP 不计数更坏 ——
#   SKIP 至少还在输出里留下了痕迹。
#   现改为：必须由调用方显式声明才认账，声明本身随 stdout 进入发版留证。
if manual_confirmed "G5"; then
  pass "已由调用方声明人工验证通过（GATE_MANUAL_CONFIRMED 含 G5）"
else
  echo "  [INFO] 手动验证命令："
  echo "    S2S_ENV=${ENV_NAME} docker compose \\"
  echo "      -f ${DEPLOY_DIR}/docker-compose.yml \\"
  echo "      -f ${OVERRIDE_FILE} \\"
  echo "      --env-file ${ENV_FILE} run --rm -e HMAC_PEPPERS_JSON= app"
  echo "    预期：容器退出，日志显示 'Missing required env var'"
  echo "    验证通过后重跑本脚本并带上声明："
  echo "      GATE_MANUAL_CONFIRMED=\"G5\" bash $0 ${ENV_NAME}"
  skip "G5" "未声明人工验证，密钥缺失时的快速失败行为未判定"
fi

# --- G6: HTTP 301 跳转 -------------------------------------------------------
echo ""
echo "[G6] HTTP 301 跳转"
if [[ "${ENV_NAME}" == "dev" ]]; then
  # dev 默认不启动 Caddy（profiles: tls），没有 HTTP 入口 —— 无对象可判，是 N/A 而非 SKIP
  not_applicable "G6" "dev 环境默认不启动 Caddy（profiles: tls），无 HTTP 入口"
elif [[ -n "${SITE_DOMAIN:-}" ]]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${SITE_DOMAIN}/" 2>/dev/null || echo "000")
  if [[ "${HTTP_CODE}" == "301" ]]; then
    pass "HTTP 返回 301 Moved Permanently"
  else
    fail "HTTP 返回 ${HTTP_CODE}，期望 301"
  fi
else
  skip "G6" "SITE_DOMAIN 未设置，HTTP 跳转未判定（可 export SITE_DOMAIN=... 后重跑）"
fi

# --- G7: 安全组检查（手动） --------------------------------------------------
echo ""
echo "[G7] 安全组端口受限（人工确认项）"
if [[ "${ENV_NAME}" == "dev" ]]; then
  # 本地开发机没有云安全组这个对象 —— 是 N/A，不是「该查但没查」
  not_applicable "G7" "dev 为本地开发机，无云安全组"
elif manual_confirmed "G7"; then
  pass "已由调用方声明人工验证通过（GATE_MANUAL_CONFIRMED 含 G7）"
else
  # 同 G5：原实现无条件 pass，把「没查」记成「合格」
  echo "  [INFO] 请确认阿里云安全组规则："
  echo "    - 入方向仅放行 443、80、22（白名单）"
  echo "    - 其他端口全部拒绝"
  echo "    - 验证方法：从非白名单 IP 用 nc 或 telnet 测试 22 端口，应超时"
  echo "    确认后重跑本脚本并带上声明："
  echo "      GATE_MANUAL_CONFIRMED=\"G7\" bash $0 ${ENV_NAME}"
  skip "G7" "未声明人工验证，云安全组入方向规则未判定"
fi

# --- G8: 备份文件权限 600 ----------------------------------------------------
echo ""
echo "[G8] 备份文件权限检查"
BACKUP_DIR="/var/backups/s2s/${ENV_NAME}"
BACKUP_FILES=$(find "${BACKUP_DIR}" -name '*.sql.gz' -type f 2>/dev/null || true)
if [[ -n "${BACKUP_FILES}" ]]; then
  # 原实现把权限检查放在 while 子 shell 里，FAIL_COUNT 的自增在子进程中丢失，
  # 因此权限错误永远不会反映到最终退出码。改用数组遍历留在当前 shell 内。
  BAD_PERM_FILES=""
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    PERMS=$(stat -c %a "$f" 2>/dev/null || echo "000")
    if [[ "${PERMS}" != "600" ]]; then
      BAD_PERM_FILES="${BAD_PERM_FILES}
      ${PERMS} ${f}"
    fi
  done <<< "${BACKUP_FILES}"

  if [[ -n "${BAD_PERM_FILES}" ]]; then
    fail "以下备份文件权限不是 600：${BAD_PERM_FILES}"
  else
    pass "所有备份文件权限正确"
  fi
else
  skip "G8" "${BACKUP_DIR} 下无备份文件，备份权限未判定"
fi

# --- G9: 日志无明文手机号 ----------------------------------------------------
echo ""
echo "[G9] 日志无明文手机号/身份证"
LOG_DIR="/var/log/app"
# ⚠ 与 G2 同型的假阴性，不能只判目录存在：目录存在但里面一个 .log 都没有时，
#   HITS 为空 → else → PASS「日志中无手机号明文」。可是根本没有日志被扫过。
#   脱敏这类判据尤其危险 —— 服务刚起还没落盘、日志被轮转搬走、挂载点没挂上，
#   都会呈现为「目录在、文件没有」，而每一次都会得到一个绿色的 PASS。
#   故必须先确认存在待扫文件，扫描面为空时是 SKIP。
if [[ ! -d "${LOG_DIR}" ]]; then
  skip "G9" "日志目录 ${LOG_DIR} 不存在，日志脱敏未判定"
else
  LOG_FILES=$(find "${LOG_DIR}" -name '*.log' -type f 2>/dev/null | head -1 || true)
  if [[ -z "${LOG_FILES}" ]]; then
    skip "G9" "${LOG_DIR} 下无 .log 文件，扫描面为空，日志脱敏未判定"
  else
    # 检查最近日志中是否有完整的 11 位手机号
    HITS=$(find "${LOG_DIR}" -name '*.log' -type f -exec grep -EH '1[3-9][0-9]{9}' {} \; 2>/dev/null | head -5 || true)
    if [[ -n "${HITS}" ]]; then
      fail "日志中发现疑似手机号明文：${HITS}"
    else
      pass "日志中无手机号明文"
    fi
  fi
fi

# --- G10: binlog 过期已配置 ---------------------------------------------------
echo ""
echo "[G10] binlog 过期配置"
# 判据参数为 binlog_expire_logs_seconds：MySQL 8.4 已移除 expire_logs_days，
# 查旧参数会永远查不到、把「已正确配置」误判成 FAIL。
# 阈值 259200 秒 = 3 天，对应盘分配表中 binlog 的 3GB 预算。
if ! command -v docker >/dev/null 2>&1; then
  skip "G10" "docker 未安装，binlog 过期配置未判定"
elif docker ps --format '{{.Names}}' | grep -q 's2s-mysql'; then
  MYSQL_ROOT_PASSWORD="$(grep -oP '^MYSQL_ROOT_PASSWORD=\K.*' "${ENV_FILE}" 2>/dev/null || true)"
  BINLOG_VALUE=$(docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" s2s-mysql \
    mysql -N -B -u root -e "SHOW VARIABLES LIKE 'binlog_expire_logs_seconds'" 2>/dev/null \
    | awk '{print $2}')
  if [[ -z "${BINLOG_VALUE}" ]]; then
    fail "binlog_expire_logs_seconds 查询不到，binlog 可能无声吃满盘"
  elif [[ "${BINLOG_VALUE}" -eq 0 ]]; then
    fail "binlog_expire_logs_seconds = 0（永不过期），binlog 将吃满 40G 盘"
  elif [[ "${BINLOG_VALUE}" -le 259200 ]]; then
    pass "binlog_expire_logs_seconds = ${BINLOG_VALUE} 秒（≤ 3 天）"
  else
    fail "binlog_expire_logs_seconds = ${BINLOG_VALUE} 秒，超出 3GB 预算对应的 259200 秒"
  fi
else
  skip "G10" "s2s-mysql 容器未运行，binlog 过期配置未判定"
fi

# --- G11: 镜像基线一致 -------------------------------------------------------
echo ""
echo "[G11] 容器镜像基线（tag 锁定 + digest 一致）"
# ⚠ 原实现写作 `if bash image-baseline.sh --verify; then pass ... else fail`，
#   只能分辨真/假两档。而台账全为 PENDING（digest 一个都没填、基线实质不存在）
#   时该脚本旧版返回 0，于是 G11 报 PASS —— 又一处「什么都没校验的通过」。
#   现按其三档退出码分辨：0 一致 / 1 不一致 / 2 台账未初始化或镜像未拉取。
bash "${DEPLOY_DIR}/scripts/image-baseline.sh" --verify >/tmp/s2s-baseline.out 2>&1
G11_RC=$?
case "${G11_RC}" in
  0) pass "镜像基线校验通过（详见 /tmp/s2s-baseline.out）" ;;
  2) skip "G11" "镜像台账未初始化（PENDING）或镜像未拉取，digest 一致性未判定；请执行 image-baseline.sh --refresh 并提交台账" ;;
  *) fail "镜像基线校验未通过，详情：
$(cat /tmp/s2s-baseline.out)" ;;
esac

# --- 汇总 --------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  门禁检查完成（环境：${ENV_NAME}）"
echo "  PASS: ${PASS_COUNT}  |  FAIL: ${FAIL_COUNT}  |  SKIP: ${SKIP_COUNT}  |  N/A: ${NA_COUNT}"
echo "=========================================="

# SKIP 必须逐条列名。只报「SKIP: 3」，读日志的人无法判断跳掉的是否恰好是
# 挡住核心风险的那一项 —— 而那一项往往就是最容易缺前置条件的一项。
if [[ "${SKIP_COUNT}" -gt 0 ]]; then
  echo ""
  echo "  未判定项（既非通过也非不通过）：${SKIP_ITEMS}"
fi

# 退出码分三档，不能把 SKIP 合并进 0：
#   调用方若只判 `if gate-check.sh; then 发版`，SKIP 归 0 就等于「没查过 = 可以发」。
#   分出 2 之后，调用方可以自行决定是否容忍不完整判定，但必须显式地决定。
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo ""
  echo "  [结论] 发版阻塞：存在 ${FAIL_COUNT} 项 FAIL，请修复后重新检查"
  exit 1
elif [[ "${SKIP_COUNT}" -gt 0 ]]; then
  echo ""
  echo "  [结论] 发版阻塞：无 FAIL，但有 ${SKIP_COUNT} 项未能判定。"
  echo "         「没有检查出问题」不等于「没有问题」。请补齐上列前置条件后重跑，"
  echo "         人工确认项则用 GATE_MANUAL_CONFIRMED=\"G5,G7\" 声明。"
  exit 2
else
  echo ""
  echo "  [结论] 全部 ${PASS_COUNT} 项判定通过（${NA_COUNT} 项按环境不适用），可以发版"
  exit 0
fi
