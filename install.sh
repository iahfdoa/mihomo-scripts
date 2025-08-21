#!/usr/bin/env bash

# 安装必要依赖
install_dependencies() {
    echo "正在安装必要依赖..."
    
    # 检测包管理器并安装依赖
    if command -v apt &> /dev/null; then
        apt update -y
        apt install -y curl openssl wget gzip ufw
    elif command -v yum &> /dev/null; then
        yum install -y curl openssl wget gzip
        # 检查是否是RHEL/CentOS 8+
        if grep -q 'release 8' /etc/redhat-release || grep -q 'release 9' /etc/redhat-release; then
            dnf install -y tar
        fi
    elif command -v dnf &> /dev/null; then
        dnf install -y curl openssl wget gzip
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm curl openssl wget gzip
    elif command -v apk &> /dev/null; then
        apk add --no-cache curl openssl wget gzip
    else
        echo "无法确定包管理器，请手动安装依赖: curl, openssl, wget, gzip"
        exit 1
    fi
    
    # 检查是否安装成功
    for cmd in curl openssl wget gzip; do
        if ! command -v $cmd &> /dev/null; then
            echo "依赖安装失败: $cmd 未找到"
            exit 1
        fi
    done
}

# 检查并安装依赖
for cmd in curl openssl wget gzip; do
    if ! command -v $cmd &> /dev/null; then
        install_dependencies
        break
    fi
done

# 创建目录
mkdir -p /root/.config/mihomo/

# 检查mihomo是否已安装
if ! command -v mihomo &> /dev/null; then
    echo "未检测到mihomo安装，开始安装..."
    # 获取系统架构
    ARCH=$(uname -m)
    case $ARCH in
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
            echo "不支持的架构: $ARCH"
            exit 1
            ;;
    esac

    # 获取最新版本号
    LATEST_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') || {
        echo "获取最新版本失败"
        exit 1
    }

    # 下载对应版本的二进制文件
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
    echo "正在下载: $DOWNLOAD_URL"
    wget -O /tmp/mihomo.gz "$DOWNLOAD_URL" || {
        echo "下载失败"
        exit 1
    }

    # 解压并安装
    gzip -d /tmp/mihomo.gz || {
        echo "解压失败"
        exit 1
    }
    chmod +x /tmp/mihomo
    mv /tmp/mihomo /usr/local/bin/mihomo || {
        echo "移动文件失败"
        exit 1
    }
    # 修改 用户 权限

    echo "mihomo安装完成"
else
    echo "检测到mihomo已安装，跳过安装步骤"
fi

# 强制重新生成随机证书
echo "生成新的SSL证书..."
openssl req -newkey rsa:2048 -nodes -keyout /root/.config/mihomo/server.key -x509 -days 365 -out /root/.config/mihomo/server.crt -subj "/C=US/ST=California/L=San Francisco/O=$(openssl rand -hex 8)/CN=$(openssl rand -hex 12)" || {
    echo "生成证书失败"
    exit 1
}

# 强制重新生成随机密码和配置文件
echo "生成新的随机配置..."
HY2_PASSWORD=$(uuidgen) || {
    echo "生成UUID失败"
    exit 1
}
ANYTLS_PASSWORD=$(uuidgen) || {
    echo "生成UUID失败"
    exit 1
}

# 生成随机端口 (20000-60000范围内)
HY2_PORT=$((RANDOM % 40001 + 20000))
ANYTLS_PORT=$((RANDOM % 40001 + 20000))

# 确保两个端口不同
while [ "$HY2_PORT" -eq "$ANYTLS_PORT" ]; do
    ANYTLS_PORT=$((RANDOM % 40001 + 20000))
done

# 生成新的配置文件（覆盖旧配置）
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
  padding-scheme: |
   stop=8
   0=30-30
   1=100-400
   2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
   3=9-9,500-1000
   4=400-1000
   5=400-1000
   6=400-1000
   7=300-1000
- name: hy2
  type: hysteria2
  port: $HY2_PORT
  listen: 0.0.0.0
  users:
    user1: $HY2_PASSWORD
  ignore-client-bandwidth: false
  alpn:
  - h3
  certificate: ./server.crt
  private-key: ./server.key
EOF

# 确保systemd目录存在
mkdir -p /etc/systemd/system/

# 生成systemd服务文件（覆盖旧配置）
cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Service
After=network.target

[Service]
Type=simple
ExecStart=mihomo
Restart=on-failure
RestartSec=3
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# 重新加载systemd
systemctl daemon-reload || {
    echo "daemon-reload失败"
    exit 1
}

# 重启服务以应用新配置
systemctl restart mihomo.service || {
    echo "重启服务失败"
    exit 1
}

# 获取公网IP
PUBLIC_IP=$(curl -s cip.cc | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n 1) || PUBLIC_IP="你的服务器IP"

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

echo "hysteria2://$HY2_PASSWORD@$PUBLIC_IP:$HY2_PORT?peer=bing.com&insecure=1#$PUBLIC_IP｜Direct｜hy2"

echo "anytls://$ANYTLS_PASSWORD@$PUBLIC_IP:$ANYTLS_PORT?peer=www.usavps.com&insecure=1&fastopen=1&udp=1#$PUBLIC_IP｜Direct｜anytls"

echo -e "\n服务状态:"
systemctl status mihomo --no-pager -l
