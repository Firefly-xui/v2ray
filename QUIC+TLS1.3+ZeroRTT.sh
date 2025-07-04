#!/bin/bash
set -e

# 彩色日志
GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }

# 自动参数
UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 16)
PORT=$((RANDOM % 1000 + 30000))
SERVER_NAME="www.nvidia.com"
CONFIG_DIR="/etc/tuic"
BIN_PATH="/usr/local/bin/tuic"
ARCH=$(uname -m)
UPLOAD_BIN="/opt/uploader-linux-amd64"

# 判断架构
case "$ARCH" in
  x86_64) TUIC_BIN="tuic-server-x86_64-unknown-linux-gnu" ;;
  aarch64) TUIC_BIN="tuic-server-aarch64-unknown-linux-gnu" ;;
  *) err "不支持的架构: $ARCH" && exit 1 ;;
esac

log "安装依赖..."
apt update
apt install -y curl wget unzip jq qrencode sudo net-tools ufw openssl

log "创建目录: $CONFIG_DIR"
mkdir -p "$CONFIG_DIR/tls"

log "下载 TUIC v5 二进制..."
cd /usr/local/bin
rm -f tuic
curl -Lo tuic "https://github.com/EAimTY/tuic/releases/latest/download/${TUIC_BIN}"
chmod +x tuic

log "验证 TUIC 是否可执行..."
if ! ./tuic --version >/dev/null 2>&1; then
  err "下载失败或二进制无效"
  exit 1
fi

log "生成自签名证书..."
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "$CONFIG_DIR/tls/key.key" \
  -out "$CONFIG_DIR/tls/cert.crt" \
  -subj "/C=US/ST=CA/L=SanFrancisco/O=bing/CN=${SERVER_NAME}" \
  -addext "subjectAltName=DNS:${SERVER_NAME}"

chmod 600 "$CONFIG_DIR/tls/key.key"
chmod 644 "$CONFIG_DIR/tls/cert.crt"

log "生成 TUIC 配置文件..."
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "server": "0.0.0.0",
  "server_port": $PORT,
  "users": {
    "$UUID": "$PSK"
  },
  "certificate": "$CONFIG_DIR/tls/cert.crt",
  "private_key": "$CONFIG_DIR/tls/key.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_ipv6": false,
  "zero_rtt_handshake": true,
  "auth_timeout": "5s",
  "max_idle_time": "60s",
  "max_packet_size": 1500,
  "disable_sni": false,
  "fallback_for_invalid_sni": {
    "enabled": true,
    "address": "www.bing.com",
    "port": 443
  },
  "log_level": "info"
}
EOF

log "配置 systemd 服务..."
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC QUIC Secure Proxy Server
After=network.target

[Service]
ExecStart=$BIN_PATH -c $CONFIG_DIR/config.json
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tuic
systemctl restart tuic
sleep 2

if systemctl is-active --quiet tuic; then
  log "TUIC 启动成功 ✅"
else
  err "TUIC 启动失败 ❌"
  journalctl -u tuic -n 20 --no-pager
  exit 1
fi

log "开启防火墙端口..."
ufw allow "$PORT/udp"
ufw allow ssh
ufw --force enable

log "获取外网 IP..."
IP=$(curl -s https://api.ipify.org)

log "生成 TUIC 配置链接（用于客户端）"
BASE64_CRED=$(echo -n "$UUID:$PSK" | base64 -w 0)
TUIC_LINK="tuic://${BASE64_CRED}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native&allow_insecure=1#tuic_v5"

echo -e "\n${GREEN}✅ TUIC v5 安装完成！配置如下：${NC}"
echo -e "${GREEN}地址: ${NC}${IP}"
echo -e "${GREEN}端口: ${NC}${PORT}"
echo -e "${GREEN}UUID : ${NC}${UUID}"
echo -e "${GREEN}PSK  : ${NC}${PSK}"
echo -e "${GREEN}链接 : ${NC}${TUIC_LINK}"
echo -e "\n${GREEN}二维码:${NC}"
echo "$TUIC_LINK" | qrencode -o - -t ANSIUTF8
