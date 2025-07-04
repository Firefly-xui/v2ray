#!/usr/bin/env python3
import os
import random
import json
import subprocess
import sys
import uuid
from datetime import datetime
import ssl

# 检查root权限
if os.geteuid() != 0:
    print("请使用root权限运行此脚本")
    sys.exit(1)

# 安装必要依赖
def install_dependencies():
    dependencies = ['nginx', 'openssl', 'uuid-runtime']
    print("正在安装必要依赖...")
    subprocess.run(['apt', 'update'], check=True)
    subprocess.run(['apt', 'install', '-y'] + dependencies, check=True)

# 生成随机端口范围
def generate_ports():
    start_port = random.randint(2000, 9000)
    return list(range(start_port, start_port + 1000))

# 生成自签名证书
def generate_self_signed_cert():
    cert_dir = "/etc/ssl/private"
    os.makedirs(cert_dir, exist_ok=True)
    
    key_path = os.path.join(cert_dir, "selfsigned.key")
    cert_path = os.path.join(cert_dir, "selfsigned.crt")
    
    if not os.path.exists(key_path) or not os.path.exists(cert_path):
        print("正在生成自签名证书...")
        subprocess.run([
            "openssl", "req", "-x509", "-nodes", "-days", "365", 
            "-newkey", "rsa:2048", "-keyout", key_path, 
            "-out", cert_path, "-subj", "/CN=localhost"
        ], check=True)
    
    return cert_path, key_path

# 生成Hysteria2配置
def generate_hysteria_config(ports, cert_path, key_path):
    config = {
        "listen": ":443",
        "tls": {
            "cert": cert_path,
            "key": key_path
        },
        "obfs": {
            "type": "salamander",
            "salamander": {
                "password": str(uuid.uuid4())
            }
        },
        "auth": {
            "type": "password",
            "password": str(uuid.uuid4())
        },
        "bandwidth": {
            "up": "0",  # 0表示无限制，使用服务器实际上传速度
            "down": "0"  # 0表示无限制，使用服务器实际下载速度
        },
        "ports": ports,
        "recv_window_conn": 15728640,
        "recv_window": 62914560,
        "disable_mtu_discovery": False
    }
    return config

# 生成Nginx配置
def generate_nginx_config(cert_path, key_path):
    config = f"""
server {{
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}}

server {{
    listen 443 ssl;
    server_name _;
    
    ssl_certificate {cert_path};
    ssl_certificate_key {key_path};
    
    root /var/www/html;
    index index.html;

    location / {{
        try_files $uri $uri/ =404;
    }}
}}
    """
    return config

# 生成V2RayN配置文件
def generate_v2rayn_config(server_ip, password, obfs_password, ports, cert_path):
    config = {
        "remarks": f"Hysteria2-{datetime.now().strftime('%Y%m%d')}",
        "server": server_ip,
        "server_port": 443,
        "protocol": "hysteria2",
        "up_mbps": 0,
        "down_mbps": 0,
        "password": password,
        "obfs": "salamander",
        "obfs_password": obfs_password,
        "ports": ports,
        "insecure": True,  # 自签名证书需要设置为不安全
        "sni": ""  # 自签名证书不需要SNI
    }
    
    # 生成可直接导入的URL
    url_config = {
        "server": server_ip,
        "ports": ",".join(map(str, ports)),
        "protocol": "hysteria2",
        "up": "0",
        "down": "0",
        "auth": password,
        "obfs": "salamander",
        "obfs-password": obfs_password,
        "insecure": "1"
    }
    query = "&".join([f"{k}={v}" for k, v in url_config.items()])
    url = f"hysteria2://{server_ip}:443?{query}#Hysteria2-{server_ip}"
    
    return config, url

# 获取服务器IP
def get_server_ip():
    try:
        result = subprocess.run(['curl', '-s', 'ifconfig.me'], capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except:
        return "your_server_ip"

# 主函数
def main():
    # 安装依赖
    install_dependencies()
    
    # 生成自签名证书
    cert_path, key_path = generate_self_signed_cert()
    
    # 生成随机端口
    ports = generate_ports()
    print(f"生成的端口范围: {ports[0]}-{ports[-1]}")
    
    # 生成Hysteria2配置
    hysteria_config = generate_hysteria_config(ports, cert_path, key_path)
    config_json = json.dumps(hysteria_config, indent=2)
    
    # 保存Hysteria2配置
    os.makedirs("/etc/hysteria2", exist_ok=True)
    with open("/etc/hysteria2/config.json", "w") as f:
        f.write(config_json)
    
    # 配置Nginx
    nginx_config = generate_nginx_config(cert_path, key_path)
    with open("/etc/nginx/sites-available/default", "w") as f:
        f.write(nginx_config)
    
    # 创建Web目录
    os.makedirs("/var/www/html", exist_ok=True)
    with open("/var/www/html/index.html", "w") as f:
        f.write("<html><body><h1>Welcome to My Server</h1></body></html>")
    
    # 重启Nginx
    subprocess.run(["systemctl", "restart", "nginx"], check=True)
    
    # 获取服务器IP
    server_ip = get_server_ip()
    
    # 生成V2RayN配置
    password = hysteria_config["auth"]["password"]
    obfs_password = hysteria_config["obfs"]["salamander"]["password"]
    v2rayn_config, v2rayn_url = generate_v2rayn_config(server_ip, password, obfs_password, ports, cert_path)
    
    # 保存V2RayN配置
    os.makedirs("/opt/hysteria2", exist_ok=True)
    with open("/opt/hysteria2/v2rayn.json", "w") as f:
        json.dump(v2rayn_config, f, indent=2)
    
    with open("/opt/hysteria2/v2rayn_url.txt", "w") as f:
        f.write(v2rayn_url)
    
    print("\n配置完成!")
    print(f"服务器IP: {server_ip}")
    print(f"Hysteria2配置文件已保存到: /etc/hysteria2/config.json")
    print(f"V2RayN配置文件已保存到: /opt/hysteria2/v2rayn.json")
    print(f"V2RayN导入URL已保存到: /opt/hysteria2/v2rayn_url.txt")
    print("\n请确保防火墙已开放以下端口:")
    print(f"- 22 (SSH)")
    print(f"- 80, 443 (HTTP/HTTPS)")
    print(f"- {ports[0]}-{ports[-1]} (端口跳跃范围)")
    print("\n注意: 由于使用自签名证书，客户端需要设置'允许不安全连接'")

if __name__ == "__main__":
    main()
