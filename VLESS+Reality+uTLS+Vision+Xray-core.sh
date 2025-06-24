#!/bin/bash

set -e

# 配置默认值
CORE="xray"
PROTOCOL="vless"
DOMAIN="www.nvidia.com"
UUID=$(cat /proc/sys/kernel/random/uuid)
USER=$(openssl rand -hex 4)
VISION_SHORT_ID=$(openssl rand -hex 4)
PORT=$((RANDOM % 7001 + 2000))

# 安装必要依赖
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y curl unzip ufw jq qrencode

# 设置防火墙并开放端口
ufw allow ${PORT}/tcp
ufw --force enable

# 下载并安装 Xray-core 最新版本
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
unzip -o xray.zip
chmod +x xray
rm -f xray.zip

# 生成 Reality 密钥对
REALITY_KEYS=$(/usr/local/bin/xray x25519)
REALITY_PRIVATE_KEY=$(echo "${REALITY_KEYS}" | grep "Private key" | awk '{print $3}')
REALITY_PUBLIC_KEY=$(echo "${REALITY_KEYS}" | grep "Public key" | awk '{print $3}')

# 写入配置文件
mkdir -p /etc/xray
cat > /etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [{
    "port": ${PORT},
    "protocol": "${PROTOCOL}",
    "settings": {
      "clients": [{
        "id": "${UUID}",
        "flow": "xtls-rprx-vision",
        "email": "${USER}"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${DOMAIN}:443",
        "xver": 0,
        "serverNames": ["${DOMAIN}"],
        "privateKey": "${REALITY_PRIVATE_KEY}",
        "shortIds": ["${VISION_SHORT_ID}"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# 配置 systemd 服务
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray -config /etc/xray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 获取本机公网 IP
NODE_IP=$(curl -s https://api.ipify.org)

# 生成 VLESS Reality 节点链接
VLESS_LINK="vless://${UUID}@${NODE_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${VISION_SHORT_ID}&type=tcp#${USER}"

# 输出信息与二维码（中文）
echo -e "\n\033[1;32m🎉 VLESS Reality 节点已成功搭建！以下是您的配置信息：\033[0m\n"
echo -e "🔗 节点链接（支持 v2rayN / v2box 直接导入）：\n${VLESS_LINK}\n"
echo -e "📱 节点二维码（终端扫码）："
echo "${VLESS_LINK}" | qrencode -o - -t ANSIUTF8
echo ""
