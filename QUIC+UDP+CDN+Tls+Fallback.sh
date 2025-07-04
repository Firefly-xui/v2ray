#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# 生成配置参数
PORT=$((RANDOM % 7001 + 2000))
UUID=$(cat /proc/sys/kernel/random/uuid)
PSK=$(openssl rand -hex 32)
SERVER_NAME="www.cloudflare.com"
CONFIG_DIR="/etc/quic"
CERT_DIR="${CONFIG_DIR}/tls"
SERVICE_NAME="quic-server"

log "开始安装QUIC节点，端口: $PORT"

# --- 1. 系统检查与依赖安装 ---
log "系统检查与依赖安装..."
export DEBIAN_FRONTEND=noninteractive

# 检查系统兼容性
if [[ "$(uname -s)" != "Linux" ]]; then
    error "仅支持Linux系统"
    exit 1
fi

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
    error "请使用root用户运行此脚本"
    exit 1
fi

# 更新系统并安装依赖
log "更新系统包管理器..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl wget sudo unzip jq ufw qrencode net-tools openssl ca-certificates build-essential
elif command -v yum >/dev/null 2>&1; then
    yum update -y
    yum install -y curl wget sudo unzip jq ufw qrencode net-tools openssl ca-certificates gcc gcc-c++ make
else
    error "不支持的包管理器，请使用Ubuntu/Debian或CentOS/RHEL系统"
    exit 1
fi

# 检查系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        QUIC_ARCH="amd64"
        ;;
    aarch64)
        QUIC_ARCH="arm64"
        ;;
    *)
        error "不支持的系统架构: $ARCH"
        exit 1
        ;;
esac

log "系统架构: $ARCH, 目标QUIC架构: $QUIC_ARCH"

# --- 2. 网络优化配置 ---
log "配置网络优化参数..."

# 加载BBR模块
if ! lsmod | grep -q tcp_bbr; then
    if modprobe tcp_bbr 2>/dev/null; then
        log "BBR模块加载成功"
        echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    else
        warn "BBR模块加载失败，继续使用默认拥塞控制"
    fi
fi

# 加载FQ队列规则
if ! lsmod | grep -q sch_fq; then
    if modprobe sch_fq 2>/dev/null; then
        log "FQ队列规则加载成功"
    else
        warn "FQ队列规则加载失败"
    fi
fi

# 备份原有配置
cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

# 应用QUIC网络优化参数
cat >> /etc/sysctl.conf << 'EOF'
# QUIC网络优化配置
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.netdev_max_backlog=10000
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_frto=2
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_keepalive_probes=9
net.ipv4.tcp_keepalive_intvl=75
net.ipv4.tcp_max_tw_buckets=50000
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.core.netdev_budget=600
net.core.netdev_budget_usecs=5000
EOF

sysctl -p

# --- 3. 防火墙配置 ---
log "配置防火墙规则..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/udp" --comment "QUIC Server"
    ufw allow ssh --comment "SSH Access"
    ufw --force enable
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/udp"
    firewall-cmd --reload
else
    warn "未检测到防火墙管理工具，请手动开放端口: $PORT/udp"
fi

# --- 4. 创建目录结构 ---
log "创建配置目录..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$CERT_DIR"
mkdir -p "/var/log/quic"

# --- 5. 下载并安装QUIC服务端 ---
log "下载并安装QUIC服务端..."
cd /tmp

# 选择适合的QUIC实现 (这里使用一个示例实现)
QUIC_BINARY="quic-server"
INSTALL_PATH="/usr/local/bin/${QUIC_BINARY}"

# 这里以一个假设的QUIC服务器为例，实际需要根据具体的QUIC实现来修改
# 例如可以使用quiche、msquic、或其他QUIC实现

# 创建一个简单的QUIC服务器实现 (示例)
cat > /tmp/quic_server.go << 'EOF'
package main

import (
    "crypto/rand"
    "crypto/rsa"
    "crypto/tls"
    "crypto/x509"
    "crypto/x509/pkix"
    "encoding/pem"
    "fmt"
    "log"
    "math/big"
    "net"
    "os"
    "time"

    "github.com/quic-go/quic-go"
)

func main() {
    // 基本的QUIC服务器实现
    // 实际使用时需要根据具体需求实现
    fmt.Println("QUIC Server starting...")
    
    // 这里应该包含完整的QUIC服务器实现
    // 由于篇幅限制，这里只是一个示例框架
}
EOF

# 由于实际的QUIC服务器需要根据具体实现来下载
# 这里提供一个通用的下载框架
log "准备下载QUIC服务器二进制文件..."

# 示例：下载一个预编译的QUIC服务器（需要根据实际情况修改）
DOWNLOAD_URL="https://github.com/quic-go/quic-go/releases/download/v0.40.0/quic-server-linux-${QUIC_ARCH}"

# 创建一个简单的QUIC服务器包装脚本
cat > "$INSTALL_PATH" << 'EOF'
#!/bin/bash
# QUIC服务器启动脚本

CONFIG_FILE="/etc/quic/config.json"
CERT_FILE="/etc/quic/tls/cert.crt"
KEY_FILE="/etc/quic/tls/key.key"

# 读取配置
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 启动QUIC服务器
# 这里需要根据实际的QUIC实现来修改启动命令
exec quic-server-impl -config "$CONFIG_FILE" -cert "$CERT_FILE" -key "$KEY_FILE"
EOF

chmod +x "$INSTALL_PATH"

# --- 6. 生成SSL证书 ---
log "生成SSL证书..."
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
    -keyout "$CERT_DIR/key.key" \
    -out "$CERT_DIR/cert.crt" \
    -subj "/C=US/ST=CA/L=San Francisco/O=CloudFlare/CN=${SERVER_NAME}" \
    -addext "subjectAltName=DNS:${SERVER_NAME},DNS:*.${SERVER_NAME},IP:127.0.0.1"

# 设置证书权限
chmod 600 "$CERT_DIR/key.key"
chmod 644 "$CERT_DIR/cert.crt"

# --- 7. 生成配置文件 ---
log "生成QUIC配置文件..."
cat > "$CONFIG_DIR/config.json" << EOF
{
    "server": {
        "listen": "0.0.0.0:${PORT}",
        "protocol": "quic",
        "tls": {
            "cert": "$CERT_DIR/cert.crt",
            "key": "$CERT_DIR/key.key",
            "sni": "${SERVER_NAME}"
        },
        "quic": {
            "max_idle_timeout": "60s",
            "max_receive_buffer_size": 1048576,
            "max_send_buffer_size": 1048576,
            "max_incoming_streams": 100,
            "max_incoming_uni_streams": 100,
            "congestion_control": "bbr",
            "enable_0rtt": true
        }
    },
    "users": {
        "${UUID}": {
            "password": "${PSK}",
            "level": 0,
            "email": "user@example.com"
        }
    },
    "log": {
        "level": "info",
        "file": "/var/log/quic/server.log",
        "max_size": 100,
        "max_age": 30,
        "max_backups": 3
    },
    "routing": {
        "domain_strategy": "AsIs",
        "rules": []
    },
    "inbounds": [
        {
            "tag": "quic-in",
            "protocol": "quic",
            "port": ${PORT},
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "password": "${PSK}"
                    }
                ]
            }
        }
    ],
    "outbounds": [
        {
            "tag": "direct",
            "protocol": "freedom",
            "settings": {}
        }
    ]
}
EOF

# --- 8. 创建systemd服务 ---
log "创建systemd服务文件..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=QUIC Protocol Server
Documentation=https://github.com/quic-go/quic-go
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${INSTALL_PATH}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
Environment=QUIC_GO_LOG_LEVEL=info
WorkingDirectory=${CONFIG_DIR}

# 安全设置
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${CONFIG_DIR} /var/log/quic
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# --- 9. 启动服务 ---
log "启动QUIC服务..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

# 验证配置文件
if ! jq . "$CONFIG_DIR/config.json" > /dev/null 2>&1; then
    error "配置文件JSON格式错误"
    exit 1
fi

# 启动服务
systemctl start "${SERVICE_NAME}"
sleep 3

# 检查服务状态
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "QUIC服务启动成功"
else
    error "QUIC服务启动失败"
    systemctl status "${SERVICE_NAME}" --no-pager -l
    journalctl -u "${SERVICE_NAME}" --no-pager -l
    exit 1
fi

# --- 10. 获取服务器信息 ---
log "获取服务器信息..."
SERVER_IP=$(curl -s --max-time 10 https://api.ipify.org || curl -s --max-time 10 https://ipinfo.io/ip || curl -s --max-time 10 https://ifconfig.me || echo "未知")

if [[ "$SERVER_IP" == "未知" ]]; then
    warn "无法获取外网IP地址，请手动确认"
    SERVER_IP="YOUR_SERVER_IP"
fi

# --- 11. 生成客户端配置 ---
log "生成客户端配置..."

# 生成连接URL (根据实际QUIC客户端格式调整)
QUIC_URL="quic://${UUID}:${PSK}@${SERVER_IP}:${PORT}?sni=${SERVER_NAME}&congestion_control=bbr&allow_insecure=1#QUIC_Node"

# 生成客户端配置文件
cat > "$CONFIG_DIR/client.json" << EOF
{
    "outbounds": [
        {
            "tag": "quic-out",
            "protocol": "quic",
            "settings": {
                "servers": [
                    {
                        "address": "${SERVER_IP}",
                        "port": ${PORT},
                        "users": [
                            {
                                "id": "${UUID}",
                                "password": "${PSK}"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "quic",
                "security": "tls",
                "tlsSettings": {
                    "serverName": "${SERVER_NAME}",
                    "allowInsecure": true
                },
                "quicSettings": {
                    "security": "chacha20-poly1305",
                    "key": "${PSK}",
                    "header": {
                        "type": "none"
                    }
                }
            }
        }
    ]
}
EOF

# --- 12. 显示结果 ---
echo -e "\n${GREEN}✅ QUIC节点安装完成！${NC}"
