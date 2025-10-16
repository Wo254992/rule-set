#!/bin/bash

# ============================================================
# Watchtower 自动部署/更新脚本 - 终极中文通知版
# 集成中文模板、智能部署、多服务器标识、代理配置
# 版本: 3.0
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
║      🐳 Watchtower 自动部署脚本 - 终极中文通知版 🐳       ║
║                                                           ║
║   • 智能部署，避免重复操作                                ║
║   • 精美中文通知，包含版本号对比                          ║
║   • 支持多服务器标识与代理配置                            ║
║   • 自动清理旧镜像，保持系统整洁                          ║
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

    echo -e "${YELLOW}💡 提示:${NC} 更新通知将使用精美的中文模板发送"
    echo ""

    read -p "请输入 Bot Token (留空跳过通知): " BOT_TOKEN

    if [ -n "$BOT_TOKEN" ]; then
        read -p "请输入 Chat ID: " CHAT_ID

        if [ -z "$CHAT_ID" ]; then
            print_warning "未提供 Chat ID，将禁用通知"
            NOTIFICATION_URL=""
            ENABLE_NOTIFICATION=false
        else
            # 构建通知 URL，不再需要 title 参数
            NOTIFICATION_URL="telegram://${BOT_TOKEN}@telegram?chats=${CHAT_ID}&parsemode=HTML"
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

    print_info "当前运行的容器:"
    echo ""
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -v "^NAMES" | while read line; do
        echo -e "  ${CYAN}•${NC} $line"
    done
    echo ""

    read -p "请输入要监控的容器名 (留空则监控所有容器): " MONITOR_CONTAINERS

    if [ -z "$MONITOR_CONTAINERS" ]; then
        print_info "将监控 ${CYAN}所有容器${NC}"
        CONTAINER_COMMAND=""
        CONTAINER_LIST="所有容器"
        MONITOR_MODE="全部监控"
    else
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

    read -p "请输入检查间隔（秒）[默认: 3600]: " CHECK_INTERVAL
    CHECK_INTERVAL=${CHECK_INTERVAL:-3600}

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
    echo ""
    echo -e "${WHITE}监控配置:${NC}"
    echo -e "  🐋 监控模式: ${CYAN}$MONITOR_MODE${NC}"
    echo -e "  📦 监控容器: ${CYAN}$CONTAINER_LIST${NC}"
    echo -e "  ⏱️  检查间隔: ${CYAN}$INTERVAL_DISPLAY${NC}"
    echo ""
    echo -e "${WHITE}网络与通知:${NC}"
    if [ "$USE_PROXY" = true ]; then
        echo -e "  🌐 代理状态: ${GREEN}已启用${NC} ($PROXY_URL)"
    else
        echo -e "  🌐 代理状态: ${YELLOW}未启用${NC}"
    fi
    if [ "$ENABLE_NOTIFICATION" = true ]; then
        echo -e "  📱 Telegram: ${GREEN}已启用 (使用中文模板)${NC}"
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

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # 代理配置
    PROXY_CONFIG=""
    if [ "$USE_PROXY" = true ]; then
        PROXY_CONFIG="
      # 网络代理配置
      - HTTP_PROXY=${PROXY_URL}
      - HTTPS_PROXY=${PROXY_URL}"
    fi

    # 通知配置
    NOTIFICATION_CONFIG=""
    if [ "$ENABLE_NOTIFICATION" = true ]; then
        NOTIFICATION_CONFIG="
      # Telegram 通知配置 (中文模板)
      - WATCHTOWER_NOTIFICATIONS=shoutrrr
      - WATCHTOWER_NOTIFICATION_URL=${NOTIFICATION_URL}
      - WATCHTOWER_NOTIFICATION_TEMPLATE_FILE=/templates/chinese_template.tpl"
    fi

    # 生成 docker-compose.yml
    NEW_COMPOSE_CONTENT=$(cat <<EOF
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
      - ./chinese_template.tpl:/templates/chinese_template.tpl:ro
    
    environment:
      # 基础配置
      - TZ=Asia/Shanghai
      - WATCHTOWER_POLL_INTERVAL=${CHECK_INTERVAL}
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_STOPPED=true
      - WATCHTOWER_ROLLING_RESTART=true
      - SERVER_IDENTITY=${SERVER_IDENTITY}${PROXY_CONFIG}${NOTIFICATION_CONFIG}
    
    ${CONTAINER_COMMAND}
    
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
      - "server.identity=${SERVER_IDENTITY}"
EOF
)
    # 检查配置是否有变化
    CONFIG_CHANGED=false
    if [ ! -f docker-compose.yml ] || ! echo "$NEW_COMPOSE_CONTENT" | cmp -s - docker-compose.yml; then
        CONFIG_CHANGED=true
        print_info "检测到配置变更，将重新生成..."
        # 备份旧配置
        if [ -f docker-compose.yml ]; then
            backup_file="docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S)"
            cp docker-compose.yml "$backup_file"
            print_info "已备份旧配置: $backup_file"
        fi
        echo "$NEW_COMPOSE_CONTENT" > docker-compose.yml
        print_success "docker-compose.yml 已生成"
    else
        print_info "配置无变化"
    fi

    # 生成中文通知模板文件
    cat > chinese_template.tpl <<'EOF'
{{- $serverIdentity := .Entries.Getenv "SERVER_IDENTITY" "未知服务器" -}}
{{- if .Report -}}
{{- with .Report -}}
<b>🔔 Watchtower 更新报告</b>
<b>服务器:</b> <code>{{ $serverIdentity }}</code>
━━━━━━━━━━━━━━
{{- if (or .Updated .Failed) -}}
<b>✨ 更新摘要:</b>
扫描: {{ .Scanned }} | 成功: {{ .Updated | len }} | 失败: {{ .Failed | len }}

{{- if .Updated }}
<b>✅ 成功更新的容器:</b>
{{- range .Updated }}
- <b>容器:</b> <code>{{ .Name }}</code>
  <b>镜像:</b> <code>{{ .ImageName }}</code>
  <b>版本:</b> <code>{{ .CurrentImageID.ShortID }}</code> → <code>{{ .LatestImageID.ShortID }}</code>
{{- end }}
{{- end }}

{{- if .Failed }}
<b>❌ 更新失败的容器:</b>
{{- range .Failed }}
- <b>容器:</b> <code>{{ .Name }}</code>
  <b>镜像:</b> <code>{{ .ImageName }}</code>
  <b>错误:</b> <code>{{ .Error }}</code>
{{- end }}
{{- end }}
{{- else -}}
<b>✅ 一切安好</b>
所有容器均已是最新版本，无需更新。
扫描数: {{ .Scanned }}
{{- end }}
{{- end -}}
{{- else -}}
<b>🚀 Watchtower 服务启动</b>
<b>服务器:</b> <code>{{ $serverIdentity }}</code>
首次检查将在约 {{ .Entries.Getenv "WATCHTOWER_POLL_INTERVAL" "3600" | toDuration | default "1h" }} 后运行。
{{- end -}}
EOF
    print_success "chinese_template.tpl 已生成"
}

# 部署服务
deploy_service() {
    echo ""
    print_separator
    echo -e "${YELLOW}🚀 开始部署${NC}"
    print_separator
    echo ""
    
    # 检查容器是否正在运行
    CONTAINER_RUNNING=false
    if docker ps --format '{{.Names}}' | grep -q "^watchtower-monitor$"; then
        CONTAINER_RUNNING=true
    fi

    # 智能部署决策
    if [ "$CONFIG_CHANGED" = false ] && [ "$CONTAINER_RUNNING" = true ]; then
        print_success "配置未变更且服务正在运行，无需重新部署。"
        return
    fi
    
    if [ "$CONTAINER_RUNNING" = true ]; then
        print_step "检测到配置变更，正在重新部署..."
    else
        print_step "服务未运行，开始首次部署..."
    fi

    print_step "清理旧的 Watchtower 容器 (如有)..."
    $COMPOSE_CMD down --remove-orphans 2>/dev/null || true

    print_step "拉取最新镜像..."
    if docker pull containrrr/watchtower:latest; then
        print_success "镜像拉取成功"
    else
        print_warning "镜像拉取失败，将使用本地缓存镜像"
    fi

    print_step "启动 Watchtower 服务..."
    $COMPOSE_CMD up -d

    sleep 5

    if docker ps | grep -q watchtower-monitor; then
        print_success "Watchtower 服务启动成功！"
    else
        print_error "服务启动失败"
        echo ""
        print_info "请检查日志:"
        $COMPOSE_CMD logs --tail 30
        exit 1
    fi

    print_step "清理悬空镜像..."
    if docker image prune -f --filter "dangling=true" | grep -q "Deleted Images:"; then
        print_success "悬空镜像已清理"
    else
        print_info "没有需要清理的悬空镜像"
    fi
}


# 显示完成信息
show_completion() {
    clear
    echo -e "${GREEN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║         🎉 部署完成！Watchtower 已成功启动 🎉             ║
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
    echo -e "  ${GREEN}✓${NC} 自动监控与更新容器"
    echo -e "  ${GREEN}✓${NC} 自动清理旧镜像"
    if [ "$ENABLE_NOTIFICATION" = true ]; then
        echo -e "  ${GREEN}✓${NC} 中文 Telegram 通知已启用"
    fi
    echo ""

    print_separator
    echo -e "${YELLOW}🔧 常用命令${NC}"
    print_separator
    echo ""

    echo -e "${CYAN}# 查看实时日志${NC}"
    echo "cd $WORK_DIR && $COMPOSE_CMD logs -f"
    echo ""
    echo -e "${CYAN}# 手动触发一次检查${NC}"
    echo "docker exec watchtower-monitor /watchtower --run-once"
    echo ""
    echo -e "${CYAN}# 停止服务${NC}"
    echo "cd $WORK_DIR && $COMPOSE_CMD down"
    echo ""
    print_separator
    echo -e "${GREEN}✨ Watchtower 已开始守护您的容器！${NC}"
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