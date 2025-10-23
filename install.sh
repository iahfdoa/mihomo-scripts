#!/usr/bin/env bash
set -e

# ==========
# Mihomo 一键安装脚本（自动选择合适架构）
# ==========

# 检查依赖
install_dependencies() {
    echo "🔧 检查并安装依赖..."
    local pkgs=(curl openssl wget gzip)
    if command -v apt &>/dev/null; then
        apt update -y
        apt install -y "${pkgs[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${pkgs[@]}" tar || true
    elif command -v dnf &>/dev/null; then
        dnf install -y "${pkgs[@]}"
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm "${pkgs[@]}"
    elif command -v apk &>/dev/null; then
        apk add --no-cache "${pkgs[@]}"
    else
        echo "❌ 无法识别包管理器，请手动安装 curl openssl wget gzip"
        exit 1
    fi
}

for cmd in curl wget gzip openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        install_dependencies
        break
    fi
done

# ==========
# 检测系统架构
# ==========
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        BIN_ARCH="amd64"
        ;;
    aarch64)
        BIN_ARCH="arm64"
        ;;
    armv7l)
        BIN_ARCH="armv7"
        ;;
    armv6l)
        BIN_ARCH="armv6"
        ;;
    *)
        echo "❌ 不支持的架构: $ARCH"
        exit 1
        ;;
esac

# ==========
# 检测 CPU 指令集 (决定 v1/v2/v3)
# ==========
CPU_FLAGS=$(grep flags /proc/cpuinfo | head -n1)
if [[ $CPU_FLAGS =~ avx2 ]]; then
    LEVEL="v3"
elif [[ $CPU_FLAGS =~ avx ]]; then
    LEVEL="v2"
else
    LEVEL="v1"
fi
echo "🧠 检测到 CPU 架构: $ARCH, 指令集等级: $LEVEL"

# ==========
# 下载并安装 Mihomo
# ==========
if ! command -v mihomo &>/dev/null; then
    echo "⬇️  正在安装 mihomo ..."

    # 获取最新版本号
    LATEST_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo "❌ 获取版本号失败"
        exit 1
    fi

    # 拼接下载 URL
    # 优先选择 v1/v2/v3，对应 CPU 兼容性
    FILE_NAME="mihomo-linux-${BIN_ARCH}-${LEVEL}-${LATEST_VERSION}.gz"
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}"

    echo "📦 下载 ${FILE_NAME} ..."
    if ! wget -O /tmp/mihomo.gz "$DOWNLOAD_URL"; then
        echo "⚠️ 下载 ${LEVEL} 版本失败，尝试兼容版本..."
        FILE_NAME="mihomo-linux-${BIN_ARCH}-compatible-${LATEST_VERSION}.gz"
        DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}"
        wget -O /tmp/mihomo.gz "$DOWNLOAD_URL" || {
            echo "❌ 所有下载方式失败，请检查网络或 GitHub 访问。"
            exit 1
        }
    fi

    gzip -d /tmp/mihomo.gz
    chmod +x /tmp/mihomo
    mv /tmp/mihomo /usr/local/bin/mihomo
    echo "✅ mihomo 安装完成"
else
    echo "✅ 已检测到 mihomo，跳过安装步骤"
fi

# ==========
# 生成配置与证书
# ==========
mkdir -p /root/.config/mihomo/
echo "🔐 生成新的 SSL 证书..."
openssl req -newkey rsa:2048 -nodes \
  -keyout /root/.config/mihomo/server.key \
  -x509 -days 365 \
  -out /root/.config/mihomo/server.crt \
  -subj "/C=US/ST=CA/L=SF/O=$(openssl rand -hex 8)/CN=$(openssl rand -hex 12)"

HY2_PASSWORD=$(uuidgen)
ANYTLS_PASSWORD=$(uuidgen)
HY2_PORT=$((RANDOM % 40001 + 20000))
ANYTLS_PORT=$((RANDOM % 40001 + 20000))
while [ "$HY2_PORT" -eq "$ANYTLS_PORT" ]; do
    ANYTLS_PORT=$((RANDOM % 40001 + 20000))
done

cat > /root/.config/mihomo/config.yaml <<EOF
listeners:
- name: anytls-in-1
  type: anytls
  port: $ANYTLS_PORT
  listen: 0.0.0.0
  users:
    username1: '$ANYTLS_PASSWORD'
  certificate: ./server.crt
  private-key: ./server.key
- name: hy2
  type: hysteria2
  port: $HY2_PORT
  listen: 0.0.0.0
  users:
    user1: $HY2_PASSWORD
  certificate: ./server.crt
  private-key: ./server.key
EOF

# ==========
# 创建 systemd 服务
# ==========
cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo
Restart=on-failure
RestartSec=3
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mihomo.service || {
    echo "⚠️ 服务启动失败，请运行: journalctl -u mihomo -xe"
}

PUBLIC_IP=$(curl -s ifconfig.me || echo "你的公网IP")
echo -e "\n✅ 安装成功！"
echo "--------------------------------------------"
echo "Hysteria2 配置:"
echo "- server: $PUBLIC_IP:$HY2_PORT"
echo "- password: $HY2_PASSWORD"
echo
echo "AnyTLS 配置:"
echo "- server: $PUBLIC_IP:$ANYTLS_PORT"
echo "- password: $ANYTLS_PASSWORD"
echo "--------------------------------------------"
systemctl status mihomo --no-pager -l
