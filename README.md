# 一键全自动Socks5脚本
### 架构支持
- ✅ x86_64 (AMD64)
- ✅ aarch64 (ARM64)
### 系统支持
- ✅ Debian 9+
- ✅ Ubuntu 16.04+
- ✅ CentOS 7+


![声明:](https://img.shields.io/badge/声明:-本脚本仅用于测试学习-red?style=flat-square&logo=alert)
![wave](https://capsule-render.vercel.app/api?type=waving&color=00BF63&height=100&section=footer)

> [!IMPORTANT]
> **运行前必读**
> 本脚本需要 **Root** 权限才能安装服务和配置防火墙。请使用 `sudo -i` 切换用户。




👉默认端口，用户名、密码
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ruheo/socks/main/socks.sh)"
```

👉默认端口，无认证
```bash
curl -fsSL https://raw.githubusercontent.com/ruheo/socks/main/socks.sh | sudo bash -s -- noauth
```

👉自定义端口，无认证
```bash
curl -fsSL https://raw.githubusercontent.com/ruheo/socks/main/socks.sh | sudo bash -s -- noauth 端口号
```

👉自定义端口，用户名、密码
```bash
curl -fsSL https://raw.githubusercontent.com/ruheo/socks/main/socks.sh | sudo bash -s -- password 端口 用户名 密码
```

🛑 卸载
```bash
bash /usr/local/bin/uninstall_socks.sh
```

![divider](https://github.com/andreasbm/readme/blob/master/assets/lines/rainbow.png?raw=true)