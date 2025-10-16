#!/bin/bash

# ============================================================
# 代理服务器终极部署脚本 - 完美版
# 支持 SOCKS5 (Dante) 和 HTTP (Squid/TinyProxy)
# 自动修复所有已知问题
# 作者: Claude AI
# 版本: 2.0 Ultimate
# 日期: 2025-10-16
# ============================================================

set -e

# ============ 颜色定义 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============ 默认配置 ============
SOCKS5_PORT=1080
HTTP_PORT=8080
USERNAME=""
PASSWORD=""
USE_TINYPROXY=false
INSTALL_DIR="/opt/proxy"
CONFIG_DIR="/etc/proxy"
LOG_DIR="/var/log/proxy"

# ============ 函数定义 ============

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║     代理服务器终极部署脚本 - Ultimate Edition            ║
║                                                           ║
║     • SOCKS5 代理 (Dante)                                ║
║     • HTTP/HTTPS 代理 (Squid/TinyProxy)                 ║
║     • 自动修复所有已知问题                                ║
║     • 完整测试和诊断                                      ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_step() {
    echo -e "${PURPLE}[>>]${NC} $1"
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        echo "请使用: sudo $0"
        exit 1
    fi
}

# 检测操作系统
detect_os() {
    print_step "检测操作系统..."
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        OS_NAME=$PRETTY_NAME
    else
        print_error "无法检测操作系统"
        exit 1
    fi
    
    print_info "操作系统: $OS_NAME"
}

# 修复 Debian 软件源
fix_debian_sources() {
    if [[ "$OS" != "debian" ]]; then
        return 0
    fi
    
    print_step "修复 Debian 软件源..."
    
    # 备份原有源
    cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    # 根据版本配置正确的源
    case "$VERSION_ID" in
        11)
            print_info "配置 Debian 11 (Bullseye) 软件源..."
            cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
            ;;
        12)
            print_info "配置 Debian 12 (Bookworm) 软件源..."
            cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
            ;;
        10)
            print_info "配置 Debian 10 (Buster) 软件源..."
            cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian buster main contrib non-free
deb http://deb.debian.org/debian buster-updates main contrib non-free
deb http://security.debian.org/debian-security buster/updates main contrib non-free
EOF
            ;;
    esac
    
    # 清理并重建 APT 缓存
    print_info "清理 APT 缓存..."
    rm -rf /var/lib/apt/lists/*
    mkdir -p /var/lib/apt/lists/partial
    
    print_success "Debian 软件源已修复"
}

# 安装依赖
install_dependencies() {
    print_step "安装系统依赖包..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        # 清理锁文件
        rm -f /var/lib/apt/lists/lock
        rm -f /var/cache/apt/archives/lock
        rm -f /var/lib/dpkg/lock*
        
        # 更新软件包列表
        print_info "更新软件包列表..."
        apt-get update -y || {
            print_warning "首次更新失败，清理后重试..."
            apt-get clean
            rm -rf /var/lib/apt/lists/*
            mkdir -p /var/lib/apt/lists/partial
            sleep 2
            apt-get update -y || {
                print_error "软件包更新失败"
                exit 1
            }
        }
        
        # 安装基础依赖
        print_info "安装基础工具..."
        apt-get install -y wget curl net-tools iptables build-essential || {
            apt-get install -f -y
            apt-get install -y wget curl net-tools iptables build-essential
        }
        
        # 尝试安装 iptables-persistent
        apt-get install -y iptables-persistent 2>/dev/null || print_warning "iptables-persistent 安装失败（非关键）"
        
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
        yum install -y wget curl net-tools iptables iptables-services gcc make
    else
        print_error "不支持的操作系统"
        exit 1
    fi
    
    print_success "依赖包安装完成"
}

# 用户配置
configure_settings() {
    echo ""
    print_step "配置代理服务器参数"
    echo ""
    
    read -p "SOCKS5 端口 [默认: 1080]: " input_socks5
    SOCKS5_PORT=${input_socks5:-1080}
    
    read -p "HTTP 代理端口 [默认: 8080]: " input_http
    HTTP_PORT=${input_http:-8080}
    
    echo ""
    read -p "是否启用用户认证? (y/n) [默认: n]: " enable_auth
    if [[ "$enable_auth" == "y" ]] || [[ "$enable_auth" == "Y" ]]; then
        read -p "用户名: " USERNAME
        while [[ -z "$USERNAME" ]]; do
            print_warning "用户名不能为空"
            read -p "用户名: " USERNAME
        done
        
        read -s -p "密码: " PASSWORD
        echo ""
        while [[ -z "$PASSWORD" ]]; do
            print_warning "密码不能为空"
            read -s -p "密码: " PASSWORD
            echo ""
        done
    fi
    
    echo ""
    read -p "HTTP 代理使用哪个程序? (1=Squid推荐, 2=TinyProxy轻量) [默认: 1]: " proxy_choice
    if [[ "$proxy_choice" == "2" ]]; then
        USE_TINYPROXY=true
    fi
    
    echo ""
    print_info "━━━━━━━━━━ 配置摘要 ━━━━━━━━━━"
    print_info "SOCKS5 端口: $SOCKS5_PORT"
    print_info "HTTP 端口: $HTTP_PORT"
    print_info "用户认证: $([ -n "$USERNAME" ] && echo "已启用 (用户: $USERNAME)" || echo "未启用")"
    print_info "HTTP 代理: $([ "$USE_TINYPROXY" = true ] && echo "TinyProxy" || echo "Squid")"
    print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    read -p "确认配置并继续? (y/n) [默认: y]: " confirm
    if [[ "$confirm" == "n" ]] || [[ "$confirm" == "N" ]]; then
        print_warning "用户取消安装"
        exit 0
    fi
}

# 安装 Dante (SOCKS5)
install_dante() {
    print_step "安装 Dante SOCKS5 服务器..."
    
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        if apt-cache show dante-server &>/dev/null; then
            apt-get install -y dante-server && {
                print_success "Dante 安装成功（APT 方式）"
                return 0
            }
        fi
        print_warning "APT 安装失败，从源码编译..."
        install_dante_from_source
        
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        yum install -y epel-release
        yum install -y dante-server || install_dante_from_source
    fi
}

# 从源码安装 Dante
install_dante_from_source() {
    print_info "从源码编译 Dante..."
    
    cd /tmp
    DANTE_VERSION="1.4.3"
    
    # 下载
    if ! wget -t 3 -T 30 "https://www.inet.no/dante/files/dante-${DANTE_VERSION}.tar.gz" -O dante.tar.gz 2>/dev/null; then
        print_warning "主源失败，尝试镜像..."
        wget -t 3 -T 30 "https://fossies.org/linux/misc/dante-${DANTE_VERSION}.tar.gz" -O dante.tar.gz || {
            print_error "下载失败"
            exit 1
        }
    fi
    
    tar -xzf dante.tar.gz
    cd "dante-${DANTE_VERSION}"
    
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var
    make -j$(nproc)
    make install
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/danted.service <<'EOFS'
[Unit]
Description=Dante SOCKS5 Server
After=network.target

[Service]
Type=forking
PIDFile=/var/run/danted.pid
ExecStart=/usr/sbin/sockd -D -f /etc/danted.conf
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOFS

    systemctl daemon-reload
    cd /
    rm -rf /tmp/dante*
    
    print_success "Dante 源码编译完成"
}

# 配置 Dante
configure_dante() {
    print_step "配置 Dante SOCKS5..."
    
    mkdir -p "$CONFIG_DIR"
    
    # 获取网络接口
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip -o -4 addr list | grep -v "127.0.0.1" | awk '{print $2}' | head -n1)
    fi
    if [ -z "$INTERFACE" ]; then
        INTERFACE="eth0"
    fi
    
    print_info "使用网络接口: $INTERFACE"
    
    # 配置文件路径
    DANTE_CONF="/etc/danted.conf"
    
    # 生成配置
    cat > "$DANTE_CONF" <<EOF
# Dante SOCKS5 配置文件 - Ultimate Edition
logoutput: syslog

# 监听配置
internal: 0.0.0.0 port = $SOCKS5_PORT
external: $INTERFACE

# 认证方法
clientmethod: none
socksmethod: $([ -n "$USERNAME" ] && echo "username" || echo "none")

# 用户权限
user.privileged: root
user.unprivileged: nobody

# 客户端规则
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

# SOCKS 规则
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: error
}

# 性能优化
timeout.io: 86400
timeout.negotiate: 30
EOF

    # 创建认证用户
    if [ -n "$USERNAME" ]; then
        print_info "创建 SOCKS5 认证用户..."
        id "$USERNAME" &>/dev/null || useradd -r -s /bin/false "$USERNAME" 2>/dev/null || true
        echo "$USERNAME:$PASSWORD" | chpasswd
    fi
    
    print_success "Dante 配置完成"
}

# 安装 Squid
install_squid() {
    print_step "安装 Squid HTTP 代理..."
    
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        apt-get install -y squid apache2-utils || {
            print_error "Squid 安装失败"
            exit 1
        }
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        yum install -y squid httpd-tools || {
            print_error "Squid 安装失败"
            exit 1
        }
    fi
    
    print_success "Squid 安装完成"
}

# 配置 Squid (Ultimate Edition)
configure_squid() {
    print_step "配置 Squid HTTP 代理 (Ultimate)..."
    
    # 备份原配置
    [ -f /etc/squid/squid.conf ] && cp /etc/squid/squid.conf /etc/squid/squid.conf.backup.$(date +%Y%m%d_%H%M%S)
    
    # 生成终极配置
    cat > /etc/squid/squid.conf <<EOF
# ============================================================
# Squid HTTP 代理配置 - Ultimate Edition
# 完美支持 HTTP/HTTPS CONNECT 方法
# ============================================================

# 监听端口
http_port $HTTP_PORT

# ============ ACL 定义 ============
acl SSL_ports port 443
acl Safe_ports port 80 21 443 70 210 1025-65535 280 488 591 777
acl CONNECT method CONNECT
acl localnet src 0.0.0.0/0

# ============ 认证配置 ============
EOF

    if [ -n "$USERNAME" ]; then
        cat >> /etc/squid/squid.conf <<EOF
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm Squid Proxy Server
auth_param basic credentialsttl 2 hours
auth_param basic casesensitive off
acl authenticated proxy_auth REQUIRED

EOF
    fi

    cat >> /etc/squid/squid.conf <<EOF
# ============ 访问控制 ============
# 拒绝不安全端口
http_access deny !Safe_ports

# 拒绝非 SSL 端口的 CONNECT
http_access deny CONNECT !SSL_ports

EOF

    if [ -n "$USERNAME" ]; then
        echo "# 允许认证用户" >> /etc/squid/squid.conf
        echo "http_access allow authenticated" >> /etc/squid/squid.conf
    else
        echo "# 允许所有本地网络" >> /etc/squid/squid.conf
        echo "http_access allow localnet" >> /etc/squid/squid.conf
    fi

    cat >> /etc/squid/squid.conf <<EOF

# 允许本机
http_access allow localhost

# 拒绝其他
http_access deny all

# ============ 性能优化 ============
# 关闭缓存
cache deny all

# 超时设置
forward_timeout 4 minutes
connect_timeout 2 minutes
read_timeout 5 minutes
request_timeout 2 minutes
persistent_request_timeout 2 minutes
client_lifetime 2 hours

# 连接池
client_persistent_connections on
server_persistent_connections on

# DNS 优化
dns_nameservers 8.8.8.8 1.1.1.1
dns_timeout 30 seconds

# ============ 隐私设置 ============
forwarded_for off
via off

# ============ 日志 ============
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log
logfile_rotate 7

# ============ 其他 ============
visible_hostname squid-proxy
shutdown_lifetime 3 seconds

# 刷新模式
refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320
EOF

    # 创建密码文件
    if [ -n "$USERNAME" ]; then
        print_info "创建 Squid 认证..."
        htpasswd -cb /etc/squid/passwords "$USERNAME" "$PASSWORD"
        chmod 640 /etc/squid/passwords
        chown proxy:proxy /etc/squid/passwords 2>/dev/null || chown squid:squid /etc/squid/passwords 2>/dev/null || true
    fi
    
    # 测试配置
    if squid -k parse 2>/dev/null; then
        print_success "Squid 配置完成"
    else
        print_error "Squid 配置文件语法错误"
        exit 1
    fi
}

# 安装 TinyProxy
install_tinyproxy() {
    print_step "安装 TinyProxy HTTP 代理..."
    
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        apt-get install -y tinyproxy || {
            print_error "TinyProxy 安装失败"
            exit 1
        }
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        yum install -y epel-release
        yum install -y tinyproxy || {
            print_error "TinyProxy 安装失败"
            exit 1
        }
    fi
    
    print_success "TinyProxy 安装完成"
}

# 配置 TinyProxy
configure_tinyproxy() {
    print_step "配置 TinyProxy HTTP 代理..."
    
    # 备份
    [ -f /etc/tinyproxy/tinyproxy.conf ] && cp /etc/tinyproxy/tinyproxy.conf /etc/tinyproxy/tinyproxy.conf.backup
    
    cat > /etc/tinyproxy/tinyproxy.conf <<EOF
# TinyProxy 配置 - Ultimate Edition
User nobody
Group nogroup
Port $HTTP_PORT
Listen 0.0.0.0
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogFile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"
MaxClients 100
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0

# 允许所有来源
Allow 0.0.0.0/0

# HTTPS CONNECT 支持
ConnectPort 443
ConnectPort 563

# 隐私
DisableViaHeader Yes
EOF

    print_success "TinyProxy 配置完成"
}

# 配置防火墙
configure_firewall() {
    print_step "配置防火墙规则..."
    
    # 检测并配置防火墙
    if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        print_info "配置 UFW 防火墙..."
        ufw allow $SOCKS5_PORT/tcp comment "SOCKS5 Proxy"
        ufw allow $HTTP_PORT/tcp comment "HTTP Proxy"
        print_success "UFW 规则已添加"
        
    elif command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        print_info "配置 firewalld..."
        firewall-cmd --permanent --add-port=$SOCKS5_PORT/tcp
        firewall-cmd --permanent --add-port=$HTTP_PORT/tcp
        firewall-cmd --reload
        print_success "firewalld 规则已添加"
        
    else
        print_info "配置 iptables..."
        # 检查规则是否已存在
        iptables -C INPUT -p tcp --dport $SOCKS5_PORT -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport $SOCKS5_PORT -j ACCEPT
        iptables -C INPUT -p tcp --dport $HTTP_PORT -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport $HTTP_PORT -j ACCEPT
        
        # 保存规则
        if command -v netfilter-persistent &> /dev/null; then
            netfilter-persistent save
        elif [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4
        elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
            service iptables save 2>/dev/null || iptables-save > /etc/sysconfig/iptables
        fi
        
        print_success "iptables 规则已添加"
    fi
}

# 启动服务
start_services() {
    print_step "启动代理服务..."
    
    # 启动 Dante
    systemctl enable danted 2>/dev/null || true
    systemctl restart danted
    sleep 2
    
    if systemctl is-active --quiet danted; then
        print_success "Dante SOCKS5 服务已启动 ✓"
    else
        print_error "Dante SOCKS5 服务启动失败 ✗"
        systemctl status danted --no-pager -l
    fi
    
    # 启动 HTTP 代理
    if [ "$USE_TINYPROXY" = true ]; then
        systemctl enable tinyproxy 2>/dev/null || true
        systemctl restart tinyproxy
        sleep 2
        
        if systemctl is-active --quiet tinyproxy; then
            print_success "TinyProxy HTTP 服务已启动 ✓"
        else
            print_error "TinyProxy HTTP 服务启动失败 ✗"
            systemctl status tinyproxy --no-pager -l
        fi
    else
        systemctl enable squid 2>/dev/null || true
        systemctl restart squid
        sleep 2
        
        if systemctl is-active --quiet squid; then
            print_success "Squid HTTP 服务已启动 ✓"
        else
            print_error "Squid HTTP 服务启动失败 ✗"
            systemctl status squid --no-pager -l
        fi
    fi
}

# 获取服务器 IP
get_server_ip() {
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 icanhazip.com 2>/dev/null || \
                curl -s --max-time 5 ipinfo.io/ip 2>/dev/null)
    
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    fi
}

# 测试代理
test_proxies() {
    print_step "测试代理连接..."
    echo ""
    
    local test_url="http://www.google.com"
    local test_https="https://www.google.com"
    local test_tg="https://api.telegram.org"
    
    # 测试 SOCKS5
    print_info "测试 SOCKS5 代理..."
    if timeout 10 curl --socks5 127.0.0.1:$SOCKS5_PORT -s -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null | grep -q "200\|301\|302"; then
        print_success "  HTTP 测试: ✓ 通过"
    else
        print_warning "  HTTP 测试: ✗ 失败"
    fi
    
    if timeout 10 curl --socks5 127.0.0.1:$SOCKS5_PORT -s -o /dev/null -w "%{http_code}" "$test_https" 2>/dev/null | grep -q "200\|301\|302"; then
        print_success "  HTTPS 测试: ✓ 通过"
    else
        print_warning "  HTTPS 测试: ✗ 失败"
    fi
    
    if timeout 10 curl --socks5 127.0.0.1:$SOCKS5_PORT -s -o /dev/null -w "%{http_code}" "$test_tg" 2>/dev/null | grep -q "200\|401"; then
        print_success "  Telegram 测试: ✓ 通过"
    else
        print_warning "  Telegram 测试: ✗ 失败"
    fi
    
    echo ""
    
    # 测试 HTTP 代理
    print_info "测试 HTTP 代理..."
    if timeout 10 curl -x http://127.0.0.1:$HTTP_PORT -s -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null | grep -q "200\|301\|302"; then
        print_success "  HTTP 测试: ✓ 通过"
    else
        print_warning "  HTTP 测试: ✗ 失败"
    fi
    
    if timeout 10 curl -x http://127.0.0.1:$HTTP_PORT -s -o /dev/null -w "%{http_code}" "$test_https" 2>/dev/null | grep -q "200\|301\|302"; then
        print_success "  HTTPS 测试: ✓ 通过"
    else
        print_warning "  HTTPS 测试: ✗ 失败"
    fi
    
    if timeout 10 curl -x http://127.0.0.1:$HTTP_PORT -s -o /dev/null -w "%{http_code}" "$test_tg" 2>/dev/null | grep -q "200\|401"; then
        print_success "  Telegram 测试: ✓ 通过"
    else
        print_warning "  Telegram 测试: ✗ 失败"
    fi
    
    echo ""
}

# 显示最终配置
show_final_config() {
    get_server_ip
    
    clear
    echo -e "${GREEN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║               🎉 部署完成！代理服务器已就绪 🎉              ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}服务器信息${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  🌐 服务器 IP: ${GREEN}$SERVER_IP${NC}"
    echo "  🖥️  操作系统: $OS_NAME"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}SOCKS5 代理配置${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  📡 协议: SOCKS5"
    echo "  🔌 地址: $SERVER_IP"
    echo "  🔢 端口: $SOCKS5_PORT"
    if [ -n "$USERNAME" ]; then
        echo "  👤 用户名: $USERNAME"
        echo "  🔑 密码: $PASSWORD"
    else
        echo "  🔓 认证: 未启用"
    fi
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}HTTP/HTTPS 代理配置${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  📡 协议: HTTP/HTTPS"
    echo "  🔌 地址: $SERVER_IP"
    echo "  🔢 端口: $HTTP_PORT"
    echo "  ⚙️  程序: $([ "$USE_TINYPROXY" = true ] && echo "TinyProxy" || echo "Squid")"
    if [ -n "$USERNAME" ]; then
        echo "  👤 用户名: $USERNAME"
        echo "  🔑 密码: $PASSWORD"
    else
        echo "  🔓 认证: 未启用"
    fi
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}客户端配置示例${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}# 1. 命令行使用 (curl)${NC}"
    echo "   # SOCKS5:"
    echo "   curl --socks5 $SERVER_IP:$SOCKS5_PORT https://www.google.com"
    echo ""
    echo "   # HTTP/HTTPS:"
    echo "   curl -x http://$SERVER_IP:$HTTP_PORT https://www.google.com"
    if [ -n "$USERNAME" ]; then
        echo ""
        echo "   # 带认证:"
        echo "   curl --socks5 $USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_PORT https://www.google.com"
        echo "   curl -x http://$USERNAME:$PASSWORD@$SERVER_IP:$HTTP_PORT https://www.google.com"
    fi
    echo ""
    
    echo -e "${GREEN}# 2. Docker 环境变量${NC}"
    cat <<EOFDC
   environment:
     - HTTP_PROXY=http://$SERVER_IP:$HTTP_PORT
     - HTTPS_PROXY=http://$SERVER_IP:$HTTP_PORT
     - NO_PROXY=localhost,127.0.0.1
EOFDC
    
    if [ -n "$USERNAME" ]; then
        echo ""
        echo "   # 或带认证:"
        cat <<EOFDC2
   environment:
     - HTTP_PROXY=http://$USERNAME:$PASSWORD@$SERVER_IP:$HTTP_PORT
     - HTTPS_PROXY=http://$USERNAME:$PASSWORD@$SERVER_IP:$HTTP_PORT
EOFDC2
    fi
    echo ""
    
    echo -e "${GREEN}# 3. Python requests 库${NC}"
    cat <<'EOFPY'
   proxies = {
       'http': 'http://SERVER_IP:HTTP_PORT',
       'https': 'http://SERVER_IP:HTTP_PORT',
       'socks5': 'socks5://SERVER_IP:SOCKS5_PORT'
   }
   requests.get('https://api.telegram.org', proxies=proxies)
EOFPY
    echo ""
    
    echo -e "${GREEN}# 4. Telegram Bot (Python)${NC}"
    cat <<'EOFTG'
   # 使用 SOCKS5 (推荐)
   request = HTTPXRequest(
       proxy='socks5://SERVER_IP:SOCKS5_PORT'
   )
   
   # 或使用 HTTP
   request = HTTPXRequest(
       proxy='http://SERVER_IP:HTTP_PORT'
   )
EOFTG
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}服务管理命令${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}# 查看服务状态${NC}"
    echo "   systemctl status danted"
    if [ "$USE_TINYPROXY" = true ]; then
        echo "   systemctl status tinyproxy"
    else
        echo "   systemctl status squid"
    fi
    echo ""
    echo -e "${GREEN}# 重启服务${NC}"
    echo "   systemctl restart danted"
    if [ "$USE_TINYPROXY" = true ]; then
        echo "   systemctl restart tinyproxy"
    else
        echo "   systemctl restart squid"
    fi
    echo ""
    echo -e "${GREEN}# 查看日志${NC}"
    echo "   journalctl -u danted -f"
    if [ "$USE_TINYPROXY" = true ]; then
        echo "   tail -f /var/log/tinyproxy/tinyproxy.log"
    else
        echo "   tail -f /var/log/squid/access.log"
        echo "   tail -f /var/log/squid/cache.log"
    fi
    echo ""
    echo -e "${GREEN}# 查看端口监听${NC}"
    echo "   netstat -tlnp | grep -E '$SOCKS5_PORT|$HTTP_PORT'"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}防火墙配置${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${RED}⚠️  重要提示 ⚠️${NC}"
    echo "  如果使用云服务器（阿里云、腾讯云、AWS 等），"
    echo "  请务必在控制台的安全组中开放以下端口："
    echo ""
    echo "    • TCP $SOCKS5_PORT (SOCKS5 代理)"
    echo "    • TCP $HTTP_PORT (HTTP/HTTPS 代理)"
    echo ""
    echo "  来源 IP: 0.0.0.0/0 (或指定您的客户端 IP)"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}故障排查${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}# 如果外部无法连接：${NC}"
    echo "  1. 检查服务是否运行: systemctl status danted squid"
    echo "  2. 检查端口监听: netstat -tlnp | grep -E '$SOCKS5_PORT|$HTTP_PORT'"
    echo "  3. 检查防火墙: iptables -L -n | grep -E '$SOCKS5_PORT|$HTTP_PORT'"
    echo "  4. 检查云服务商安全组设置"
    echo "  5. 本地测试: curl --socks5 127.0.0.1:$SOCKS5_PORT https://www.google.com"
    echo ""
    echo -e "${GREEN}# 诊断脚本（保存后运行）：${NC}"
    cat > /root/proxy_diagnose.sh <<'EOFDIAG'
#!/bin/bash
echo "=== 代理服务诊断 ==="
echo ""
echo "1. 服务状态:"
systemctl status danted --no-pager | head -3
systemctl status squid --no-pager | head -3 2>/dev/null || systemctl status tinyproxy --no-pager | head -3
echo ""
echo "2. 端口监听:"
netstat -tlnp | grep -E "1080|8080|SOCKS5_PORT|HTTP_PORT"
echo ""
echo "3. 防火墙规则:"
iptables -L INPUT -n | grep -E "1080|8080|SOCKS5_PORT|HTTP_PORT"
echo ""
echo "4. 测试本地连接:"
curl --socks5 127.0.0.1:SOCKS5_PORT -s -o /dev/null -w "SOCKS5: %{http_code}\n" https://www.google.com
curl -x http://127.0.0.1:HTTP_PORT -s -o /dev/null -w "HTTP: %{http_code}\n" https://www.google.com
echo ""
echo "5. 最近日志:"
tail -5 /var/log/squid/cache.log 2>/dev/null || tail -5 /var/log/tinyproxy/tinyproxy.log 2>/dev/null
EOFDIAG
    sed -i "s/SOCKS5_PORT/$SOCKS5_PORT/g" /root/proxy_diagnose.sh
    sed -i "s/HTTP_PORT/$HTTP_PORT/g" /root/proxy_diagnose.sh
    chmod +x /root/proxy_diagnose.sh
    echo "   已创建诊断脚本: /root/proxy_diagnose.sh"
    echo "   运行命令: bash /root/proxy_diagnose.sh"
    echo ""
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}配置文件位置${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  📄 Dante 配置: /etc/danted.conf"
    if [ "$USE_TINYPROXY" = true ]; then
        echo "  📄 TinyProxy 配置: /etc/tinyproxy/tinyproxy.conf"
    else
        echo "  📄 Squid 配置: /etc/squid/squid.conf"
    fi
    echo ""
    
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}          ✨ 部署完成！祝您使用愉快！ ✨             ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ============ 主函数 ============
main() {
    print_banner
    
    check_root
    detect_os
    fix_debian_sources
    configure_settings
    
    install_dependencies
    
    # 安装和配置 SOCKS5
    install_dante
    configure_dante
    
    # 安装和配置 HTTP 代理
    if [ "$USE_TINYPROXY" = true ]; then
        install_tinyproxy
        configure_tinyproxy
    else
        install_squid
        configure_squid
    fi
    
    configure_firewall
    start_services
    
    echo ""
    test_proxies
    
    show_final_config
}

# 执行主函数
main "$@"