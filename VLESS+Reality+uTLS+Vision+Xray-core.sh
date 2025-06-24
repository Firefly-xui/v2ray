#!/bin/bash

set -e

# 默认参数
CORE="xray"
PROTOCOL="vless"
DOMAIN="www.nvidia.com"
PORT=2000
UUID=$(cat /proc/sys/kernel/random/uuid)
USER=$(openssl rand -hex 4)
REALITY_PUBLIC_KEY=""
REALITY_PRIVATE_KEY=""
VISION_SHORT_ID=$(openssl rand -hex 4)

# 安装依赖
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y curl unzip ufw jq

# 防火墙配置
ufw allow ${PORT}/tcp
ufw --force enable

# 安装 sing-box 或 xray-core
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
unzip -o xray.zip
chmod +x xray
rm -f xray.zip

# 生成 Reality 密钥对
REALITY_KEY=$(./xray x25519)
REALITY_PRIVATE_KEY=$(echo "$REALITY_KEY" | grep "Private key:" | awk '{print $3}')
REALITY_PUBLIC_KEY=$(echo "$REALITY_KEY" | grep "Public key:" | awk '{print $3}')

# 生成配置文件
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

# 启动服务
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

# 输出节点信息
echo ""
echo "🎉 已成功搭建 VLESS + Reality + uTLS + Vision 节点！以下是你的配置信息："
echo ""
echo "地址：$(curl -s https://api.ipify.org)"
echo "端口：${PORT}"
echo "UUID：${UUID}"
echo "用户名（email）：${USER}"
echo "伪装域名：${DOMAIN}"
echo "Reality 公钥：${REALITY_PUBLIC_KEY}"
echo "短 ID：${VISION_SHORT_ID}"
echo "传输协议：tcp + reality"
echo "flow：xtls-rprx-vision"
echo ""
echo "✅ 请将上述信息导入支持 Reality 的客户端使用"

