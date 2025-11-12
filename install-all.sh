#!/usr/bin/env bash
set -e


random_free_port() {
    local port
    while true; do
        port=$((RANDOM % 40001 + 20000))
        if ! grep -q ":$(printf '%04X' $port)" /proc/net/tcp /proc/net/udp 2>/dev/null; then
            echo "$port"
            return
        fi
    done
}




# ==========
# Mihomo 一键安装脚本（自动选择合适架构）
# ==========



# 检查依赖
install_dependencies() {
    echo "🔧 检查并安装依赖..."
    # 基本依赖
    local base_pkgs=(curl openssl wget gzip)

    # 默认要安装的 uuidgen 包名（按不同包管理器设置）
    local uuid_pkg=""
    local extra_pkgs=()

    if command -v apt &>/dev/null; then
        uuid_pkg="uuid-runtime"
        # apt 安装前刷新索引
        apt update -y
        apt install -y "${base_pkgs[@]}" "$uuid_pkg"
    elif command -v yum &>/dev/null; then
        # yum/centos/rhel: util-linux 包含 uuidgen；保留 tar 兼容
        uuid_pkg="util-linux"
        extra_pkgs=(tar)
        yum install -y "${base_pkgs[@]}" "$uuid_pkg" "${extra_pkgs[@]}" || true
    elif command -v dnf &>/dev/null; then
        uuid_pkg="util-linux"
        dnf install -y "${base_pkgs[@]}" "$uuid_pkg"
    elif command -v pacman &>/dev/null; then
        uuid_pkg="util-linux"
        # pacman 需要同步更新数据库
        pacman -Sy --noconfirm "${base_pkgs[@]}" "$uuid_pkg"
    elif command -v apk &>/dev/null; then
        # Alpine 一般用 util-linux（在部分镜像/版本可能不同）
        uuid_pkg="util-linux"
        apk add --no-cache "${base_pkgs[@]}" "$uuid_pkg"
    else
        echo "❌ 无法识别包管理器，请手动安装: curl openssl wget gzip 和 uuidgen 提供包（例如 uuid-runtime 或 util-linux）"
        exit 1
    fi

    # 最后再校验 uuidgen 是否可用，如果仍不可用提示用户
    if ! command -v uuidgen &>/dev/null; then
        echo "⚠️ 安装完成，但系统仍未找到 uuidgen。尝试以下替代方案："
        echo "  • 在 Debian/Ubuntu 上：sudo apt install uuid-runtime"
        echo "  • 在 RHEL/CentOS/Fedora/Arch/Alpine 上：sudo yum/dnf/pacman/apk install util-linux"
        echo "  • 或在脚本中使用 python3 -c 'import uuid; print(uuid.uuid4())' 作为回退"
        # 不直接 exit，以便脚本可以继续（按原来逻辑可调整为 exit 1）
    else
        echo "✅ 依赖安装完成，uuidgen 可用。"
    fi
}

for cmd in curl wget gzip openssl uuidgen; do
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
    if [ "$BIN_ARCH" = "amd64" ]; then
      FILE_NAME="mihomo-linux-${BIN_ARCH}-${LEVEL}-${LATEST_VERSION}.gz"
    else
      FILE_NAME="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
    fi
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

# ========
# 生成 reality-keypair
# ========
# 使用 mihomo 自带命令生成 Reality 密钥对
REALITY_KEYS=$(mihomo generate reality-keypair)
# 提取 PrivateKey / PublicKey
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
VLESS_SNI="www.apple.com"




HY2_PASSWORD=$(uuidgen)
ANYTLS_PASSWORD=$(uuidgen)
VLESS_PASSWORD=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)
HY2_PORT=$(random_free_port)

# 确保 ANYTLS_PORT 不等于 HY2_PORT
while true; do
    ANYTLS_PORT=$(random_free_port)
    [ "$ANYTLS_PORT" -ne "$HY2_PORT" ] && break
done

# 确保 VLESS_PORT 不等于前两个
while true; do
    VLESS_PORT=$(random_free_port)
    if [ "$VLESS_PORT" -ne "$HY2_PORT" ] && [ "$VLESS_PORT" -ne "$ANYTLS_PORT" ]; then
        break
    fi
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
- name: vless-reality
  type: vless
  port: $VLESS_PORT
  listen: 0.0.0.0
  users:
  - uuid: "$VLESS_PASSWORD"
    username: 1
    flow: xtls-rprx-vision
  tls: true
  sni: "$VLESS_SNI"
  network: tcp
  udp: true
  packet-encoding: xudp
  reality-config:
    dest: "$VLESS_SNI:443"
    private-key: "$PRIVATE_KEY"
    short-id:
      - "$SHORT_ID"
    server-names:
      - "$VLESS_SNI"
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
# 输出客户端配置
echo -e "\n\n新的客户端配置信息："
echo "=============================================="
echo "1. Hysteria2 客户端配置:"
echo -e "\n- name: $PUBLIC_IP｜Direct｜hy2"
echo "  type: hysteria2"
echo "  server: $PUBLIC_IP"
echo "  port: $HY2_PORT"
echo "  password: '$HY2_PASSWORD'"
echo "  udp: true"
echo "  sni: bing.com"
echo "  skip-cert-verify: true"

echo -e "\n2. AnyTLS 客户端配置:"
echo -e "\n- name: $PUBLIC_IP｜Direct｜anytls"
echo "  server: $PUBLIC_IP"
echo "  type: anytls"
echo "  port: $ANYTLS_PORT"
echo "  password: $ANYTLS_PASSWORD"
echo "  skip-cert-verify: true"
echo "  sni: www.usavps.com"
echo "  udp: true"
echo "  tfo: true"
echo "  tls: true"
echo "  client-fingerprint: chrome"
echo "=============================================="

echo -e "\n3. Vless Reality 客户端配置:"
echo -e "\n- name: $PUBLIC_IP｜Direct｜vless"
echo "  server: $PUBLIC_IP"
echo "  type: vless"
echo "  port: $VLESS_PORT"
echo "  uuid: $VLESS_PASSWORD"
echo "  flow: xtls-rprx-vision"
echo "  tls: true"
echo "  servername: $VLESS_SNI"
echo "  client-fingerprint: chrome"
echo "  network: tcp"
echo "  udp: true"
echo "  packet-encoding: xudp"
echo "  reality-opts:"
echo "    public-key: \"$PUBLIC_KEY\""
echo "    short-id: \"$SHORT_ID\""



echo -e "\nCompact 格式配置（可直接粘贴到 Mihomo proxies 列表中）:"
echo "----------------------------------------------"
echo "- {name: \"$PUBLIC_IP｜Direct｜anytls\", type: anytls, server: $PUBLIC_IP, port: $ANYTLS_PORT, password: \"$ANYTLS_PASSWORD\", skip-cert-verify: true, sni: www.usavps.com, udp: true, tfo: true, tls: true, client-fingerprint: chrome}"
echo "- {name: \"$PUBLIC_IP｜Direct｜hy2\", type: hysteria2, server: $PUBLIC_IP, port: $HY2_PORT, password: \"$HY2_PASSWORD\", udp: true, sni: bing.com, skip-cert-verify: true}"
echo "- {name: \"$PUBLIC_IP｜Direct｜vless\", type: vless, server: $PUBLIC_IP, port: $VLESS_PORT, uuid: \"$VLESS_PASSWORD\", flow: xtls-rprx-vision, tls: true, servername: $VLESS_SNI, skip-cert-verify: true,network: tcp,udp: true, client-fingerprint: chrome,packet-encoding: xudp, reality-opts: {public-key: \"$PUBLIC_KEY\", short-id: \"$SHORT_ID\"}}"
echo "----------------------------------------------"



echo "hysteria2://$HY2_PASSWORD@$PUBLIC_IP:$HY2_PORT?peer=bing.com&insecure=1#$PUBLIC_IP｜Direct｜hy2"

echo "anytls://$ANYTLS_PASSWORD@$PUBLIC_IP:$ANYTLS_PORT?peer=www.usavps.com&insecure=1&fastopen=1&udp=1#$PUBLIC_IP｜Direct｜anytls"

echo "vless://$VLESS_PASSWORD@$PUBLIC_IP:$VLESS_PORT?security=reality&flow=xtls-rprx-vision&pbk=$PUBLIC_KEY&sni=$VLESS_SNI&fp=chrome&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#$PUBLIC_IP｜Direct｜vless"


systemctl restart mihomo.service

echo -e "\n服务状态:"

systemctl status mihomo --no-pager -l

