#!/usr/bin/env bash
# ============================================================================
# S2S 容器镜像基线脚本
# ----------------------------------------------------------------------------
# 依据：《部署架构设计文档》§14.6 容器镜像基线
#       《DevSecOps 接入方案》§7.1 版本锁定
#
# 功能：
#   --verify   校验宿主机上的镜像 digest 与 images.lock 台账是否一致（默认）
#   --refresh  pull 全部镜像、读取真实 digest 并回写 images.lock
#   --pull     仅按台账拉取镜像，不改台账
#
# 执行方式：
#   bash deploy/scripts/image-baseline.sh --verify
#   bash deploy/scripts/image-baseline.sh --refresh
#
# 退出码：0 全部一致 / 1 存在不一致或错误 / 2 无不一致但有未初始化(PENDING)或未拉取项
#
# 纪律：
#   1. --refresh 会修改 images.lock，改完必须提交入库，否则下次 --verify
#      在别人机器上仍是 PENDING
#   2. PENDING 在 --verify 下判为 WARN 而非 FAIL：台账未初始化不应该
#      阻塞首次部署，但会持续提示直到有人跑一次 --refresh
#   3. WARN 必须走独立退出码 2，【不可】并入 0。台账全 PENDING 时基线实际上
#      并不存在，若 WARN 归 0，阻塞型调用方（gate-check.sh 的 G11 用
#      `if bash ... --verify` 判真假）会把「什么都没校验」收成 PASS。
#      非阻塞型调用方（env-up.sh）本就写成 `|| echo WARN`，不受本档影响。
# ============================================================================

set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${DEPLOY_DIR}/images.lock"
MODE="--verify"

# ---------------------------------------------------------------------------
# 函数：parse_args
# 功能：解析命令行参数，确定运行模式
# 参数：$@ — 原始命令行参数
# 返回：无返回值；设置全局变量 MODE。参数非法时直接退出 1
# ---------------------------------------------------------------------------
parse_args() {
  if [[ $# -eq 0 ]]; then
    return 0
  fi
  case "$1" in
    --verify|--refresh|--pull) MODE="$1" ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | head -30
      exit 0
      ;;
    *)
      echo "[ERROR] 未知参数：$1（可用：--verify | --refresh | --pull）" >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 函数：read_baseline
# 功能：从 images.lock 中读出所有「镜像 digest」条目，剔除注释与空行
# 参数：无
# 返回：向 stdout 逐行输出 "<image:tag> <digest|PENDING>"
# ---------------------------------------------------------------------------
read_baseline() {
  # sed 去掉行内注释与首尾空白后，只保留恰好两个字段的行
  sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${LOCK_FILE}" \
    | awk 'NF == 2 { print $1, $2 }'
}

# ---------------------------------------------------------------------------
# 函数：local_digest
# 功能：读取宿主机上某镜像的 RepoDigest（内容哈希）
# 参数：$1 — 镜像引用，形如 mysql:8.4
# 返回：向 stdout 输出 sha256:... ；镜像不存在或无 digest 时输出空串
# 说明：RepoDigests 为数组，本地构建但未 push 的镜像该数组为空，
#       因此空串是合法结果而非错误，调用方需自行区分。
# ---------------------------------------------------------------------------
local_digest() {
  docker image inspect "$1" \
    --format '{{ if .RepoDigests }}{{ index .RepoDigests 0 }}{{ end }}' 2>/dev/null \
    | sed 's/^.*@//'
}

parse_args "$@"

if [[ ! -f "${LOCK_FILE}" ]]; then
  echo "[ERROR] 未找到台账 ${LOCK_FILE}" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] 未安装 docker，无法操作镜像" >&2
  exit 1
fi

echo "=========================================="
echo "  S2S 镜像基线 ${MODE}"
echo "  台账：${LOCK_FILE}"
echo "=========================================="
echo ""

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

while read -r IMAGE EXPECTED; do
  [[ -z "${IMAGE}" ]] && continue

  # --- tag 合法性：三种禁用形态一律 FAIL，与 --verify/--refresh 模式无关 ----
  if [[ "${IMAGE}" == *:latest || "${IMAGE}" != *:* ]]; then
    echo "  [FAIL] ${IMAGE} —— 使用了 latest 或缺少 tag，违反版本锁定纪律"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  case "${MODE}" in
    --pull|--refresh)
      echo "  [PULL] ${IMAGE}"
      if ! docker pull -q "${IMAGE}" >/dev/null 2>&1; then
        echo "  [FAIL] ${IMAGE} 拉取失败（检查网络或镜像名）"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
      fi
      ;;
  esac

  ACTUAL="$(local_digest "${IMAGE}")"

  if [[ "${MODE}" == "--refresh" ]]; then
    if [[ -z "${ACTUAL}" ]]; then
      echo "  [WARN] ${IMAGE} 无 RepoDigest（本地构建未 push？），台账保持 PENDING"
      WARN_COUNT=$((WARN_COUNT + 1))
      continue
    fi
    # 就地回写：只替换该镜像行的第二个字段，不动任何注释
    # 分隔符用 | 而非 /：镜像名与 digest 都含 / 与 :，用 / 会与之冲突
    sed -i -E "s|^([[:space:]]*${IMAGE}[[:space:]]+)[^[:space:]]+|\1${ACTUAL}|" "${LOCK_FILE}"
    echo "  [ OK ] ${IMAGE} → ${ACTUAL}"
    OK_COUNT=$((OK_COUNT + 1))
    continue
  fi

  # --- --verify / --pull 的比对分支 ---------------------------------------
  if [[ "${EXPECTED}" == "PENDING" ]]; then
    echo "  [WARN] ${IMAGE} 台账未初始化（PENDING），请执行 --refresh 后提交"
    WARN_COUNT=$((WARN_COUNT + 1))
  elif [[ -z "${ACTUAL}" ]]; then
    echo "  [WARN] ${IMAGE} 本机未拉取该镜像，无法比对"
    WARN_COUNT=$((WARN_COUNT + 1))
  elif [[ "${ACTUAL}" == "${EXPECTED}" ]]; then
    echo "  [ OK ] ${IMAGE}"
    OK_COUNT=$((OK_COUNT + 1))
  else
    echo "  [FAIL] ${IMAGE} digest 不一致"
    echo "         台账：${EXPECTED}"
    echo "         实际：${ACTUAL}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done < <(read_baseline)

echo ""
echo "=========================================="
echo "  OK: ${OK_COUNT}  |  WARN: ${WARN_COUNT}  |  FAIL: ${FAIL_COUNT}"
echo "=========================================="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "  [结论] 基线校验未通过。digest 不一致意味着运行的镜像与台账记录的"
  echo "         不是同一个二进制 —— 要么有人手动 pull 了新版本，要么台账过期。"
  echo "         确认版本变更是有意的之后，执行 --refresh 更新台账并提交。"
  exit 1
fi

if [[ "${WARN_COUNT}" -gt 0 ]]; then
  echo "  [结论] 无不一致项，但有 ${WARN_COUNT} 项待初始化/未拉取 —— 基线尚未真正生效。"
  echo "         建议在联网机器上执行：bash deploy/scripts/image-baseline.sh --refresh"
  exit 2
fi

exit 0
