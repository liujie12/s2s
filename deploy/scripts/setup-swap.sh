#!/usr/bin/env bash
# ============================================================================
# S2S swap 初始化脚本
# ----------------------------------------------------------------------------
# 依据：《部署架构设计文档》§4.3 swap 配置
#       《系统总体架构设计文档》§4.1（R8：内存预算已贴住 2G，swap 是硬要求）
#       《可观测性架构方案》§7（swap 文件占盘 2GB）
#
# 功能：在 ECS 上创建 2GB swap 文件并写入 fstab 持久化，降低 swappiness
# 执行时机：ECS 首次初始化时，在 docker compose up 之前执行一次
# 执行方式：sudo bash deploy/scripts/setup-swap.sh
# 幂等性：已存在 /swapfile 时直接跳过，不重复创建
# ============================================================================

set -euo pipefail

SWAP_FILE="/swapfile"
SWAP_SIZE="2G"
SWAPPINESS=10

# --- 前置校验：必须以 root 身份执行 -------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] 本脚本需要 root 权限，请用 sudo 执行" >&2
  exit 1
fi

# --- 幂等检查：swap 已启用则跳过 ---------------------------------------------
if swapon --show | grep -q "${SWAP_FILE}"; then
  echo "[SKIP] ${SWAP_FILE} 已启用，当前 swap 状态："
  swapon --show
  exit 0
fi

# --- 创建 swap 文件 ------------------------------------------------------------
echo "[1/5] 创建 ${SWAP_SIZE} swap 文件：${SWAP_FILE}"
if [[ -f "${SWAP_FILE}" ]]; then
  echo "      文件已存在但未启用，直接复用"
else
  # fallocate 比 dd 快，ESSD 上瞬间完成
  fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"
fi

# --- 权限收紧：swap 文件必须 600，否则内存内容可被任意用户读取 ------------------
echo "[2/5] 设置权限 600"
chmod 600 "${SWAP_FILE}"

# --- 格式化并启用 -------------------------------------------------------------
echo "[3/5] 格式化为 swap 格式"
mkswap "${SWAP_FILE}"

echo "[4/5] 启用 swap"
swapon "${SWAP_FILE}"

# --- 持久化到 fstab，确保 ECS 重启后自动挂载 -----------------------------------
if ! grep -q "^${SWAP_FILE}" /etc/fstab; then
  echo "[5/5] 写入 /etc/fstab 持久化"
  echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
else
  echo "[5/5] /etc/fstab 已含 swap 条目，跳过"
fi

# --- 降低 swappiness ----------------------------------------------------------
# 默认值 60 会在内存尚有余量时就主动换出，导致响应抖动。
# 设为 10：仅在内存确实吃紧时才用 swap，符合「swap 是兜底而非常态」的定位。
echo "[+] 设置 vm.swappiness=${SWAPPINESS}"
sysctl -w "vm.swappiness=${SWAPPINESS}" >/dev/null
if ! grep -q "^vm.swappiness" /etc/sysctl.conf; then
  echo "vm.swappiness=${SWAPPINESS}" >> /etc/sysctl.conf
fi

echo
echo "[DONE] swap 配置完成，当前状态："
swapon --show
free -h