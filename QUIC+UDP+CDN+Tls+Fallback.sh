#!/bin/bash
set -e

# 输出颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 参数初始化
PORT=$((RANDOM % 7001 + 2000))
UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 16)
SERVER_NAME="www.nvidia.com"
CONFIG_DIR="/etc/tuic"
UPLOAD_BIN="/opt/uploader-linux-amd64"

log "安装 TUIC 节点，端口: $PORT"

# 安装依赖
log "安装依赖环境..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y curl wget sudo unzip jq ufw qrencode net-tools file ca-certificates libc6

# 防止 SSH 断联
log "确保 SSH 端口未被阻断..."
SSH_PORT=22
ufw allow ${PORT}/udp
ufw allow ${SSH_PORT}/tcp
ufw --force enable

# 网络优化
log "应用网络加速参数..."
modprobe tcp_bbr || true
modprobe sch_fq || true

cat >> /etc/sysctl.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p

# 下载 TUIC 二进制（适配新仓库 tuic-protocol/tuic）
log "获取 TUIC 最新版本..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/tuic-protocol/tuic/releases/latest | jq -r '.tag_name')
ARCH=$(uname -m)
case $ARCH in
    x86_64) BIN_NAME="tuic-server-${LATEST_VERSION}-x86_64-unknown-linux-gnu" ;;
    aarch64) BIN_NAME="tuic-server-${LATEST_VERSION}-aarch64-unknown-linux-gnu" ;;
    *) error "不支持的架构: $ARCH"; exit 1 ;;
esac

log "下载 TUIC 二进制文件: $BIN_NAME"
curl -L --fail "https://github.com/tuic-protocol/tuic/releases/download/${LATEST_VERSION}/${BIN_NAME}" -o /usr/local/bin/tuic
chmod +x /usr/local/bin/tuic

# 生成自签 SSL 证书
log "生成 SSL 证书..."
mkdir -p $CONFIG_DIR/tls
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout $CONFIG_DIR/tls/key.key \
  -out $CONFIG_DIR/tls/cert.crt \
  -subj "/CN=${SERVER_NAME}" \
  -addext "subjectAltName=DNS:${SERVER_NAME}"

# TUIC 配置文件生成
log "创建 TUIC 配置文件..."
mkdir -p $CONFIG_DIR
cat > $CONFIG_DIR/config.json <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "users": {
    "${UUID}": "${PSK}"
  },
  "certificate": "$CONFIG_DIR/tls/cert.crt",
  "private_key": "$CONFIG_DIR/tls/key.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "zero_rtt_handshake": true,
  "auth_timeout": "5s",
  "max_idle_time": "60s",
  "max_packet_size": 1500,
  "disable_sni": false,
  "fallback_for_invalid_sni": {
    "enabled": true,
    "address": "www.nvidia.com",
    "port": 443
  },
  "log_level": "info"
}
EOF

# 创建 systemd 服务
log "生成 systemd 服务文件..."
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC QUIC Secure Proxy Server
After=network.target

[Service]
ExecStart=/usr/local/bin/tuic -c $CONFIG_DIR/config.json
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tuic
systemctl restart tuic

# 构建链接
IP=$(curl -s https://api.ipify.org)
ENCODED=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
TUIC_LINK="tuic://${ENCODED}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native&allow_insecure=1#tuic_secure"

log "✅ TUIC 节点部署完成"
echo "链接：$TUIC_LINK"
echo "$TUIC_LINK" | qrencode -o - -t ANSIUTF8
