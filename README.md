V2ray快速节点搭建
简体中文(./README_EN.md)  

> 声明：该项目仅供个人学习、交流，请遵守当地法律法规,勿用于非法用途;请勿用于生产环境  


# 功能介绍

- 支持一条命令搭建完成
- 支持扫码添加节点
- 支持多用户、多协议
- 支持的协议：vmess、vless、quic、hysteria2
- 支持配置更多传输配置：http、tcp、ws、grpc、kcp、quic
- 可自定义 xray 配置模板
- 支持证书自签

# 一键安装
在安装前请确保你的系统支持`bash`环境,且系统网络正常  


# 配置要求  
## 内存  
- 128MB minimal/256MB+ recommend  
## OS  
- Ubuntu 22-24

 # VLESS+Reality+uTLS+Vision+Xray-core协议
```
bash <(curl -Ls https://raw.githubusercontent.com/Firefly-xui/v2ray/master/VLESS+Reality+uTLS+Vision+Xray-core.sh)
```  

抗识别性极强：Reality 模拟浏览器握手，借助 uTLS 和 Vision，将流量伪装为正常 TLS；

无需证书：相比传统 TLS，Reality 不依赖于域名/签发证书，部署更灵活；

低识别风险：支持伪装为真实站点（如 Cloudflare、NVIDIA），对防火墙极度友好；

基于 TCP：流量更稳定，尤其适合城市宽带 / 教育网；

无需中间代理：直接入口部署即可使用。

适用场景：

长期开通的公网节点；

高干扰 / 高频封锁区域；

注重隐蔽性和可信度


# Hysteria2+UDP+TLS+Obfuscation搭建协议
```
bash <(curl -Ls https://raw.githubusercontent.com/Firefly-xui/v2ray/master/Hysteria2+UDP+TLS+Obfuscation.sh)

```  

极速连接与低延迟：基于 QUIC over UDP，初次连接快（支持 0-RTT）；

天然抗丢包：自动适应丢包重传，非常适合波动大的移动网络；

Obfs 模式内置：内建 Salty / Salamander 混淆插件，绕过 DPI 检测；

密码认证 + TLS 模拟：能有效避免端口扫描和握手特征识别。

缺点：

纯 UDP 架构受部分运营商影响（如 NAT 设备封锁）；

部分地区存在对 UDP 流量限速策略（如校园网）；

v2rayN 等传统客户端支持较弱（需 plugin）；

适用场景：

海外 VPS 接入移动端；

追求低延迟流媒体服务；

与服务器之间稳定性可控时非常高效；




| 协议组合                            | 平台       | 客户端/支持说明                                    |
|-------------------------------------|------------|-----------------------------------------------------|
| VLESS + Reality + uTLS + Vision     | Windows    | ✅ v2rayN ≥6.30，支持 Reality + Vision + uTLS       |
|                                     | Android    | ✅ v2rayNG（Meta 内核）或 Nekoray Android           |
|                                     | iOS        | ✅ Stash / Shadowrocket，需手动导入 Reality 节点     |
|                                     | macOS      | ✅ Clash Verge Meta / Stash                         |
|                                     | Linux/CLI  | ✅ Xray-core ≥1.8 / Sing-box                        |
|-------------------------------------|------------|-----------------------------------------------------|
| Hysteria2 + UDP + TLS + 混淆        | Windows    | ✅ Hysteria2 官方客户端 / v2rayN 插件               |
|                                     | Android    | ✅ Hysteria2 Android / Nekoray（开发版）            |
|                                     | iOS        | ⚠️ 手动配置 Shadowrocket / Stash，支持有限          |
|                                     | macOS      | ✅ CLI / Nekoray Mac                                |
|                                     | Linux/CLI  | ✅ Hysteria2 原生客户端                             |
|-------------------------------------|------------|-----------------------------------------------------|



| 协议组合                            | 抗封锁  | 延迟   | 稳定性 | 部署复杂度 | 适用建议       |
|-------------------------------------|--------|--------|--------|-------------|----------------|
| VLESS + Reality + uTLS + Vision     | ★★★★☆ | ★★★☆☆ | ★★★★☆ | ★★☆☆☆      | 推荐主力入口   |
| Hysteria2 + UDP + TLS + Obfs        | ★★★★☆ | ★★★★★ | ★★★☆☆ | ★★☆☆☆      | 流媒体 / 备用  |

