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

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) BIN_ARCH="amd64" ;;
    aarch64) BIN_ARCH="arm64" ;;
    armv7l) BIN_ARCH="armv7" ;;
    armv6l) BIN_ARCH="armv6" ;;
    *)
        echo "[-] 不支持的架构: $ARCH"
        exit 1
        ;;
esac

CPU_FLAGS=$(grep flags /proc/cpuinfo | head -n1)
if [[ $CPU_FLAGS =~ avx2 ]]; then
    LEVEL="v3"
elif [[ $CPU_FLAGS =~ avx ]]; then
    LEVEL="v2"
else
    LEVEL="v1"
fi

echo "[+] 检测到 架构=$ARCH 可执行=$BIN_ARCH 指令集等级=$LEVEL"

if ! command -v mihomo &>/dev/null; then
    echo "[+] 正在安装 mihomo..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo "[-] 无法获取最新版本号。"
        exit 1
    fi

    if [ "$BIN_ARCH" = "amd64" ]; then
        FILE_NAME="mihomo-linux-${BIN_ARCH}-${LEVEL}-${LATEST_VERSION}.gz"
    else
        FILE_NAME="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
    fi
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}"

    echo "[+] 正在下载 ${FILE_NAME}..."
    if ! wget -O /tmp/mihomo.gz "$DOWNLOAD_URL"; then
        echo "[!] 对应等级的构建下载失败，尝试兼容版本..."
        FILE_NAME="mihomo-linux-${BIN_ARCH}-compatible-${LATEST_VERSION}.gz"
        DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}"
        wget -O /tmp/mihomo.gz "$DOWNLOAD_URL" || {
            echo "[-] 所有下载方式均失败。"
            exit 1
        }
    fi

    gzip -d /tmp/mihomo.gz
    chmod +x /tmp/mihomo
    mv /tmp/mihomo /usr/local/bin/mihomo
    echo "[+] mihomo 安装完成。"
else
    echo "[+] 已检测到 mihomo，跳过安装。"
fi

mkdir -p /root/.config/mihomo/

echo "[+] 生成 SSL 证书..."
openssl req -newkey rsa:2048 -nodes \
  -keyout /root/.config/mihomo/server.key \
  -x509 -days 365 \
  -out /root/.config/mihomo/server.crt \
  -subj "/C=US/ST=CA/L=SF/O=$(openssl rand -hex 8)/CN=$(openssl rand -hex 12)"

echo "[+] 生成 Reality 密钥对..."
REALITY_KEYS=$(mihomo generate reality-keypair)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $2}')
VLESS_SNI="www.apple.com"

echo "[+] 生成 VLESS 后量子密钥 (mlkem768)..."
PQ_KEYS=$(mihomo generate vless-mlkem768)
PQ_SEED=$(echo "$PQ_KEYS" | awk -F': ' '/^Seed:/{print $2}')
PQ_CLIENT=$(echo "$PQ_KEYS" | awk -F': ' '/^Client:/{print $2}')
if [ -n "$PQ_SEED" ] && [ -n "$PQ_CLIENT" ]; then
    VLESS_DECRYPTION="mlkem768x25519plus.native.600s.$PQ_SEED"
    VLESS_ENCRYPTION="mlkem768x25519plus.native.0rtt.$PQ_CLIENT"
fi
# 如果解析失败，使用示例字符串占位，避免空值
if [ -z "$VLESS_DECRYPTION" ] || [ -z "$VLESS_ENCRYPTION" ]; then
    echo "[!] 未能解析后量子密钥，使用示例值（请尽快替换为实际生成的密钥）"
    VLESS_DECRYPTION="mlkem768x25519plus.native.600s.csJ8f1xrtBp09v6_TiKIO_fEhBt6jz7BJ4G1XUBUidfHUrGbaONgZvGkDL-tsuDElGTgTRDsrTOzBWbdX4Mnlw"
    VLESS_ENCRYPTION="mlkem768x25519plus.native.0rtt.3qdg7VMCRGYf97oh-eRj4iWOIRGJ4IIKa5oAxSud0FpXqkoL85efWOg-4oSQ0HKRd1l_gvmKW_sqgAdiLlA2QCSBMPA9n2MwhOu_7LS87SWROrxkW-OQ-MUcLcVP5VQTHTQBOONdWndpi4cEfIYp2TqarQGnwBUg5LNcSwOTNuMgNWpiyNeSDdkpv3wDRyspCrOhHbI9nxqImRIid6EXDEa5EjmcvJHLAJcUKJQi77hAdRtlgig2AoGnQnhTD5eHSwuS_4ysvfCr-2wlWZMVNUsZx_m4W2lUFpwAWWtYujZTwYwygHqSHgO_l2y0_6w1-ghcnLO8WVQcrdXGiURy2NTOXmkKfaAkEQN6lIgV8xlpzGhC_RFyXtw4uDoqNsIIsWghXRgVfMZy3INe5qZLtcQ5M0JLONbB5hW_cjujsPsXvcm-eIRXxTEUOzkjpKObcTo62hCF_jMAmQCZYvu9kArAdqYjwVi41SwdTTBF2uHEDwlSXCtk7FzKdRpejxiSitdP6SYSYeuXsaxWZKejBSx3RNI-OftU3BG3oSI4SWOUm3mMnyNP7meQc9p7s8tVssY7M6sKSDQdQfSbpPh--ouCrjIda1ixo7ZaGxK4BxRAyRMaHZcQcal5GESXbiy7G9UjD4N0UCLCWzCU_Bh8o5en1eihzZBMHpt6P0dKYXQaI6aYyfpppuuOGsdI5RZBYkll2NISz2lCKmIRR5qHOgUVigV0ApldgPMqYHOLkHctSdtqHgRqgZkG2VjNUQQFfbO9epqilPEtu5OLB3VaOGJwEyAQEQt2LhrJH0t3F3XCMYoauyGGGMF0DdAYPwiHc-wWxQUSrDeWUCdZ3FrGDzEpvfEzrPEUOJKKXPqQHTWKR8PDxbjCuqxr-8qYGJiXnqt_cYohqZdl6jSQ-1WZoId8S1Sz6pYh_kGC4hCSk2S5wwRFvOWNKEHDhCfPmBIX8VdrKowCuKYFQLylxClUwfsRjUozV3J40cqkmKleGtBKP8yepLkgTFmLNRJ4-qIdArN_VaiLyxlbXONT8jAQOsduJHoYB_EumQdFxdB61aOevyxhxncVHOpFf_wXnQuk-AKsPRsCksfC2anCeIFzavuKrOylPWaf03eZOKBRB7KuOeNo42Oru_FA_-DBvukY25XBm9XNWmlW6hhFAoAzambFnvW1PbVUv_uz6jFPLpVzjtSrQuyWjdKUQPKwoKFuNDhxRzdEFrG6ecg9o8wg9Pyk3NyId3TEToAM5hxUPYxkFUoc0eWGwFtX6Iksimahl8xeKfCtzSUkZpk017GCstnIDwAfomVrieKf9lOXQBCNT2ZECZempsQ9oIXAwVgNzvrJFruq44E8bGu_80dEj6ujOEkQllBPPKsw7QBoUExix9yZCVll3zqo_nIgdZQR48QEkxen_WVszDigahUvHPa5wiE2jJZlCAE0thzAwZIf96rH_bk09LZO9kISwqxWa7ab1JMpWmlYAxcOB9gEzIF00pxXBfa0lEWb6ITCDbVf6AeadSdbcPhIS7RjbdcWlJBDBrT-S46HfIcM3lWcgFeAjeyyx8raG8MaMN2rwQA"
fi

VLESS_PASSWORD=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)
VLESS_PORT=$(random_free_port)

cat > /root/.config/mihomo/config.yaml <<EOF
listeners:
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
  decryption: "$VLESS_DECRYPTION"
  reality-config:
    dest: "$VLESS_SNI:443"
    private-key: "$PRIVATE_KEY"
    short-id:
      - "$SHORT_ID"
    server-names:
      - "$VLESS_SNI"
EOF

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
    echo "[!] 服务启动失败，请运行: journalctl -u mihomo -xe"
}

PUBLIC_IP=$(curl -4 -s ifconfig.me || echo "YOUR_PUBLIC_IP")

echo "\nVLESS Reality 客户端配置 (含后量子加密):"
echo "=============================================="
echo "- name: ${PUBLIC_IP}|Direct|vless"
echo "  type: vless"
echo "  server: $PUBLIC_IP"
echo "  port: $VLESS_PORT"
echo "  uuid: $VLESS_PASSWORD"
echo "  flow: xtls-rprx-vision"
echo "  tls: true"
echo "  servername: $VLESS_SNI"
echo "  client-fingerprint: chrome"
echo "  network: tcp"
echo "  udp: true"
echo "  packet-encoding: xudp"
echo "  encryption: \"$VLESS_ENCRYPTION\"  # 出站（客户端）使用"
echo "  reality-opts:"
echo "    public-key: \"$PUBLIC_KEY\""
echo "    short-id: \"$SHORT_ID\""
echo "=============================================="

echo "vless://$VLESS_PASSWORD@$PUBLIC_IP:$VLESS_PORT?security=reality&flow=xtls-rprx-vision&pbk=$PUBLIC_KEY&sni=$VLESS_SNI&fp=chrome&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision&encryption=$VLESS_ENCRYPTION#${PUBLIC_IP}|Direct|vless"
echo "=============================================="
echo -e "\nCompact 格式配置（可直接粘贴到 Mihomo proxies 列表中）:"
echo "- {name: \"$PUBLIC_IP|Direct|vless\", type: vless, server: $PUBLIC_IP, port: $VLESS_PORT, uuid: "$VLESS_PASSWORD", flow: xtls-rprx-vision, tls: true, servername: $VLESS_SNI, skip-cert-verify: true, network: tcp, udp: true, packet-encoding: xudp, decryption: "$VLESS_DECRYPTION", encryption: "$VLESS_ENCRYPTION", reality-opts: {public-key: "$PUBLIC_KEY", short-id: "$SHORT_ID"}}"


systemctl restart mihomo.service

echo -e "\n服务状态:"
systemctl status mihomo --no-pager -l
