#!/usr/bin/env bash
set -euo pipefail

# ---------- 彩色日志 ----------
GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[1;33m"; NC="\033[0m"
log(){  echo -e "${GREEN}[INFO ]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN ]${NC} $*"; }
err(){  echo -e "${RED}[ERROR]${NC} $*" ; exit 1; }

# ---------- 自动参数 ----------
UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 16)
PORT=$((RANDOM%7001+2000))  # 2000-9000 随机端口
SERVER_NAME="www.bing.com"
CFG_DIR="/etc/tuic"; TLS_DIR="$CFG_DIR/tls"
BIN_DIR="/usr/local/bin"; BIN_LINK="$BIN_DIR/tuic"

# ---------- 安装依赖 ----------
log "安装依赖..."
apt update -y
apt install -y curl wget jq qrencode ufw openssl net-tools

# ---------- 获取架构 ----------
case "$(uname -m)" in
  x86_64)  ARCH_TAIL="x86_64-unknown-linux-gnu"  ;;
  aarch64) ARCH_TAIL="aarch64-unknown-linux-gnu" ;;
  *) err "暂不支持的架构: $(uname -m)" ;;
esac

# ---------- 获取最新版本 ----------
TAG_JSON=$(curl -s https://api.github.com/repos/EAimTY/tuic/releases/latest)
TAG_NAME=$(echo "$TAG_JSON" | jq -r '.tag_name')
VERSION=${TAG_NAME#tuic-server-}
BIN_NAME="tuic-server-${VERSION}-${ARCH_TAIL}"

log "最新版本: ${VERSION}"
log "目标文件: ${BIN_NAME}"

# ---------- 下载并校验 ----------
cd "$BIN_DIR"; rm -f tuic "$BIN_NAME" "${BIN_NAME}.sha256sum"

URL_BASE="https://github.com/EAimTY/tuic/releases/download/${TAG_NAME}"
curl -L --fail -o "$BIN_NAME"             "$URL_BASE/$BIN_NAME"
curl -L --fail -o "${BIN_NAME}.sha256sum" "$URL_BASE/${BIN_NAME}.sha256sum"

sha256sum -c "${BIN_NAME}.sha256sum" || err "SHA256 校验失败"
chmod +x "$BIN_NAME"
ln -sf "$BIN_DIR/$BIN_NAME" "$BIN_LINK"

# ---------- TLS 证书 ----------
log "生成自签名证书..."
mkdir -p "$TLS_DIR"
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "$TLS_DIR/key.key" -out "$TLS_DIR/cert.crt" \
  -subj "/C=US/ST=CA/L=SanFrancisco/O=bing/CN=${SERVER_NAME}" \
  -addext "subjectAltName=DNS:${SERVER_NAME}"
chmod 600 "$TLS_DIR/key.key"
chmod 644 "$TLS_DIR/cert.crt"

# ---------- 写入配置文件 ----------
log "写入 tuic 配置..."
mkdir -p "$CFG_DIR"
cat > "$CFG_DIR/config.json" <<EOF
{
  "server": "0.0.0.0",
  "server_port": $PORT,
  "users": { "$UUID": "$PSK" },
  "certificate": "$TLS_DIR/cert.crt",
  "private_key": "$TLS_DIR/key.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "zero_rtt_handshake": true,
  "fallback_for_invalid_sni": {
    "enabled": true,
    "address": "www.bing.com",
    "port": 443
  },
  "log_level": "info"
}
EOF

# ---------- systemd 服务 ----------
log "创建 systemd 服务..."
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC v5 Server
After=network.target

[Service]
ExecStart=$BIN_LINK -c $CFG_DIR/config.json
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tuic

# ---------- 检查运行状态 ----------
sleep 2
if systemctl is-active --quiet tuic; then
  log "TUIC 启动成功 ✅"
else
  err "TUIC 启动失败，查看日志：journalctl -u tuic -n 30"
fi

# ---------- 防火墙 ----------
log "配置防火墙规则..."
ufw allow ssh
ufw allow ${PORT}/udp
ufw --force enable

# ---------- 输出连接信息 ----------
IP=$(curl -s https://api.ipify.org)
ENCODE=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
LINK="tuic://${ENCODE}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native&allow_insecure=1#tuic_v5"

echo -e "\n${GREEN}✅ TUIC v5 安装完成${NC}"
echo -e "${GREEN}外网地址:${NC} $IP"
echo -e "${GREEN}端口     :${NC} $PORT"
echo -e "${GREEN}UUID     :${NC} $UUID"
echo -e "${GREEN}密钥     :${NC} $PSK"
echo -e "${GREEN}链接     :${NC} $LINK"
echo -e "\n${GREEN}二维码:${NC}"
echo "$LINK" | qrencode -o - -t ANSIUTF8
