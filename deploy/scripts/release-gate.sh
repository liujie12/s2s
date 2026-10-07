#!/usr/bin/env bash
# ============================================================================
# S2S L3 出包门禁（release gate）
# ----------------------------------------------------------------------------
# 依据：
#   《DevSecOps 接入方案》§4.1 后门三层判据 / §4.2 release-gate.log 留证规格 /
#                         §4.3 签名门禁 / §4.4 出包门禁 11 步序列
#   《编码规范》§8 提交、分支与出包
#   《分支与版本标记规范》§3.1 rel/<env>/<APP_VERSION>
#   《完成定义 DoD》§2.4 出包类条目 R1–R4
#
# 本脚本只承载【判据】；四态记账、汇总与退出码结算由 gate-lib.sh 提供
# （L2 部署门禁与 L3 出包门禁共用同一份外壳，见 DevSecOps 条目 [112]）。
#
# 运行环境：WSL2（bash + strings/grep/sha256sum），经 WSL 互操作调用 Windows 侧
#   工具链 flutter.bat / keytool.exe / apksigner.bat。
#   为何不在 Windows 侧用 PowerShell 重写：L3 第 1/2/10/11 步需要的外壳职责与 L2
#   完全一致，各写一份会导致「SKIP 是否阻塞」悄悄不一致，而这种不一致没有任何
#   检出手段（两边都跑得通、都打印绿色结论，差别只在没人盯的退出码）。
#
# 用法：
#   bash release-gate.sh [选项]
#     --version <ts>       指定 APP_VERSION（默认取当前时间戳 YYYYmmdd-HHMMSS）
#     --skip-build         跳过第 4/5/6 步（analyze/test/build），用于复检既有产物
#     --apk <path>         指定待检 APK（默认 build/app/outputs/flutter-apk/app-release.apk）
#     --allow-skip "理由"  放行 SKIP 档（对 FAIL 无效；理由必填，写入日志与 tag）
#     -h | --help
#
# 退出码（三档，与 L2 一致）：0 放行 / 1 中止（存在 FAIL）/ 2 需显式理由（存在 SKIP）
# ============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# 定位仓库与门禁外壳。source 失败必须硬拦，不得降级为警告：
# 本脚本刻意不设 set -e，若 source 静默失败，后续 pass/fail 全成 command not found，
# 四个计数器保持 0、退出码极可能为 0 —— 「门禁库不在」会变成「门禁全部通过」。
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GATE_LIB="${SCRIPT_DIR}/gate-lib.sh"
[[ -f "${GATE_LIB}" ]] || { echo "[ERROR] 门禁外壳缺失：${GATE_LIB}" >&2; exit 1; }
# shellcheck source=gate-lib.sh
source "${GATE_LIB}" || { echo "[ERROR] 门禁外壳加载失败：${GATE_LIB}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
# 正式签名证书 SHA-256 指纹（registered）。来源：条目 [131] 生成的 s2s-release.jks
# （alias=s2s-release，CN=找鸭找，有效期 10000 天）。换证书等于换应用身份、老用户无法
# 覆盖安装，故此处是「一经写死不再改」的锚点；确需更换须同步 P7 备案材料。
readonly EXPECTED_CERT_SHA256="4EFB8B219F897D42B51B7D8FB4F7C76116C8DCF3C5D0654757FD02E3CD205CFA"

# rel/* tag 的环境段：内测包 baseUrl 指向 prod 后端（https://s2s.build110.com）。
readonly RELEASE_ENV="prod"

# release 构建注入的编译期常量（全工程唯一真源见 api_client.dart / amap_init_guard.dart）
readonly DEFINE_BASE_URL="S2S_API_BASE_URL=https://s2s.build110.com"
readonly DEFINE_IS_RELEASE="S2S_IS_RELEASE=true"
readonly DEFINE_AMAP_KEY_NAME="AMAP_ANDROID_KEY"

readonly DEFAULT_APK_REL="build/app/outputs/flutter-apk/app-release.apk"
readonly LOG_REL="build/release-gate.log"

# ---------------------------------------------------------------------------
# 参数默认值
# ---------------------------------------------------------------------------
APP_VERSION=""
SKIP_BUILD=0
APK_ARG=""
ALLOW_SKIP_REASON=""
ALLOW_SKIP_GIVEN=0

# ---------------------------------------------------------------------------
# 函数：usage
# 功能：打印脚本用法与退出码语义
# 参数：无
# 返回：无（调用方随后自行 exit）
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
用法：bash release-gate.sh [选项]
  --version <ts>       指定 APP_VERSION（默认取当前时间戳 YYYYmmdd-HHMMSS）
  --skip-build         跳过第 4/5/6 步（analyze/test/build），用于复检既有产物
  --apk <path>         指定待检 APK（默认 build/app/outputs/flutter-apk/app-release.apk）
  --allow-skip "理由"  放行 SKIP 档（对 FAIL 无效；理由必填，写入日志与 tag）
  -h | --help          打印本帮助
退出码：0 放行 / 1 中止（存在 FAIL，产物被物理删除）/ 2 需显式理由（存在未判定项）
EOF
}

# ---------------------------------------------------------------------------
# 函数：parse_args
# 功能：解析命令行参数，校验 --allow-skip 的理由必填
# 参数：$@ — 原始命令行参数
# 返回：无；校验失败时 exit 1
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)    APP_VERSION="${2:-}";        shift; [[ $# -gt 0 ]] && shift ;;
      --apk)        APK_ARG="${2:-}";            shift; [[ $# -gt 0 ]] && shift ;;
      --allow-skip) ALLOW_SKIP_REASON="${2:-}"; ALLOW_SKIP_GIVEN=1; shift; [[ $# -gt 0 ]] && shift ;;
      --skip-build) SKIP_BUILD=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "[ERROR] 未知参数：$1" >&2; usage; exit 1 ;;
    esac
  done
  # 裸开关（--allow-skip 后无值）会退化成肌肉记忆，与 `|| true` 无异；
  # 必须现场写一句「为什么这次可以不判定那几项」，构成 DevSecOps §3.2 的留证方式。
  if [[ "${ALLOW_SKIP_GIVEN}" -eq 1 && -z "${ALLOW_SKIP_REASON}" ]]; then
    echo "[ERROR] --allow-skip 的理由不可为空，须写明「为什么这次可以不判定那几项」" >&2
    exit 1
  fi
  if [[ "${ALLOW_SKIP_REASON}" == --* ]]; then
    echo "[ERROR] --allow-skip 的理由不得以 -- 开头（疑为把下一个选项当成了理由）" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 函数：win_env
# 功能：读取 Windows 侧环境变量值（WSL 默认不继承 Windows 变量）
# 参数：$1 — 变量名（不含 %）
# 返回：stdout 输出变量值；未定义时输出空串
# ---------------------------------------------------------------------------
win_env() {
  local v
  v="$(cmd.exe /c "echo %$1%" 2>/dev/null | tr -d '\r' | head -n1)"
  [[ "${v}" == *"%"* ]] && v=""
  echo "${v}"
}

# ---------------------------------------------------------------------------
# 函数：resolve_toolchain
# 功能：解析 Windows 侧工具链可执行文件路径（flutter / keytool / apksigner）
# 参数：无（读取 Windows PATH / ANDROID_HOME / ANDROID_SDK_ROOT / LOCALAPPDATA）
# 返回：无；通过全局变量 FLUTTER_WIN / KEYTOOL_WIN / APKSIGNER_WIN 传出
# 说明：均支持用同名环境变量覆盖，便于换机或工具链升级。
# ---------------------------------------------------------------------------
resolve_toolchain() {
  FLUTTER_WIN="${FLUTTER_WIN:-$(cmd.exe /c where flutter 2>/dev/null | tr -d '\r' | head -n1)}"
  KEYTOOL_WIN="${KEYTOOL_WIN:-$(cmd.exe /c where keytool 2>/dev/null | tr -d '\r' | head -n1)}"

  if [[ -z "${APKSIGNER_WIN:-}" ]]; then
    local sdk sdk_wsl v
    sdk="$(win_env ANDROID_HOME)"
    [[ -n "${sdk}" ]] || sdk="$(win_env ANDROID_SDK_ROOT)"
    [[ -n "${sdk}" ]] || sdk="$(win_env LOCALAPPDATA)\\Android\\Sdk"
    APKSIGNER_WIN=""
    if [[ -n "${sdk}" ]]; then
      # 目录列举在 WSL 侧用 ls 完成：把 Windows 路径直接塞进 `cmd /c dir` 会因
      # WSL→cmd 的路径传参被 cmd 判为「目录名语法不正确」（已实测），
      # 而 wslpath -u 转换后再 ls 不经过 cmd 解析，稳定。
      sdk_wsl="$(wslpath -u "${sdk}" 2>/dev/null || true)"
      if [[ -n "${sdk_wsl}" && -d "${sdk_wsl}/build-tools" ]]; then
        # build-tools 目录名即版本号，按版本倒排取第一个存在 apksigner.bat 的版本
        while IFS= read -r v; do
          [[ -z "${v}" ]] && continue
          if [[ -f "${sdk_wsl}/build-tools/${v}/apksigner.bat" ]]; then
            APKSIGNER_WIN="${sdk}\\build-tools\\${v}\\apksigner.bat"
            break
          fi
        done < <(ls -1 "${sdk_wsl}/build-tools" 2>/dev/null | sort -rV)
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# 函数：run_win
# 功能：调用一个 Windows 侧可执行文件（.exe/.bat），工作目录为仓库根
# 参数：$1 — 可执行文件 Windows 路径；其余参数原样透传
# 返回：被调用程序的退出码
# 说明：cmd.exe 会**自动继承**本进程的 cwd（实测 `cmd /c cd` 返回仓库 Windows 路径），
#       故无需 `cd /d ... && ...`；而 `cd /d` 经 WSL→cmd 传参会被 cmd 判为
#       「文件名、目录名或卷标语法不正确」（已实测），是必须避开的写法。
#       仓库根的保证由脚本开头的 `cd "${REPO}"` 提供。
# ---------------------------------------------------------------------------
run_win() {
  local exe="$1"; shift
  cmd.exe /c "$exe $*"
}

# ---------------------------------------------------------------------------
# 函数：resolve_apk
# 功能：确定待检 APK 的 WSL 路径
# 参数：无（读取 APK_ARG，空则用默认相对路径）
# 返回：stdout 输出 APK 的 WSL 绝对路径
# ---------------------------------------------------------------------------
resolve_apk() {
  if [[ -n "${APK_ARG}" ]]; then
    if [[ "${APK_ARG}" = /* ]]; then echo "${APK_ARG}"; else echo "${REPO}/${APK_ARG}"; fi
  else
    echo "${REPO}/${DEFAULT_APK_REL}"
  fi
}

# ---------------------------------------------------------------------------
# 函数：sha256_of
# 功能：计算文件的 SHA-256（大写十六进制，无分隔符）
# 参数：$1 — 文件路径
# 返回：stdout 输出 64 位大写十六进制摘要
# ---------------------------------------------------------------------------
sha256_of() {
  sha256sum "$1" | awk '{print toupper($1)}'
}

# ---------------------------------------------------------------------------
# 函数：normalize_fp
# 功能：归一化证书指纹为「大写、去冒号」形态，便于跨工具比对
# 参数：$1 — 形如 AA:BB:... 或 aabb... 的指纹
# 返回：stdout 输出归一化结果
# ---------------------------------------------------------------------------
normalize_fp() {
  echo "$1" | tr -d ':' | tr -d ' ' | tr 'a-z' 'A-Z'
}

# ---------------------------------------------------------------------------
# 函数：debug_cert_sha256
# 功能：读取本机 Android debug keystore 的证书 SHA-256（用于「不得为 debug 签名」判据）
# 参数：无（读取 Windows %USERPROFILE%\.android\debug.keystore）
# 返回：stdout 输出归一化指纹；debug keystore 不存在时输出空串
# 说明：debug keystore 是每台机器随机生成的，其指纹不是通用常量，故只能在
#       本机存在时做比对；「与登记指纹一致」这条更强的判据在 S8 中独立成立。
# ---------------------------------------------------------------------------
debug_cert_sha256() {
  local d dbg_wsl dbg_win keytool_wsl out
  # 在 /mnt/c/Users/* 下定位 .android/debug.keystore：用户目录名含中文时，
  # 从 cmd 回传的 %USERPROFILE% 是 GBK 字节、与文件系统上的 UTF-8 路径不匹配
  # （实测 `wslpath -u` 结果看似正确却 test -f 失败），故完全绕开文本边界。
  dbg_wsl=""
  for d in /mnt/c/Users/*/; do
    if [[ -f "${d}.android/debug.keystore" ]]; then dbg_wsl="${d}.android/debug.keystore"; break; fi
  done
  [[ -n "${dbg_wsl}" ]] || { echo ""; return 0; }

  keytool_wsl="$(wslpath -u "${KEYTOOL_WIN}" 2>/dev/null || true)"
  [[ -n "${keytool_wsl}" ]] || { echo ""; return 0; }
  dbg_win="$(wslpath -w "${dbg_wsl}")"
  # keytool.exe 是 .exe，可由 WSL 直接执行（binfmt）；keystore 路径作为**独立参数**传入，
  # 不经 `cmd /c` 的引号/非 ASCII 参数边界（实测那条路必然失败）。
  out="$("${keytool_wsl}" -list -v -keystore "${dbg_win}" -storepass android -alias androiddebugkey 2>/dev/null)"
  normalize_fp "$(echo "${out}" | grep -i 'SHA256:' | head -n1 | awk -F': ' '{print $NF}' | tr -d '\r' | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# 函数：extract_stream
# 功能：从 APK 抽取可扫描的文本流（先解压条目再取可打印串）
# 参数：$1 — APK 的 WSL 路径；$2 — all（全部条目）| dart（仅 Dart AOT 产物 libapp.so）
# 返回：stdout 输出可扫描文本
# 说明：APK 是 zip，其中 libapp.so 通常未压缩、而 dex 可能被 deflate 压缩，直接对
#       zip 跑 strings 会看不到压缩条目内的字符串 ——「搜不到」会与「真干净」同形
#       （与部署门禁 G2/G9 的假阴性同源）。故优先解压后再扫描，解压通道按可用性
#       降级：python3 → unzip → strings（后者仅扫未压缩区，可能漏，判据侧会因此
#       记 SKIP 而非 PASS —— 见第 7 步对空扫描面的断言）。
# ---------------------------------------------------------------------------
extract_stream() {
  local apk="$1" mode="$2" pattern
  if [[ "${mode}" == "dart" ]]; then pattern='lib/*/libapp.so'; else pattern='*'; fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${apk}" "${mode}" <<'PY' 2>/dev/null | strings -a
import sys, zipfile
apk, mode = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk) as z:
    for name in z.namelist():
        if mode == 'dart' and not (name.startswith('lib/') and name.endswith('/libapp.so')):
            continue
        sys.stdout.buffer.write(z.read(name))
PY
  elif command -v unzip >/dev/null 2>&1; then
    unzip -p "${apk}" "${pattern}" 2>/dev/null | strings -a
  else
    strings -a "${apk}"
  fi
}

# 切到仓库根：Windows 侧子进程（cmd.exe）继承本进程 cwd，run_win 据此免写 `cd /d`。
cd "${REPO}" || { echo "[ERROR] 无法进入仓库根：${REPO}" >&2; exit 1; }

parse_args "$@"
resolve_toolchain
[[ -n "${APP_VERSION}" ]] || APP_VERSION="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${REPO}/${LOG_REL}"
mkdir -p "$(dirname "${LOG_FILE}")"

# 计数留证（写入日志，不在最终汇总里冒充判据）
COUNT_888888="N/A"
COUNT_DEBUGCODE="N/A"
SCAN_METHOD="N/A"
APK_PATH="$(resolve_apk)"
APK_SHA256="N/A"
SIGNER_SHA256="N/A"
DEBUG_FP="N/A"
BRANCH="N/A"
COMMIT="N/A"
CHECKPOINT_TAG="N/A"
TAG_NAME=""
TAG_RESULT="N/A"

echo "=========================================="
echo "  S2S L3 出包门禁"
echo "  APP_VERSION : ${APP_VERSION}"
echo "  待检 APK    : ${APK_PATH}"
echo "=========================================="

# ---------------------------------------------------------------------------
# 第 1 步：工作区干净
# 口径（2026-10-07 用户裁定，见说明文档 DEC-22）：
#   「干净」= ① 已跟踪文件无改动（git status -uno 为空）；② 构建源码面
#   （lib/ android/ ios/ pubspec.yaml）下无未跟踪文件。
#   为何不用字面口径「git status 无任何未提交改动」：本机工具链会在代理运行期间
#   临时物化 .claude/skills/ 等配置目录，未跟踪条目随机出现（实测两次出包均因此
#   在运行中变脏）—— 那与「日志 commit 是否对应打包代码」无关。
#   为何仍要单独查源码面：未跟踪文件不属于任何 commit，但**未跟踪的源码会被编译
#   进产物**（漏 git add 的 lib/xxx.dart 即此情形），故不能只做 -uno。
# ---------------------------------------------------------------------------
TRACKED_DIRTY="$(git -C "${REPO}" status --porcelain --untracked-files=no)"
UNTRACKED_SRC="$(git -C "${REPO}" status --porcelain --untracked-files=all -- lib android ios pubspec.yaml 2>/dev/null | grep '^??' || true)"
if [[ -z "${TRACKED_DIRTY}" && -z "${UNTRACKED_SRC}" ]]; then
  pass "S1 工作区干净（已跟踪文件无改动；构建源码面 lib/ android/ ios/ pubspec.yaml 无未跟踪文件）"
else
  fail "S1 工作区不干净，日志中的 commit hash 无法对应到打包的代码：
$(printf '%s\n%s\n' "${TRACKED_DIRTY}" "${UNTRACKED_SRC}" | grep . | sed 's/^/        /')"
fi

# ---------------------------------------------------------------------------
# 第 2 步：分支与 commit hash（写入日志）
# ---------------------------------------------------------------------------
BRANCH="$(git -C "${REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
COMMIT="$(git -C "${REPO}" rev-parse HEAD 2>/dev/null || echo unknown)"
CHECKPOINT_TAG="$(git -C "${REPO}" describe --tags --abbrev=0 --match 'checkpoint/*' 2>/dev/null || echo none)"
pass "S2 分支=${BRANCH} commit=${COMMIT} 最近 checkpoint=${CHECKPOINT_TAG}"

# ---------------------------------------------------------------------------
# 第 3 步：源码层后门 grep
# 口径（2026-10-07 用户裁定，见说明文档 DEC-21）：要求的不是「命中行本身在
# kDebugMode 块内」，而是「命中的**使用点**在 kDebugMode 内」；常量**声明点**
# 不强制包裹 —— 其值是否真进产物由产物层（第 7 步）判定，而 §4.1 已明确
# 「产物层是唯一有效的最终判据」。故声明点形态自动放行，其余形态仍需人工确认。
# ---------------------------------------------------------------------------
SRC_HITS_LINES="$(grep -rn '888888' "${REPO}/lib" 2>/dev/null || true)"
if [[ -z "${SRC_HITS_LINES}" ]]; then
  pass "S3 源码层 lib/ 无 888888 命中"
else
  SRC_TOTAL="$(printf '%s\n' "${SRC_HITS_LINES}" | grep -c . || true)"
  SRC_DECL="$(printf '%s\n' "${SRC_HITS_LINES}" | grep -cE "=[[:space:]]*['\"]888888['\"]" || true)"
  if [[ "${SRC_DECL}" -eq "${SRC_TOTAL}" ]]; then
    pass "S3 源码层命中 ${SRC_TOTAL} 处，全部为常量声明点（=\`888888\`）；声明点不要求在 kDebugMode 内，其值是否进产物由产物层 S7 判定"
  elif manual_confirmed "S3"; then
    pass "S3 源码层命中 ${SRC_TOTAL} 处（含 $((SRC_TOTAL - SRC_DECL)) 处非声明点），已由 GATE_MANUAL_CONFIRMED=S3 声明人工确认使用点均在 kDebugMode 分支内"
  else
    skip "S3" "源码层命中 ${SRC_TOTAL} 处 888888，其中 $((SRC_TOTAL - SRC_DECL)) 处非常量声明点，需人工确认其使用点是否在 kDebugMode 分支内；确认后以 GATE_MANUAL_CONFIRMED=S3 重跑"
  fi
fi

# ---------------------------------------------------------------------------
# 第 4/5/6 步：分析 / 测试 / 构建（Windows 侧 flutter）
# ---------------------------------------------------------------------------
if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  not_applicable "S4" "本次以 --skip-build 复检既有产物，未执行 flutter analyze"
  not_applicable "S5" "本次以 --skip-build 复检既有产物，未执行 flutter test"
  not_applicable "S6" "本次以 --skip-build 复检既有产物，未执行 flutter build"
else
  if [[ -z "${FLUTTER_WIN}" ]]; then
    skip "S4" "未找到 flutter（Windows PATH 无 flutter）"
    skip "S5" "未找到 flutter，测试未执行"
    skip "S6" "未找到 flutter，构建未执行"
  else
    # S4 flutter analyze：只把 error 级问题当失败，warning/info 如实计数但不阻塞
    ANALYZE_OUT="$(run_win "${FLUTTER_WIN}" analyze --no-pub 2>&1)"
    ANALYZE_RC=$?
    ANALYZE_ERR="$(echo "${ANALYZE_OUT}" | grep -cE '^[[:space:]]*error' || true)"
    if [[ "${ANALYZE_ERR}" -gt 0 ]]; then
      fail "S4 flutter analyze 报 ${ANALYZE_ERR} 个 error：
$(echo "${ANALYZE_OUT}" | grep -E '^[[:space:]]*error' | head -n 20 | sed 's/^/        /')"
    elif [[ "${ANALYZE_RC}" -ne 0 ]]; then
      fail "S4 flutter analyze 退出码 ${ANALYZE_RC}（无 error 行，疑为 warning/info 或工具异常）：
$(echo "${ANALYZE_OUT}" | tail -n 20 | sed 's/^/        /')"
    else
      pass "S4 flutter analyze 通过（0 error）"
    fi

    # S5 flutter test：全量绿
    if run_win "${FLUTTER_WIN}" test > "${REPO}/build/release-gate.test.log" 2>&1; then
      pass "S5 flutter test 全绿（输出见 build/release-gate.test.log）"
    else
      fail "S5 flutter test 未全绿，末尾输出：
$(tail -n 25 "${REPO}/build/release-gate.test.log" | sed 's/^/        /')"
    fi

    # S6 flutter build apk --release（含 --dart-define 注入）
    if [[ -z "${AMAP_ANDROID_KEY:-}" ]]; then
      skip "S6-Key" "未提供 AMAP_ANDROID_KEY，构建出的包地图将走降级底图（P0 五环之一不可验）"
    fi
    DEFINES="--dart-define=${DEFINE_BASE_URL} --dart-define=${DEFINE_IS_RELEASE}"
    [[ -n "${AMAP_ANDROID_KEY:-}" ]] && DEFINES="${DEFINES} --dart-define=${DEFINE_AMAP_KEY_NAME}=${AMAP_ANDROID_KEY}"
    if run_win "${FLUTTER_WIN}" build apk --release ${DEFINES} > "${REPO}/build/release-gate.build.log" 2>&1; then
      pass "S6 flutter build apk --release 成功（输出见 build/release-gate.build.log）"
    else
      fail "S6 flutter build apk --release 失败，末尾输出：
$(tail -n 25 "${REPO}/build/release-gate.build.log" | sed 's/^/        /')"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 第 7 步：产物层后门扫描（唯一有效的最终判据）
# 扫描面口径（2026-10-07 用户裁定，见说明文档 DEC-21）：
#   ① `888888` 只在 `lib/*/libapp.so`（我们的 Dart AOT 产物）上扫 —— 后门只可能
#      出现在我们自己编译出的代码里；`libflutter.so` 是预编译的 Flutter 引擎，
#      其中大量 0x38 字节连串会被 strings 读成 `888888...`（实测每条 ABI 184 次），
#      `classes*.dex` 同样含字节噪声（实测 4 次）。对整包做数字字面量 grep 在本项目
#      **恒为假阳性**，永远无法为 0，等于把这条判据变成永久 FAIL。
#   ② `debugCode`（后门标识符，非数字，无噪声）仍在**整包**上扫。
#   两者均须为 0。
# ---------------------------------------------------------------------------
if [[ ! -f "${APK_PATH}" ]]; then
  fail "S7 产物不存在：${APK_PATH}"
else
  SCAN_METHOD="dart=lib/*/libapp.so | full=全部条目（解压后扫描）"
  DART_STREAM="$(extract_stream "${APK_PATH}" dart)"
  FULL_STREAM="$(extract_stream "${APK_PATH}" all)"
  # 先断言扫描面存在，再执行判据：判据「没搜到」与判据「没东西可搜」在 shell 里
  # 都表现为空输出，若不先断言，空扫描面会稳定拿到一个绿色的 PASS ——
  # 与部署门禁 G2（Dockerfile 不存在却报 PASS）/ G9（日志目录为空却报 PASS）同源。
  if [[ -z "${DART_STREAM}" ]]; then
    skip "S7" "Dart 产物扫描面为空（APK 内未取到 lib/*/libapp.so），产物层后门无法判定"
  elif [[ -z "${FULL_STREAM}" ]]; then
    skip "S7" "整包扫描面为空（解压通道无输出），debugCode 无法判定"
  else
    COUNT_888888="$(printf '%s' "${DART_STREAM}" | grep -c '888888' || true)"
    COUNT_DEBUGCODE="$(printf '%s' "${FULL_STREAM}" | grep -c 'debugCode' || true)"
    if [[ "${COUNT_888888}" -eq 0 && "${COUNT_DEBUGCODE}" -eq 0 ]]; then
      pass "S7 产物扫描（${SCAN_METHOD}）：libapp.so 中 888888=${COUNT_888888}、整包 debugCode=${COUNT_DEBUGCODE}"
    else
      fail "S7 产物层发现后门残留：libapp.so 中 888888=${COUNT_888888}、整包 debugCode=${COUNT_DEBUGCODE}（两者均须为 0）"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 第 8 步：apksigner 验签（非 debug 指纹，且与登记指纹一致）
# ---------------------------------------------------------------------------
if [[ ! -f "${APK_PATH}" ]]; then
  skip "S8" "产物不存在，无法验签"
elif [[ -z "${APKSIGNER_WIN}" ]]; then
  skip "S8" "未找到 apksigner（Android SDK build-tools 不可用）"
else
  APK_WIN="$(wslpath -w "${APK_PATH}")"
  if SIGN_OUT="$(run_win "${APKSIGNER_WIN}" verify --print-certs "${APK_WIN}" 2>&1)"; then
    SIGNER_SHA256="$(normalize_fp "$(echo "${SIGN_OUT}" | grep -i 'certificate SHA-256 digest' | head -n1 | awk -F': ' '{print $NF}' | tr -d '\r' | tr -d ' ')")"
    DEBUG_FP="$(debug_cert_sha256)"
    if [[ -n "${DEBUG_FP}" && "${SIGNER_SHA256}" == "${DEBUG_FP}" ]]; then
      fail "S8 APK 使用 debug 签名（指纹 ${DEBUG_FP} 与本机 debug keystore 一致）"
    elif [[ "${SIGNER_SHA256}" != "${EXPECTED_CERT_SHA256}" ]]; then
      fail "S8 APK 签名指纹与登记证书不一致：实际 ${SIGNER_SHA256}，期望 ${EXPECTED_CERT_SHA256}（换签名等于换应用身份，老用户无法覆盖安装）"
    else
      pass "S8 apksigner 验签通过，签名证书 SHA-256 = ${SIGNER_SHA256}（与登记指纹一致；本机 debug keystore 比对：${DEBUG_FP:-未安装}）"
    fi
  else
    SIGNER_SHA256="VERIFY_FAILED"
    fail "S8 apksigner 验签失败：
$(echo "${SIGN_OUT}" | tail -n 15 | sed 's/^/        /')"
  fi
fi

# ---------------------------------------------------------------------------
# 第 9 步：计算产物 SHA-256（把「这份证明」与「这个产物」锁在一起）
# ---------------------------------------------------------------------------
if [[ -f "${APK_PATH}" ]]; then
  APK_SHA256="$(sha256_of "${APK_PATH}")"
  pass "S9 APK SHA-256 = ${APK_SHA256}"
else
  skip "S9" "产物不存在，无法计算 SHA-256"
fi

# ---------------------------------------------------------------------------
# 结算：先算退出码，再写留证日志（第 10 步）与删产物（第 11 步）
# 刻意不使用 gate_conclude（它自带 exit），否则这两个钩子插不进去。
# ---------------------------------------------------------------------------
gate_summary "L3 出包门禁 | APP_VERSION=${APP_VERSION}"

GATE_RC="$(gate_exit_code)"
case "${GATE_RC}" in
  0) VERDICT="PASS" ;;
  1) VERDICT="FAIL" ;;
  2) VERDICT="SKIP（存在未判定项）" ;;
esac

# ---------------------------------------------------------------------------
# 第 10 步：写 build/release-gate.log（自动写入，不允许手工编辑）
# ---------------------------------------------------------------------------
{
  echo "# S2S release-gate.log（由 deploy/scripts/release-gate.sh 自动生成，禁止手工编辑）"
  echo "① 执行时间戳   : $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "   APP_VERSION  : ${APP_VERSION}"
  echo "   分支 / commit: ${BRANCH} / ${COMMIT}"
  echo "   最近 checkpoint tag: ${CHECKPOINT_TAG}"
  echo "② APK 路径     : ${APK_PATH}"
  echo "   APK SHA-256  : ${APK_SHA256}"
  echo "③ 888888 计数  : ${COUNT_888888}（扫描方式：${SCAN_METHOD}）"
  echo "④ debugCode计数: ${COUNT_DEBUGCODE}"
  echo "⑤ 签名验证结果 : ${SIGNER_SHA256}（期望 ${EXPECTED_CERT_SHA256}）"
  echo "   本机 debug 证书指纹: ${DEBUG_FP:-未安装}"
  echo "   门禁汇总     : PASS ${GATE_PASS_COUNT} | FAIL ${GATE_FAIL_COUNT} | SKIP ${GATE_SKIP_COUNT} | N/A ${GATE_NA_COUNT}"
  [[ "${GATE_SKIP_COUNT}" -gt 0 ]] && echo "   未判定项     :${GATE_SKIP_ITEMS}"
  [[ -n "${ALLOW_SKIP_REASON}" ]] && echo "   SKIP 放行理由: ${ALLOW_SKIP_REASON}"
  echo "⑥ 最终判定     : ${VERDICT}"
} > "${LOG_FILE}"
echo ""
echo "  留证日志已写入：${LOG_FILE}"
if [[ -f "${APK_PATH}" ]]; then
  pass "S10 release-gate.log 已写入（含时间戳/APK路径/SHA-256/双计数/签名结果/最终判定）"
else
  pass "S10 release-gate.log 已写入"
fi

# ---------------------------------------------------------------------------
# 第 11 步：FAIL 时物理删除产物 APK（防止误分发）
# ---------------------------------------------------------------------------
if [[ "${GATE_RC}" -eq 1 ]]; then
  if [[ -f "${APK_PATH}" ]]; then
    rm -f "${APK_PATH}"
    echo "  [处置] FAIL：已物理删除产物 APK ${APK_PATH}"
  fi
  echo ""
  echo "  [结论] 阻塞：存在 ${GATE_FAIL_COUNT} 项 FAIL，请修复后重新出包"
  exit 1
fi

# SKIP 档：默认阻塞；带 --allow-skip="理由" 时显式放行（只对 SKIP 生效，对 FAIL 无效）
if [[ "${GATE_RC}" -eq 2 ]]; then
  if [[ -z "${ALLOW_SKIP_REASON}" ]]; then
    echo ""
    echo "  [结论] 阻塞：无 FAIL，但有 ${GATE_SKIP_COUNT} 项未能判定。"
    echo "         「没有检查出问题」不等于「没有问题」。补齐前置条件后重跑；"
    echo "         确需放行请带 --allow-skip=\"理由\"（理由将写入日志与 tag）。"
    exit 2
  fi
  echo ""
  echo "  [放行] SKIP 档已按显式理由放行：${ALLOW_SKIP_REASON}"
fi

# ---------------------------------------------------------------------------
# 打 rel/* tag（分支与版本标记规范 §3.1）：tag 名与 APP_VERSION 严格同值
# 时机在门禁通过之后 —— 打在前面等于给未验证的东西背书。
# tag 创建失败不得只打印一行就放行：DoD R1 把「rel/* tag 与 APP_VERSION 严格同值」
# 列为出包类条目的验收点，无锚点就无法把这次交付对应到确定的代码状态。
# ---------------------------------------------------------------------------
TAG_NAME="rel/${RELEASE_ENV}/${APP_VERSION}"
TAG_RC=0
if git -C "${REPO}" rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null 2>&1; then
  TAG_RESULT="已存在，未重复创建"
else
  TAG_MSG="APP_VERSION: ${APP_VERSION}
产物: ${APK_PATH}
SHA-256: ${APK_SHA256}
门禁结论: PASS ${GATE_PASS_COUNT} | SKIP ${GATE_SKIP_COUNT}$([[ -n "${ALLOW_SKIP_REASON}" ]] && echo "（放行理由：${ALLOW_SKIP_REASON}）")"
  # 刻意不写 2>/dev/null：失败原因（缺 tagger 身份 / 权限 / 同名冲突）正是唯一排查线索
  if TAG_ERR="$(git -C "${REPO}" tag -a "${TAG_NAME}" -m "${TAG_MSG}" 2>&1)"; then
    TAG_RESULT="已创建（附注 tag）"
  else
    TAG_RESULT="创建失败"
    TAG_RC=1
  fi
fi

echo ""
echo "  版本锚点：${TAG_NAME} —— ${TAG_RESULT}"
if [[ "${TAG_RC}" -ne 0 ]]; then
  echo "  [处置] 版本锚点创建失败：${TAG_ERR}"
  echo "         DoD R1 要求 rel/* tag 与 APP_VERSION 严格同值，无锚点不得视为交付完成"
  exit 1
fi
echo "  [结论] 全部 ${GATE_PASS_COUNT} 项判定通过（${GATE_NA_COUNT} 项按环境不适用），可以交付"
exit 0
