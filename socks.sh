#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "请以root用户身份运行"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

AUTH_MODE=${1:-password}
PORT=${2:-5868}
USER=${3:-admin}
PASSWD=${4:-123456}

if [[ "$AUTH_MODE" != "password" && "$AUTH_MODE" != "noauth" ]]; then
    echo -e "${RED}错误：认证模式仅支持 'password' 或 'noauth'${NC}"
    exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo -e "${RED}错误：端口必须是 1 到 65535 之间的整数。${NC}"
    exit 1
fi

if [ "$AUTH_MODE" == "password" ]; then
    if [ -z "$USER" ] || [ -z "$PASSWD" ]; then
        echo -e "${RED}错误：password 模式下，账号和密码不能为空！${NC}"
        exit 1
    fi
else
    USER=""
    PASSWD=""
fi

echo "=========================================="
echo "正在执行安装..."
echo "模式: $AUTH_MODE | 端口: $PORT"
echo "=========================================="

SOCKS_BIN="/usr/local/bin/socks"
SERVICE_FILE="/etc/systemd/system/sockd.service"
CONFIG_FILE="/etc/socks/config.json"
UNINSTALL_SCRIPT="/usr/local/bin/uninstall_socks.sh"

IS_FIREWALLD=0
IS_UFW=0
IS_IPTABLES=0
PACKAGE_MANAGER=""

if command -v yum &> /dev/null; then
    PACKAGE_MANAGER="yum"
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        IS_FIREWALLD=1
        echo -e "${GREEN}检测到防火墙: Firewalld${NC}"
    else
        IS_IPTABLES=1
        echo -e "${YELLOW}将使用 iptables 进行防火墙配置${NC}"
    fi
elif command -v apt-get &> /dev/null; then
    PACKAGE_MANAGER="apt-get"
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        IS_UFW=1
        echo -e "${GREEN}检测到防火墙: UFW${NC}"
    else
        IS_IPTABLES=1
        echo -e "${YELLOW}检测到 UFW 未开启或不存在，将使用 iptables 进行配置${NC}"
    fi
else
    echo -e "${RED}不支持的系统。${NC}"
    exit 1
fi

echo "检查基础依赖..."

if [ "$PACKAGE_MANAGER" == "yum" ]; then
    NEED_INSTALL=0
    for cmd in wget lsof curl; do
        if ! command -v $cmd &> /dev/null; then
            NEED_INSTALL=1
            break
        fi
    done

    if [ "$NEED_INSTALL" -eq 0 ]; then
        echo -e "${GREEN}✓ 依赖已就绪，跳过安装过程${NC}"
    else
        yum install -y wget lsof curl
        if [ "$IS_IPTABLES" -eq 1 ]; then
            yum install -y iptables-services
            systemctl enable iptables
            systemctl start iptables
        fi
    fi
elif [ "$PACKAGE_MANAGER" == "apt-get" ]; then
    NEED_INSTALL=0
    for cmd in wget lsof curl; do
        if ! command -v $cmd &> /dev/null; then
            NEED_INSTALL=1
            break
        fi
    done

    if [ "$IS_IPTABLES" -eq 1 ] && ! dpkg -s netfilter-persistent &> /dev/null; then
        NEED_INSTALL=1
    fi

    if [ "$NEED_INSTALL" -eq 0 ]; then
        echo -e "${GREEN}✓ 依赖已就绪，跳过安装过程${NC}"
    else
        echo "安装缺失的依赖..."

        if apt-get install -y --no-upgrade wget lsof curl 2>/dev/null; then
            echo -e "${GREEN}✓ 依赖安装完成${NC}"
        else
            if ps aux | grep -E '[a]pt-get|[a]pt|[d]pkg|[u]nattended' | grep -v grep >/dev/null 2>&1; then
                echo -e "${YELLOW}检测到后台包管理进程运行中，等待其完成...${NC}"

                WAIT_COUNT=0
                MAX_WAIT=40

                while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
                    if ! ps aux | grep -E '[a]pt-get|[a]pt|[d]pkg|[u]nattended' | grep -v grep >/dev/null 2>&1; then
                        break
                    fi
                    echo "  等待中... (${WAIT_COUNT}/${MAX_WAIT})"
                    sleep 3
                    ((WAIT_COUNT++))
                done

                if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
                    echo -e "${YELLOW}⚠ 等待超时，尝试继续...${NC}"
                else
                    echo -e "${GREEN}✓ 后台进程已完成${NC}"
                fi
            fi

            echo "更新软件源并重试..."
            if ! apt-get update -qq; then
                echo -e "${RED}错误：apt-get update 失败${NC}"
                echo -e "${YELLOW}请检查网络连接和软件源配置${NC}"
                exit 1
            fi

            if ! apt-get install -y --no-upgrade wget lsof curl; then
                echo -e "${RED}错误：依赖安装失败${NC}"
                exit 1
            fi

            echo -e "${GREEN}✓ 依赖安装完成${NC}"
        fi

        if [ "$IS_IPTABLES" -eq 1 ] && ! dpkg -s netfilter-persistent &> /dev/null; then
            echo "安装防火墙持久化工具..."
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade iptables-persistent netfilter-persistent >/dev/null 2>&1
        fi
    fi
fi

echo "检测网络环境..."
HAS_IPV6=0
if ip -6 addr show 2>/dev/null | grep -q "scope global"; then
    HAS_IPV6=1
    echo -e "${GREEN}✓ 检测到 IPv6 支持${NC}"
else
    echo -e "${YELLOW}⚠ 未检测到 IPv6，将仅使用 IPv4${NC}"
fi

echo "正在检查端口 $PORT 是否被占用..."
systemctl stop sockd.service 2>/dev/null
sleep 1

CHECK_PORT_PID=$(lsof -i TCP:$PORT -s TCP:LISTEN -t 2>/dev/null)
if [ -n "$CHECK_PORT_PID" ]; then
    PROCESS_NAME=$(ps -p $CHECK_PORT_PID -o comm= 2>/dev/null || echo "未知")
    echo -e "${RED}错误：端口 $PORT 已经被其他程序占用！${NC}"
    echo -e "占用程序: ${YELLOW}$PROCESS_NAME${NC} (PID: $CHECK_PORT_PID)"
    exit 1
else
    echo -e "${GREEN}端口 $PORT 可用，继续安装...${NC}"
fi

if [ -f "$CONFIG_FILE" ]; then
    OLD_PORT=$(grep '"port":' "$CONFIG_FILE" | awk -F': ' '{print $2}' | tr -cd '0-9')
    if [ -n "$OLD_PORT" ] && [ "$OLD_PORT" != "$PORT" ]; then
        echo "检测到旧端口: $OLD_PORT，正在清理..."
        if [ "$IS_FIREWALLD" -eq 1 ]; then
            firewall-cmd --remove-port=$OLD_PORT/tcp --permanent >/dev/null 2>&1
            firewall-cmd --remove-port=$OLD_PORT/udp --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        elif [ "$IS_UFW" -eq 1 ]; then
            ufw delete allow $OLD_PORT/tcp >/dev/null 2>&1
            ufw delete allow $OLD_PORT/udp >/dev/null 2>&1
        elif [ "$IS_IPTABLES" -eq 1 ]; then
            while iptables -D INPUT -p tcp --dport $OLD_PORT -j ACCEPT >/dev/null 2>&1; do :; done
            while iptables -D INPUT -p udp --dport $OLD_PORT -j ACCEPT >/dev/null 2>&1; do :; done
            netfilter-persistent save >/dev/null 2>&1 || service iptables save >/dev/null 2>&1
        fi
        echo -e "  ${GREEN}✓ 已清理旧端口 $OLD_PORT 的防火墙规则${NC}"
    fi
fi

ARCH=$(uname -m)
GITHUB_REPO_URL="https://raw.githubusercontent.com/ruheo/socks/main"

if [[ "$ARCH" == "x86_64" ]]; then
    TARGET_FILE="socksamd"
elif [[ "$ARCH" == "aarch64" ]]; then
    TARGET_FILE="socksarm"
else
    echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1
fi

DOWNLOAD_URL="$GITHUB_REPO_URL/$TARGET_FILE"
echo "正在下载安装源文件 ($ARCH)..."
echo "源文件: $TARGET_FILE"

if ! wget -O "$SOCKS_BIN" "$DOWNLOAD_URL"; then
    echo -e "${RED}错误：下载失败！${NC}"
    echo -e "${YELLOW}请检查 GitHub 仓库地址或网络连接。${NC}"
    rm -f "$SOCKS_BIN"
    exit 1
fi

chmod +x "$SOCKS_BIN"
if ! id "socksuser" &>/dev/null; then useradd -r -s /sbin/nologin socksuser; fi

echo "生成配置..."
mkdir -p /etc/socks

if [ "$AUTH_MODE" = "password" ]; then
    AUTH_PART="\"auth\": \"password\", \"accounts\": [ { \"user\": \"$USER\", \"pass\": \"$PASSWD\" } ],"
else
    AUTH_PART="\"auth\": \"noauth\","
fi

if [ "$HAS_IPV6" -eq 1 ]; then
    LISTEN_ADDR="::"
else
    LISTEN_ADDR="0.0.0.0"
fi

cat <<EOF > "$CONFIG_FILE"
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "listen": "$LISTEN_ADDR",
            "port": $PORT,
            "protocol": "socks",
            "settings": { $AUTH_PART "udp": true }
        }
    ],
    "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF

chown socksuser:socksuser "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Socks Service
After=network.target

[Service]
User=socksuser
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$SOCKS_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sockd.service
systemctl restart sockd.service
sleep 2

if ! systemctl is-active --quiet sockd.service; then
    echo -e "${RED}✗ 服务启动失败！以下是错误日志：${NC}"
    journalctl -u sockd.service -n 20 --no-pager
    exit 1
fi

if ! lsof -i TCP:$PORT -s TCP:LISTEN -t >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ 警告：服务已启动，但端口 $PORT 未被监听。${NC}"
    echo -e "${YELLOW}可能是配置文件有误或权限不足。${NC}"
    exit 1
else
    echo -e "${GREEN}✓ 服务运行正常，端口监听成功${NC}"
fi

echo "放行端口: $PORT (TCP + UDP)..."

if [ "$IS_FIREWALLD" -eq 1 ]; then
    firewall-cmd --add-port=$PORT/tcp --permanent >/dev/null 2>&1
    firewall-cmd --add-port=$PORT/udp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    echo -e "${GREEN}✓ Firewalld 规则已添加${NC}"
elif [ "$IS_UFW" -eq 1 ]; then
    ufw allow $PORT/tcp >/dev/null 2>&1
    ufw allow $PORT/udp >/dev/null 2>&1
    echo -e "${GREEN}✓ UFW 规则已添加${NC}"
elif [ "$IS_IPTABLES" -eq 1 ]; then
    iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
    iptables -I INPUT -p udp --dport $PORT -j ACCEPT

    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
        echo -e "${GREEN}✓ iptables 规则已添加并持久化 (netfilter-persistent)${NC}"
    elif command -v service &> /dev/null; then
        service iptables save >/dev/null 2>&1
        echo -e "${GREEN}✓ iptables 规则已添加并持久化 (service)${NC}"
    else
        echo -e "${YELLOW}⚠ 警告：未找到规则保存工具，重启后防火墙规则可能失效。${NC}"
    fi
fi

cat <<EOF > "$UNINSTALL_SCRIPT"
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "=========================================="
echo "正在执行深度卸载..."
echo "目标清理端口: $PORT"
echo "=========================================="

echo "停止服务..."
systemctl stop sockd.service >/dev/null 2>&1
systemctl disable sockd.service >/dev/null 2>&1

echo "删除文件..."
rm -f "$SERVICE_FILE" "$SOCKS_BIN"
rm -rf /etc/socks
if id "socksuser" &>/dev/null; then userdel socksuser >/dev/null 2>&1; fi
systemctl daemon-reload >/dev/null 2>&1

echo "正在智能清理防火墙规则..."

if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --remove-port=$PORT/tcp --permanent >/dev/null 2>&1
    firewall-cmd --remove-port=$PORT/udp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    echo -e "\${GREEN}✓ 已清理 Firewalld 规则\${NC}"
fi

if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
    ufw delete allow $PORT/tcp >/dev/null 2>&1
    ufw delete allow $PORT/udp >/dev/null 2>&1
    echo -e "\${GREEN}✓ 已清理 UFW 规则\${NC}"
fi

echo "深度扫描并清理 iptables 重复规则..."

count_tcp=0
while iptables -D INPUT -p tcp --dport $PORT -j ACCEPT >/dev/null 2>&1; do
    ((count_tcp++))
done
if [ \$count_tcp -gt 0 ]; then
    echo -e "\${GREEN}✓ 已清理 \$count_tcp 条 TCP 规则\${NC}"
fi

count_udp=0
while iptables -D INPUT -p udp --dport $PORT -j ACCEPT >/dev/null 2>&1; do
    ((count_udp++))
done
if [ \$count_udp -gt 0 ]; then
    echo -e "\${GREEN}✓ 已清理 \$count_udp 条 UDP 规则\${NC}"
fi

if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save >/dev/null 2>&1
elif command -v service &> /dev/null; then
    service iptables save >/dev/null 2>&1
fi

echo "=========================================="
echo -e "\${GREEN}✓ Socks5 代理服务已完全卸载！\${NC}"
echo "已清理："
echo "  - 服务文件"
echo "  - 可执行文件"
echo "  - 配置目录"
echo "  - 系统用户"
echo "  - 防火墙规则（端口 $PORT）"
echo "=========================================="

rm -- "\$0"
EOF
chmod +x "$UNINSTALL_SCRIPT"

echo "获取服务器 IP 地址..."
IPv4=$(curl -s -4 --connect-timeout 3 ip.sb 2>/dev/null | tr -d '[:space:]' || echo "获取失败")

if [ "$HAS_IPV6" -eq 1 ]; then
    IPv6=$(curl -s -6 --connect-timeout 3 ip.sb 2>/dev/null | tr -d '[:space:]' || echo "获取失败")
    STACK_INFO="双栈模式（IPv4 + IPv6）"
else
    IPv6="当前主机无 IPv6"
    STACK_INFO="单栈模式（仅 IPv4）"
fi

echo "=========================================="
echo -e "${GREEN}安装完成！${NC}"
echo "运行模式: $STACK_INFO"
echo "----------------------------------------"
echo "IPv4 地址: $IPv4"
echo "IPv6 地址: $IPv6"
echo "端口: $PORT"
if [ "$AUTH_MODE" = "password" ]; then
    echo "用户名: $USER"
    echo "密码: $PASSWD"
else
    echo "认证: 无需认证"
fi
echo "----------------------------------------"
echo "卸载命令: bash $UNINSTALL_SCRIPT"
echo "=========================================="