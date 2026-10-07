#!/usr/bin/env bash
# ============================================================================
# S2S 服务器初始化脚本（CentOS 7 / Rocky Linux / AlmaLinux）
# ----------------------------------------------------------------------------
# 用途：在一台干净的 CentOS 系服务器上，一次性做完部署前的所有准备工作：
#         1. 系统更新与基础工具
#         2. 2GB swap 配置
#         3. 防火墙（firewalld）放行 22/80/443
#         4. Docker CE + docker compose 插件
#         5. JDK 21（Eclipse Temurin）+ Maven 3.9
#         6. Git / OpenSSL / curl
#         7. 时区 Asia/Shanghai + NTP 同步
#         8. 创建部署目录 /opt/s2s
#
# 用法：
#   sudo bash server-init.sh
#
# 幂等性：所有步骤均可重复执行，已安装的不会重新安装。
# 退出码：0 成功 / 1 失败
# ============================================================================

set -euo pipefail

# ---- 颜色输出 -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---- 必须 root ---------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  error "请用 root 或 sudo 执行本脚本"
fi

# ---- 检测系统版本 -----------------------------------------------------------
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_NAME="${ID}"
  OS_VERSION="${VERSION_ID}"
else
  error "无法检测操作系统版本（/etc/os-release 不存在）"
fi

if [[ "${OS_NAME}" != "centos" && "${OS_NAME}" != "rocky" && "${OS_NAME}" != "almalinux" && "${OS_NAME}" != "rhel" ]]; then
  warn "检测到系统：${OS_NAME} ${OS_VERSION}，可能不完全兼容"
  read -rp "是否继续？(y/N) " -n 1 -r
  echo
  [[ "${REPLY}" =~ ^[Yy]$ ]] || error "已取消"
fi

info "系统：${OS_NAME} ${OS_VERSION}"

# ============================================================================
# 第 1 步：系统更新与基础工具
# ============================================================================
step1() {
  info "[1/8] 系统更新与安装基础工具..."

  # EPEL 仓库（部分工具依赖）
  if ! rpm -q epel-release >/dev/null 2>&1; then
    if [[ "${OS_NAME}" == "centos" ]]; then
      yum install -y epel-release
    else
      # Rocky / AlmaLinux 自带 epel-release 包
      yum install -y epel-release || warn "epel-release 安装失败，跳过（不影响核心功能）"
    fi
  fi

  # 基础工具
  yum install -y \
    curl wget git vim-enhanced unzip openssl \
    yum-utils device-mapper-persistent-data lvm2 \
    net-tools bind-utils

  info "[1/8] 完成"
}

# ============================================================================
# 第 2 步：swap 2GB
# ============================================================================
step2() {
  info "[2/8] 配置 2GB swap..."

  if swapon --show | grep -q .; then
    warn "已有 swap 配置，跳过：$(swapon --show --noheadings | awk '{print $1, $3}')"
    return 0
  fi

  if [[ -f /swapfile ]]; then
    warn "/swapfile 已存在但未启用，尝试启用..."
    chmod 600 /swapfile
    swapon /swapfile || error "启用 swap 失败"
  else
    fallocate -l 2G /swapfile || error "创建 swapfile 失败"
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
  fi

  # 写入 fstab（幂等：已存在则不重复）
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  # swappiness 调为 10（减少主动换出）
  sysctl vm.swappiness=10
  if ! grep -q '^vm.swappiness' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
  fi

  info "[2/8] 完成：$(free -h | grep Swap | awk '{print $2}')"
}

# ============================================================================
# 第 3 步：防火墙
# ============================================================================
step3() {
  info "[3/8] 配置防火墙（放行 22/80/443）..."

  if ! systemctl is-active --quiet firewalld; then
    if systemctl list-unit-files | grep -q firewalld.service; then
      systemctl enable --now firewalld
    else
      warn "firewalld 未安装，尝试安装..."
      yum install -y firewalld
      systemctl enable --now firewalld
    fi
  fi

  # 放行服务（幂等：已放行也不会报错）
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload

  info "[3/8] 完成：$(firewall-cmd --list-services)"
  warn "⚠ 如果你在云厂商（阿里云/腾讯云等）上，请在控制台安全组也放行 22/80/443"
}

# ============================================================================
# 第 4 步：Docker CE
# ============================================================================
step4() {
  info "[4/8] 安装 Docker CE..."

  if command -v docker >/dev/null 2>&1; then
    local ver
    ver="$(docker --version | awk '{print $3}' | sed 's/,//')"
    warn "Docker 已安装（${ver}），跳过"
    # 确保 docker compose 插件存在
    if ! docker compose version >/dev/null 2>&1; then
      yum install -y docker-compose-plugin
    fi
    systemctl enable --now docker
    return 0
  fi

  # 添加 Docker 官方 yum 仓库
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

  # 安装
  yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # 启动并设为开机自启
  systemctl enable --now docker

  # 验证
  docker --version
  docker compose version

  info "[4/8] 完成"
}

# ============================================================================
# 第 5 步：JDK 21（Eclipse Temurin）+ Maven 3.9
# ============================================================================
step5() {
  info "[5/8] 安装 JDK 21 + Maven 3.9..."

  # JDK 21：用 Eclipse Adoptium Temurin
  if ! java -version 2>&1 | grep -q 'version "21'; then
    # 添加 Adoptium 仓库
    cat > /etc/yum.repos.d/adoptium.repo <<'EOF'
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/centos/${releasever}/${basearch}
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF

    yum install -y temurin-21-jdk

    # 设置 JAVA_HOME
    cat > /etc/profile.d/java.sh <<'EOF'
export JAVA_HOME=/usr/lib/jvm/temurin-21-jdk
export PATH=$JAVA_HOME/bin:$PATH
EOF
    # shellcheck disable=SC1091
    source /etc/profile.d/java.sh
  else
    warn "JDK 21 已安装，跳过"
  fi

  # Maven 3.9：官方二进制包（yum 里版本太老）
  if ! mvn -version 2>/dev/null | grep -q 'Apache Maven 3.9'; then
    local maven_ver="3.9.9"
    local maven_dir="/opt/apache-maven-${maven_ver}"

    if [[ ! -d "${maven_dir}" ]]; then
      cd /opt
      wget -q "https://dlcdn.apache.org/maven/maven-3/${maven_ver}/binaries/apache-maven-${maven_ver}-bin.tar.gz" \
        -O "apache-maven-${maven_ver}-bin.tar.gz"
      tar xzf "apache-maven-${maven_ver}-bin.tar.gz"
      rm -f "apache-maven-${maven_ver}-bin.tar.gz"
    fi

    cat > /etc/profile.d/maven.sh <<EOF
export MAVEN_HOME=${maven_dir}
export PATH=\$MAVEN_HOME/bin:\$PATH
EOF
    # shellcheck disable=SC1091
    source /etc/profile.d/maven.sh
  else
    warn "Maven 3.9 已安装，跳过"
  fi

  java -version
  mvn -version

  info "[5/8] 完成"
}

# ============================================================================
# 第 6 步：Git / OpenSSL / curl 确认
# ============================================================================
step6() {
  info "[6/8] 验证基础工具..."

  for cmd in git openssl curl; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      error "缺少命令：${cmd}（第 1 步应该已安装，请检查）"
    fi
  done

  info "[6/8] 完成：git=$(git --version | awk '{print $3}'), openssl=$(openssl version | awk '{print $2}'), curl=$(curl --version | head -1 | awk '{print $2}')"
}

# ============================================================================
# 第 7 步：时区与时间同步
# ============================================================================
step7() {
  info "[7/8] 时区与时间同步..."

  # 时区设为 Asia/Shanghai
  timedatectl set-timezone Asia/Shanghai 2>/dev/null || {
    # CentOS 7 可能没有 timedatectl，用软链接方式
    rm -f /etc/localtime
    ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  }

  # 启用 NTP 同步（chrony 或 ntp）
  if systemctl list-unit-files | grep -q chronyd.service; then
    systemctl enable --now chronyd 2>/dev/null || warn "chronyd 启动失败，跳过"
  elif systemctl list-unit-files | grep -q ntpd.service; then
    systemctl enable --now ntpd 2>/dev/null || warn "ntpd 启动失败，跳过"
  else
    yum install -y chrony
    systemctl enable --now chronyd 2>/dev/null || warn "chrony 安装后启动失败"
  fi

  date
  info "[7/8] 完成"
}

# ============================================================================
# 第 8 步：创建部署目录
# ============================================================================
step8() {
  info "[8/8] 创建部署目录..."

  mkdir -p /opt/s2s
  mkdir -p /var/backups/s2s
  chmod 700 /var/backups/s2s

  # 限制 sshd 登录信息提示（可选加固）
  info "[8/8] 完成：/opt/s2s 和 /var/backups/s2s 已创建"
}

# ============================================================================
# 主流程
# ============================================================================
main() {
  echo "=========================================="
  echo "  S2S 服务器初始化脚本"
  echo "  系统：${OS_NAME} ${OS_VERSION}"
  echo "  时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  echo

  step1
  step2
  step3
  step4
  step5
  step6
  step7
  step8

  echo
  echo "=========================================="
  echo "  初始化完成！"
  echo "=========================================="
  echo
  echo "下一步："
  echo "  1. 配置 SSH（如果你用密钥登录，确保 authorized_keys 正确）"
  echo "  2. 到云厂商控制台确认安全组已放行 22/80/443"
  echo "  3. 执行首次部署脚本：bash deploy-first.sh <仓库地址> <域名>"
  echo
  echo "验证命令："
  echo "  docker --version && docker compose version"
  echo "  java -version && mvn -version"
  echo "  free -h  # 确认 swap 约 2G"
  echo "  firewall-cmd --list-services  # 确认 ssh/http/https"
}

main "$@"
