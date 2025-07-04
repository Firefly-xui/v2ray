#!/bin/bash
set -e

PORT=443
UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 16)
SNI="www.nvidia.com"
CONFIG_DIR="/etc/tuic"

log() {
    echo -e "\033[1;32m[$(date '+%H:%M:%S')]\033[0m $1"
}

# 安装 Docker（如未安装）
if ! command -v docker &>/dev/null; then
    log "正在安装 Docker..."
    curl -fsSL https://get.docker.com | bash
else
    log "Docker 已安装"
fi

# 配置目录准备
log "创建配置目录: $CONFIG_DIR"
mkdir -p $CONFIG_DIR

# TLS 证书生成（自签）
log "生成自签 TLS 证书..."
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout ${CONFIG_DIR}/key.key \
  -out ${CONFIG_DIR}/cert.crt \
  -subj "/CN=${SNI}"

# 生成 TUIC 配置文件
log "写入配置文件..."
cat > ${CONFIG_DIR}/config.json <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "users": {
    "${UUID}": "${PSK}"
  },
  "certificate": "/etc/tuic/cert.crt",
  "private_key": "/etc/tuic/key.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "zero_rtt_handshake": true,
  "auth_timeout": "5s",
  "max_idle_time": "60s",
  "max_packet_size": 1500,
  "disable_sni": false,
  "fallback_for_invalid_sni": {
    "enabled": true,
    "address": "${SNI}",
    "port": 443
  },
  "log_level": "info"
}
EOF

# 启动 TUIC 容器
log "启动 TUIC 容器..."
docker run -d --name tuic-server --restart unless-stopped \
  -p ${PORT}:${PORT}/udp \
  -v ${CONFIG_DIR}:/etc/tuic \
  ghcr.io/itsusinn/tuic-server:latest \
  -c /etc/tuic/config.json

# 构建 TUIC 链接
IP=$(curl -s https://api.ipify.org)
ENCODED=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
TUIC_LINK="tuic://${ENCODED}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SNI}&udp_relay_mode=native#tuic_nvidia"

log "✅ TUIC 节点部署完成"
echo -e "\nTuic 链接：$TUIC_LINK"
echo "$TUIC_LINK" | qrencode -o - -t ANSIUTF8
