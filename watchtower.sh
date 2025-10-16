#!/bin/bash

# ============================================================
# Watchtower 自动部署/更新脚本 - 优化版
# 支持多服务器标识、代理配置和 Telegram 通知
# 版本: 2.0
# ============================================================

set -e

# ============ 颜色定义 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ============ 打印函数 ============
print_info() { echo -e "${BLUE}[ℹ️ ]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[⚠️ ]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_step() { echo -e "${PURPLE}[>>]${NC} $1"; }

# 显示横幅
print_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║        🐳 Watchtower 自动部署脚本 - 优化版 🐳            ║
║                                                           ║
║     • 自动监控 Docker 容器更新                            ║
║     • 支持多服务器标识                                    ║
║     • Telegram 通知集成                                   ║
║     • 自动清理旧镜像                                      ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}\n"
}

# 分隔线
print_separator() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 工作目录
WORK_DIR=~/watchtower

# 检测 Docker Compose
detect_compose() {
    print_step "检测 Docker Compose..."
    
    COMPOSE_CMD=""
    if docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
        print_success "Docker Compose (插件版本) 已就绪"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
        print_success "Docker Compose (独立版本) 已就绪"
    else
        print_error "未找到 Docker Compose，请先安装"
        exit 1
    fi
}

# 获取服务器信息
get_server_info() {
    print_step "获取服务器信息..."
    
    # 获取主机名
    HOSTNAME=$(hostname)
    
    # 获取外网 IP
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
                curl -s --max-time 5 icanhazip.com 2>/dev/null || \
                curl -s --max-time 5 ipinfo.io/ip 2>/dev/null || \
                echo "未知")
    
    # 如果没有外网 IP，使用内网 IP
    if [ "$SERVER_IP" = "未知" ]; then
        SERVER_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    fi
    
    print_info "主机名: ${CYAN}$HOSTNAME${NC}"
    print_info "IP 地址: ${CYAN}$SERVER_IP${NC}"
}

# 配置服务器标识
configure_server_identity() {
    echo ""
    print_separator
    echo -e "${YELLOW}📝 配置服务器标识${NC}"
    print_separator
    echo ""
    
    echo -e "${WHITE}当前服务器信息:${NC}"
    echo -e "  • 主机名: ${CYAN}$HOSTNAME${NC}"
    echo -e "  • IP 地址: ${CYAN}$SERVER_IP${NC}"
    echo ""
    
    # 提供默认标识
    DEFAULT_IDENTITY="${HOSTNAME} (${SERVER_IP})"
    
    echo -e "${YELLOW}💡 提示:${NC} 服务器标识将显示在 Telegram 通知中，帮助您区分不同服务器"
    echo -e "${YELLOW}示例:${NC}"
    echo "  • 生产服务器 (阿里云-北京)"
    echo "  • 测试服务器 (腾讯云-上海)"
    echo "  • 个人服务器 (Vultr-东京)"
    echo ""
    
    read -p "请输入服务器标识 [默认: $DEFAULT_IDENTITY]: " SERVER_IDENTITY
    
    if [ -z "$SERVER_IDENTITY" ]; then
        SERVER_IDENTITY="$DEFAULT_IDENTITY"
    fi
    
    print_success "服务器标识: ${CYAN}$SERVER_IDENTITY${NC}"
}

# 检查代理
check_proxy() {
    echo ""
    print_separator
    echo -e "${YELLOW}🌐 检查网络代理${NC}"
    print_separator
    echo ""
    
    print_step "检查 Xray 代理状态..."
    
    if docker ps | grep -q xray-proxy; then
        print_success "Xray 代理正在运行"
        USE_PROXY=true
        PROXY_URL="http://127.0.0.1:1081"
    else
        print_warning "未检测到 Xray 代理容器"
        echo ""
        echo -e "${YELLOW}注意:${NC} 没有代理可能导致："
        echo "  • 无法连接到 Telegram (需要科学上网)"
        echo "  • 无法拉取某些海外镜像"
        echo ""
        
        read -p "是否配置自定义代理? (y/n) [默认: n]: " use_custom_proxy
        
        if [[ "$use_custom_proxy" == "y" ]] || [[ "$use_custom_proxy" == "Y" ]]; then
            read -p "请输入代理地址 (如: http://proxy.example.com:8080): " custom_proxy
            if [ -n "$custom_proxy" ]; then
                USE_PROXY=true
                PROXY_URL="$custom_proxy"
                print_success "已配置自定义代理: $PROXY_URL"
            else
                USE_PROXY=false
            fi
        else
            USE_PROXY=false
            print_warning "将在无代理环境下运行"
        fi
    fi
}

# 配置 Telegram 通知
configure_telegram() {
    echo ""
    print_separator
    echo -e "${YELLOW}📱 配置 Telegram 通知${NC}"
    print_separator
    echo ""
    
    echo -e "${YELLOW}💡 提示:${NC}"
    echo "  • 更新检测完成后发送通知"
    echo "  • 通知将包含服务器标识"
    echo "  • 可以多个服务器使用同一个 Bot"
    echo ""
    
    read -p "请输入 Bot Token (留空跳过通知): " BOT_TOKEN
    
    if [ -n "$BOT_TOKEN" ]; then
        read -p "请输入 Chat ID: " CHAT_ID
        
        if [ -z "$CHAT_ID" ]; then
            print_warning "未提供 Chat ID，将禁用通知"
            NOTIFICATION_URL=""
            ENABLE_NOTIFICATION=false
        else
            # 构建通知 URL，包含服务器标识
            NOTIFICATION_URL="telegram://${BOT_TOKEN}@telegram?chats=${CHAT_ID}&parsemode=HTML&title=${SERVER_IDENTITY}"
            ENABLE_NOTIFICATION=true
            print_success "Telegram 通知已配置"
        fi
    else
        print_warning "未配置 Telegram 通知"
        NOTIFICATION_URL=""
        ENABLE_NOTIFICATION=false
    fi
}

# 配置监控容器
configure_containers() {
    echo ""
    print_separator
    echo -e "${YELLOW}🐋 配置监控容器${NC}"
    print_separator
    echo ""
    
    # 列出当前运行的容器
    print_info "当前运行的容器:"
    echo ""
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -v "^NAMES" | while read line; do
        echo -e "  ${CYAN}•${NC} $line"
    done
    echo ""
    
    echo -e "${YELLOW}💡 提示:${NC}"
    echo "  • 输入容器名，多个容器用逗号或空格分隔"
    echo "  • 示例: danmu-api,danmu-app 或 danmu-api danmu-app"
    echo "  • 留空则监控所有容器"
    echo ""
    
    read -p "请输入要监控的容器名: " MONITOR_CONTAINERS
    
    if [ -z "$MONITOR_CONTAINERS" ]; then
        print_info "将监控 ${CYAN}所有容器${NC}"
        CONTAINER_COMMAND=""
        CONTAINER_LIST="所有容器"
        MONITOR_MODE="全部监控"
    else
        # 处理输入（支持逗号和空格分隔）
        MONITOR_CONTAINERS=$(echo "$MONITOR_CONTAINERS" | tr ',' ' ' | tr -s ' ')
        CONTAINER_COMMAND="command: [$MONITOR_CONTAINERS]"
        CONTAINER_LIST="$MONITOR_CONTAINERS"
        MONITOR_MODE="指定监控"
        print_success "已配置监控: ${CYAN}$MONITOR_CONTAINERS${NC}"
    fi
}

# 配置检查间隔
configure_interval() {
    echo ""
    print_separator
    echo -e "${YELLOW}⏰ 配置检查间隔${NC}"
    print_separator
    echo ""
    
    echo -e "${YELLOW}建议间隔:${NC}"
    echo "  • 3600 (1 小时) - 推荐用于生产环境"
    echo "  • 1800 (30 分钟) - 适合测试环境"
    echo "  • 7200 (2 小时) - 适合低频更新"
    echo ""
    
    read -p "请输入检查间隔（秒）[默认: 3600]: " CHECK_INTERVAL
    CHECK_INTERVAL=${CHECK_INTERVAL:-3600}
    
    # 转换为可读格式
    if [ "$CHECK_INTERVAL" -ge 3600 ]; then
        INTERVAL_DISPLAY="$((CHECK_INTERVAL / 3600)) 小时"
    elif [ "$CHECK_INTERVAL" -ge 60 ]; then
        INTERVAL_DISPLAY="$((CHECK_INTERVAL / 60)) 分钟"
    else
        INTERVAL_DISPLAY="$CHECK_INTERVAL 秒"
    fi
    
    print_success "检查间隔: ${CYAN}$INTERVAL_DISPLAY${NC}"
}

# 显示配置摘要
show_summary() {
    echo ""
    print_separator
    echo -e "${YELLOW}📋 配置摘要${NC}"
    print_separator
    echo ""
    
    echo -e "${WHITE}服务器信息:${NC}"
    echo -e "  🏷️  服务器标识: ${CYAN}$SERVER_IDENTITY${NC}"
    echo -e "  🖥️  主机名: ${CYAN}$HOSTNAME${NC}"
    echo -e "  🌐 IP 地址: ${CYAN}$SERVER_IP${NC}"
    echo ""
    
    echo -e "${WHITE}监控配置:${NC}"
    echo -e "  🐋 监控模式: ${CYAN}$MONITOR_MODE${NC}"
    echo -e "  📦 监控容器: ${CYAN}$CONTAINER_LIST${NC}"
    echo -e "  ⏱️  检查间隔: ${CYAN}$INTERVAL_DISPLAY${NC}"
    echo ""
    
    echo -e "${WHITE}网络配置:${NC}"
    if [ "$USE_PROXY" = true ]; then
        echo -e "  🌐 代理状态: ${GREEN}已启用${NC} ($PROXY_URL)"
    else
        echo -e "  🌐 代理状态: ${YELLOW}未启用${NC}"
    fi
    echo ""
    
    echo -e "${WHITE}通知配置:${NC}"
    if [ "$ENABLE_NOTIFICATION" = true ]; then
        echo -e "  📱 Telegram: ${GREEN}已启用${NC}"
        echo -e "  💬 Chat ID: ${CYAN}$CHAT_ID${NC}"
    else
        echo -e "  📱 Telegram: ${YELLOW}未启用${NC}"
    fi
    echo ""
    
    print_separator
    read -p "确认配置并继续部署? (y/n) [默认: y]: " confirm
    
    if [[ "$confirm" == "n" ]] || [[ "$confirm" == "N" ]]; then
        print_warning "用户取消部署"
        exit 0
    fi
}

# 生成配置文件
generate_config() {
    echo ""
    print_step "生成配置文件..."
    
    # 创建工作目录
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # 备份旧配置
    if [ -f docker-compose.yml ]; then
        backup_file="docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S)"
        cp docker-compose.yml "$backup_file"
        print_info "已备份配置: $backup_file"
    fi
    
    # 代理配置
    PROXY_CONFIG=""
    if [ "$USE_PROXY" = true ]; then
        PROXY_CONFIG="
      # 网络代理配置
      - HTTP_PROXY=${PROXY_URL}
      - HTTPS_PROXY=${PROXY_URL}
      - NO_PROXY=localhost,127.0.0.1,*.local,169.254.0.0/16"
    fi
    
    # 通知配置
    NOTIFICATION_CONFIG=""
    if [ "$ENABLE_NOTIFICATION" = true ]; then
        NOTIFICATION_CONFIG="
      # Telegram 通知配置
      - WATCHTOWER_NOTIFICATIONS=shoutrrr
      - WATCHTOWER_NOTIFICATION_URL=${NOTIFICATION_URL}
      - WATCHTOWER_NOTIFICATION_REPORT=true
      - WATCHTOWER_NOTIFICATION_TEMPLATE={{range .}}📦 *{{.Name}}* 更新完成\n服务器: ${SERVER_IDENTITY}\n镜像: {{.ImageName}}\n状态: {{.State}}\n时间: {{.Time}}\n{{end}}"
    fi
    
    # 生成 docker-compose.yml
    cat > docker-compose.yml <<EOF
# Watchtower 自动更新配置
# 服务器: ${SERVER_IDENTITY}
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower-monitor
    restart: unless-stopped
    
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/localtime:/etc/localtime:ro
    
    environment:
      # 基础配置
      - TZ=Asia/Shanghai
      - WATCHTOWER_POLL_INTERVAL=${CHECK_INTERVAL}
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_REMOVE_VOLUMES=false
      - WATCHTOWER_INCLUDE_STOPPED=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_REVIVE_STOPPED=false
      - WATCHTOWER_DEBUG=false
      - WATCHTOWER_RUN_ONCE=false
      - WATCHTOWER_ROLLING_RESTART=true
      
      # 服务器标识
      - WATCHTOWER_LABEL_ENABLE=true
      - SERVER_IDENTITY=${SERVER_IDENTITY}${PROXY_CONFIG}${NOTIFICATION_CONFIG}
    
    ${CONTAINER_COMMAND}
    
    # 网络模式
    network_mode: host
    
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
      - "server.identity=${SERVER_IDENTITY}"

EOF

    print_success "配置文件已生成"
}

# 部署服务
deploy_service() {
    echo ""
    print_separator
    echo -e "${YELLOW}🚀 开始部署${NC}"
    print_separator
    echo ""
    
    # 获取旧镜像 ID
    OLD_IMAGE_ID=""
    if docker ps -a --format '{{.Names}}' | grep -q "^watchtower-monitor$"; then
        OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' watchtower-monitor 2>/dev/null || echo "")
    fi
    
    # 停止并清理旧容器
    print_step "清理现有 Watchtower 容器..."
    
    # 停止所有 watchtower 容器
    watchtower_containers=$(docker ps -a --filter "ancestor=containrrr/watchtower" --format "{{.Names}}" 2>/dev/null || echo "")
    if [ -n "$watchtower_containers" ]; then
        for container in $watchtower_containers; do
            print_info "停止容器: $container"
            docker stop "$container" >/dev/null 2>&1 || true
            docker rm "$container" >/dev/null 2>&1 || true
        done
        print_success "旧容器已清理"
    else
        print_info "没有需要清理的容器"
    fi
    
    # 使用 compose 停止
    $COMPOSE_CMD down 2>/dev/null || true
    
    # 拉取最新镜像
    print_step "拉取最新镜像..."
    if docker pull containrrr/watchtower:latest; then
        NEW_IMAGE_ID=$(docker inspect --format='{{.Id}}' containrrr/watchtower:latest)
        print_success "镜像拉取成功: ${NEW_IMAGE_ID:7:12}"
        
        # 清理旧镜像
        if [ -n "$OLD_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
            print_info "清理旧镜像..."
            docker rmi "$OLD_IMAGE_ID" 2>/dev/null || true
        fi
    else
        print_warning "镜像拉取失败，使用本地镜像"
    fi
    
    # 启动服务
    print_step "启动 Watchtower 服务..."
    $COMPOSE_CMD up -d
    
    # 等待启动
    sleep 5
    
    # 验证启动
    MAX_RETRY=3
    for i in $(seq 1 $MAX_RETRY); do
        if docker ps | grep -q watchtower-monitor; then
            print_success "Watchtower 服务启动成功！"
            break
        else
            if [ $i -eq $MAX_RETRY ]; then
                print_error "服务启动失败"
                echo ""
                print_info "查看日志:"
                $COMPOSE_CMD logs --tail 30
                exit 1
            fi
            print_warning "第 $i/$MAX_RETRY 次检查..."
            sleep 3
        fi
    done
    
    # 清理悬空镜像
    print_step "清理悬空镜像..."
    dangling_count=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    if [ "$dangling_count" -gt 0 ]; then
        docker image prune -f >/dev/null 2>&1
        print_success "已清理 $dangling_count 个悬空镜像"
    else
        print_info "没有需要清理的镜像"
    fi
}

# 显示完成信息
show_completion() {
    clear
    echo -e "${GREEN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║            🎉 部署完成！Watchtower 已就绪 🎉              ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}\n"
    
    print_separator
    echo -e "${YELLOW}📊 部署信息${NC}"
    print_separator
    echo ""
    
    echo -e "${WHITE}服务器:${NC} ${CYAN}$SERVER_IDENTITY${NC}"
    echo -e "${WHITE}工作目录:${NC} ${CYAN}$WORK_DIR${NC}"
    echo -e "${WHITE}监控容器:${NC} ${CYAN}$CONTAINER_LIST${NC}"
    echo -e "${WHITE}检查间隔:${NC} ${CYAN}$INTERVAL_DISPLAY${NC}"
    echo ""
    
    echo -e "${WHITE}功能特性:${NC}"
    echo -e "  ${GREEN}✓${NC} 自动监控容器更新"
    echo -e "  ${GREEN}✓${NC} 自动拉取新镜像"
    echo -e "  ${GREEN}✓${NC} 自动重启容器"
    echo -e "  ${GREEN}✓${NC} 自动清理旧镜像"
    if [ "$USE_PROXY" = true ]; then
        echo -e "  ${GREEN}✓${NC} 代理连接已启用"
    fi
    if [ "$ENABLE_NOTIFICATION" = true ]; then
        echo -e "  ${GREEN}✓${NC} Telegram 通知已启用"
    fi
    echo ""
    
    print_separator
    echo -e "${YELLOW}🔧 常用命令${NC}"
    print_separator
    echo ""
    
    echo -e "${CYAN}# 查看实时日志${NC}"
    echo "cd $WORK_DIR && $COMPOSE_CMD logs -f"
    echo ""
    
    echo -e "${CYAN}# 查看服务状态${NC}"
    echo "cd $WORK_DIR && $COMPOSE_CMD ps"
    echo ""
    
    echo -e "${CYAN}# 重启服务${NC}"
    echo "cd $WORK_DIR && $COMPOSE_CMD restart"
    echo ""
    
    echo -e "${CYAN}# 停止服务${NC}"
    echo "cd $WORK_DIR && $COMPOSE_CMD down"
    echo ""
    
    echo -e "${CYAN}# 手动触发检查${NC}"
    echo "cd $WORK_DIR && $COMPOSE_CMD exec watchtower /watchtower --run-once"
    echo ""
    
    echo -e "${CYAN}# 查看容器状态${NC}"
    echo "docker ps | grep watchtower"
    echo ""
    
    print_separator
    echo -e "${GREEN}✨ Watchtower 已启动并开始监控您的容器！${NC}"
    print_separator
    echo ""
}

# ============ 主函数 ============
main() {
    print_banner
    
    detect_compose
    get_server_info
    configure_server_identity
    check_proxy
    configure_telegram
    configure_containers
    configure_interval
    show_summary
    
    generate_config
    deploy_service
    
    show_completion
}

# 执行主函数
main "$@"