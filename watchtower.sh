#!/bin/bash
# Docker 容器监控 - 一键部署脚本（最终版）
# 功能: 监控容器更新，发送中文 Telegram 通知
# 版本: 2.4 (支持自定义服务器名称前缀)

# --- 颜色定义 ---
set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 打印函数 ---
print_info() { echo -e "${BLUE}[信息]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

# --- 欢迎横幅 ---
show_banner() {
cat << "EOF"
╔════════════════════════════════════════════════════╗
║                                                    ║
║   Docker 容器监控部署脚本 v2.4                     ║
║   Watchtower + Telegram 中文通知                   ║
║   支持多服务器名称区分                             ║
║                                                    ║
╚════════════════════════════════════════════════════╝
EOF
echo ""
}

# --- 检查命令是否存在 ---
check_command() {
    command -v "$1" &> /dev/null
}

# --- 检查依赖 ---
check_requirements() {
    print_info "检查系统要求..."
    if ! check_command docker; then
        print_error "未安装 Docker"
        echo "请访问: https://docs.docker.com/engine/install/"
        exit 1
    fi

    if ! docker compose version &>/dev/null && ! check_command docker-compose; then
        print_error "未安装 Docker Compose"
        exit 1
    fi

    print_success "系统要求检查通过"
}

# --- 获取用户输入 (★★★ 修复点 ★★★) ---
get_user_input() {
    print_info "开始配置..."
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1️⃣  配置 Telegram Bot"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📌 如何获取 Bot Token:"
    echo "   1. 在 Telegram 搜索 @BotFather"
    echo "   2. 发送 /newbot 创建机器人"
    echo "   3. 获取 Token (格式: 123456:ABC-DEF...)"
    echo ""

    while true; do
        read -p "请输入 Bot Token: " BOT_TOKEN
        if [ -n "$BOT_TOKEN" ]; then
            break
        fi
        print_warning "不能为空，请重新输入"
    done

    echo ""
    echo "📌 如何获取 Chat ID:"
    echo "   1. 在 Telegram 搜索 @userinfobot"
    echo "   2. 发送任意消息获取你的 ID"
    echo ""

    while true; do
        read -p "请输入 Chat ID: " CHAT_ID
        if [ -n "$CHAT_ID" ]; then
            break
        fi
        print_warning "不能为空，请重新输入"
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "2️⃣  配置监控参数"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "检查间隔选项:"
    echo "  1) 每 30 分钟"
    echo "  2) 每小时 (推荐)"
    echo "  3) 每 6 小时"
    echo "  4) 每 12 小时"
    echo "  5) 每天一次"
    echo "  6) 自定义"
    echo ""

    read -p "请选择 [1-6]: " INTERVAL_CHOICE

    case $INTERVAL_CHOICE in
        1) POLL_INTERVAL=1800 ;;
        2) POLL_INTERVAL=3600 ;;
        3) POLL_INTERVAL=21600 ;;
        4) POLL_INTERVAL=43200 ;;
        5) POLL_INTERVAL=86400 ;;
        6)
            read -p "请输入检查间隔(秒): " POLL_INTERVAL
            POLL_INTERVAL=${POLL_INTERVAL:-3600}
            ;;
        *)
            print_warning "无效选择，使用默认: 每小时"
            POLL_INTERVAL=3600
            ;;
    esac

    echo ""
    read -p "是否监控所有容器? (y/n, 默认: y): " MONITOR_ALL
    MONITOR_ALL=${MONITOR_ALL:-y}

    if [[ ! $MONITOR_ALL =~ ^[Yy]$ ]]; then
        echo ""
        echo "请输入要监控的容器名称(多个用空格分隔)"
        read -p "容器名称: " CONTAINER_NAMES
    fi

    echo ""
    read -p "是否自动清理旧镜像? (y/n, 默认: y): " CLEANUP
    CLEANUP=${CLEANUP:-y}
    [[ $CLEANUP =~ ^[Yy]$ ]] && CLEANUP="true" || CLEANUP="false"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "3️⃣  配置服务器 (★★★ 新增功能 ★★★)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    read -p "请输入服务器名称 (可选, 用于区分通知来源): " SERVER_NAME
    # 如果不为空，格式化一下
    if [ -n "$SERVER_NAME" ]; then
        print_info "通知将带上 [${SERVER_NAME}] 前缀"
    else
        print_info "不使用服务器名称前缀"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "4️⃣  配置安装目录"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    read -p "安装目录 (默认: $HOME/watchtower): " INSTALL_DIR
    INSTALL_DIR=${INSTALL_DIR:-$HOME/watchtower}
    
    # 简单的路径检查
    Verify_INSTALL_DIR=$(grep -qF "$INSTALL_DIR" /proc/mounts && echo "true" || echo "false")
    if [ "$Verify_INSTALL_DIR" = "true" ]; then
        print_warning "警告: $INSTALL_DIR 似乎位于一个独立的挂载点上。"
        read -p "如果这是 Docker-in-Docker 或 远程NFS，可能会导致问题。是否继续? (y/n, 默认: y): " continue_install
        if [[ ! $continue_install =~ ^[Yy]$ ]] && [ -n "$continue_install" ]; then
            print_error "安装已中止。"
            exit 1
        fi
    fi

    echo ""
    print_success "配置完成"
}

# --- 创建 docker-compose.yml (★★★ 修复点 ★★★) ---
create_docker_compose() {
    print_info "创建 docker-compose.yml..."
    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:
  # Watchtower - 容器更新服务
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
    environment:
      - WATCHTOWER_NOTIFICATIONS=
      - WATCHTOWER_NO_STARTUP_MESSAGE=true
      - TZ=Asia/Shanghai
      - WATCHTOWER_CLEANUP=${CLEANUP}
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_INCLUDE_STOPPED=false
      - WATCHTOWER_NO_RESTART=false
      - WATCHTOWER_TIMEOUT=10s
      - WATCHTOWER_POLL_INTERVAL=${POLL_INTERVAL}
      - WATCHTOWER_DEBUG=false
      - WATCHTOWER_LOG_LEVEL=info
EOF

    if [[ ! $MONITOR_ALL =~ ^[Yy]$ ]] && [ -n "$CONTAINER_NAMES" ]; then
        cat >> "$INSTALL_DIR/docker-compose.yml" << EOF
    command:
EOF
        for container in $CONTAINER_NAMES; do
            cat >> "$INSTALL_DIR/docker-compose.yml" << EOF
      - $container
EOF
        done
    fi

    cat >> "$INSTALL_DIR/docker-compose.yml" << EOF
    labels:
      - "com.centurylinklabs.watchtower.enable=false"

  # 通知服务 - 监控日志并发送中文通知
  watchtower-notifier:
    image: alpine:latest
    container_name: watchtower-notifier
    restart: unless-stopped
    network_mode: host
    depends_on:
      watchtower:
        condition: service_started
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./monitor.sh:/monitor.sh:ro
    environment:
      - TZ=Asia/Shanghai
      - BOT_TOKEN=${BOT_TOKEN}
      - CHAT_ID=${CHAT_ID}
      # ★★★ 新增 SERVER_NAME 环境变量 ★★★
      - SERVER_NAME=${SERVER_NAME}
    command: sh /monitor.sh
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
EOF
    print_success "配置文件已创建"
}

# --- 创建 monitor.sh (★★★ 修复点 ★★★) ---
create_monitor_script() {
    print_info "创建监控脚本 (v2.4)..."
    cat > "$INSTALL_DIR/monitor.sh" << 'MONITOR_SCRIPT'
#!/bin/sh

echo "正在安装依赖..."
apk add --no-cache curl docker-cli coreutils grep sed >/dev/null 2>&1

TELEGRAM_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

# ★★★ 修复点 v2.4: 定义服务器名称标签 ★★★
if [ -n "$SERVER_NAME" ]; then
    # 如果 SERVER_NAME 不为空, 则创建标签 (HTML加粗)
    SERVER_TAG="<b>[${SERVER_NAME}]</b> "
else
    # 否则标签为空
    SERVER_TAG=""
fi

send_telegram() {
    # 发送时自动带上标签
    # $1 是传入的消息体
    curl -s -X POST "$TELEGRAM_API" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":\"${SERVER_TAG}$1\",\"parse_mode\":\"HTML\"}" >/dev/null 2>&1
}

get_time() { date '+%Y-%m-%d %H:%M:%S'; }
get_version() { echo "$1" | grep -oE ':[^:]+$' | sed 's/://' || echo "latest"; }
get_image_name() { echo "$1" | sed 's/:.*$//'; }

echo "=========================================="
echo "Docker 容器监控通知服务 v2.4"
echo "服务器: ${SERVER_NAME:-N/A}"
echo "启动时间: $(get_time)"
echo "=========================================="
echo ""

# 修复点 v2.3: 增加等待 watchtower 启动的逻辑
echo "正在等待 watchtower 容器完全启动..."
while true; do
    if docker inspect -f '{{.State.Running}}' watchtower 2>/dev/null | grep -q "true"; then
        echo "Watchtower 已启动. 准备监控日志."
        break 
    else
        echo "Watchtower 尚未运行, 2 秒后重试..."
        sleep 2
    fi
done

# 修复点 v2.3: 仅在成功锁定日志后才发送启动通知
echo "服务已稳定，正在发送启动通知..."
# ★★★ 修复点 v2.4: 此处调用 send_telegram 时已自动带上前缀 ★★★
send_telegram "🚀 <b>容器监控服务已启动</b>
🕐 时间: $(get_time)
📊 状态: 正在监控容器更新"

echo "开始监控 Watchtower 日志..."

current_updating_image=""
current_container_name=""
old_image=""

# 监控 watchtower 日志
docker logs -f --tail 0 watchtower 2>&1 | while IFS= read -r line; do
    echo "[$(date '+%H:%M:%S')] $line"

    # 1. 发现新镜像
    if echo "$line" | grep -q "Found new"; then
        new_image=$(echo "$line" | grep -oE '[a-zA-Z0-9_.\-/]+:[a-zA-Z0-9_.\-]+' | grep -v "^[0-9][0-9]:[0-9][0-9]$" | head -n1)
        if [ -n "$new_image" ]; then
            current_updating_image="$new_image"
            echo "  → 发现新镜像: $new_image"
        fi
    fi

    # 2. 停止旧容器 (获取容器名和旧镜像)
    if echo "$line" | grep -q "Stopping /"; then
        container_name=$(echo "$line" | grep -oP '(?<=Stopping /)[a-zA-Z0-9_.\-]+' | head -n1)
        if [ -n "$container_name" ]; then
            current_container_name="$container_name"
            old_image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "")
            echo "  → 停止容器: $container_name"
            echo "  → 旧镜像: $old_image"
        fi
    fi
    
    # 3. 创建新容器 (备用)
    if echo "$line" | grep -q "Creating /"; then
        container_name=$(echo "$line" | grep -oP '(?<=Creating /)[a-zA-Z0-9_.\-]+' | head -n1)
        if [ -n "$container_name" ] && [ -z "$current_container_name" ]; then
            current_container_name="$container_name"
            echo "  → 创建容器: $container_name"
        fi
    fi

    # 4. 会话完成 (判断成功/失败)
    if echo "$line" | grep -q "Session done"; then
        updated=$(echo "$line" | grep -oP '(?<=Updated=)[0-9]+')
        failed=$(echo "$line" | grep -oP '(?<=Failed=)[0-9]+')
        
        if [ "$updated" -gt 0 ] && [ -n "$current_container_name" ]; then
            echo "  → 检查容器状态..."
            sleep 5 # 等待容器启动
            
            status=$(docker inspect -f '{{.State.Running}}' "$current_container_name" 2>/dev/null || echo "false")
            new_image=$(docker inspect --format='{{.Config.Image}}' "$current_container_name" 2>/dev/null || echo "$current_updating_image")
            
            old_ver=$(get_version "$old_image")
            new_ver=$(get_version "$new_image")
            img_name=$(get_image_name "$new_image")
            time=$(get_time)
            
            if [ "$status" = "true" ]; then
                send_telegram "🎉 <b>容器更新成功</b>
📦 容器: $current_container_name
🏷️ 镜像: $img_name
📌 旧版本: $old_ver
🆕 新版本: $new_ver
🕐 时间: $time
✅ 容器已成功更新并正常运行"
                echo "  ✓ 已发送更新成功通知"
            else
                send_telegram "❌ <b>容器启动失败</b>
📦 容器: $current_container_name
🏷️ 镜像: $img_name
🆕 版本: $new_ver
🕐 时间: $time
⚠️ 更新后无法启动
💡 检查: docker logs $current_container_name"
                echo "  ✓ 已发送启动失败通知"
            fi
            
            current_updating_image=""
            current_container_name=""
            old_image=""
        fi
    fi

    # 5. 捕获错误
    if echo "$line" | grep -qiE "level=error|level=fatal"; then
        if [ -n "$current_container_name" ]; then
            error=$(echo "$line" | sed 's/.*msg="\([^"]*\)".*/\1/' | head -c 150) # 尝试提取错误
            send_telegram "❌ <b>容器更新失败</b>
📦 容器: $current_container_name
⚠️ 错误: $error
🕐 时间: $(get_time)"
            echo "  ✓ 已发送更新失败通知"
            
            current_updating_image=""
            current_container_name=""
            old_image=""
        fi
    fi
done
MONITOR_SCRIPT
    chmod +x "$INSTALL_DIR/monitor.sh"
    print_success "监控脚本已创建"
}

# --- 创建 manage.sh ---
create_management_script() {
    print_info "创建管理脚本..."
    cat > "$INSTALL_DIR/manage.sh" << 'MANAGE_SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"

# 自动检测使用 docker compose 还是 docker-compose
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo "错误：未找到 docker compose 或 docker-compose"
    exit 1
fi

case "$1" in
    start)   $COMPOSE_CMD up -d && echo "✓ 服务已启动" ;;
    stop)    $COMPOSE_CMD down && echo "✓ 服务已停止" ;;
    restart) $COMPOSE_CMD restart && echo "✓ 服务已重启" ;;
    logs)    $COMPOSE_CMD logs -f ;;
    status)  $COMPOSE_CMD ps ;;
    update)  $COMPOSE_CMD pull && $COMPOSE_CMD up -d && echo "✓ 服务已更新" ;;
    test)
        echo "发送测试通知 (将重启 watchtower-notifier)..."
        # 重启 notifier 会触发启动通知
        $COMPOSE_CMD restart watchtower-notifier
        echo "✓ 已触发重启，请等待几秒钟查看 Telegram 启动通知"
        ;;
    *)
        echo "用法: $0 {start|stop|restart|logs|status|update|test}"
        echo ""
        echo "  start   - 启动服务"
        echo "  stop    - 停止服务"
        echo "  restart - 重启服务"
        echo "  logs    - 查看日志"
        echo "  status  - 查看状态"
        echo "  update  - 更新服务 (指更新 watchtower/notifier 本身)"
        echo "  test    - 发送测试通知 (通过重启 notifier)"
        exit 1
        ;;
esac
MANAGE_SCRIPT
    chmod +x "$INSTALL_DIR/manage.sh"
    print_success "管理脚本已创建"
}

# --- 启动服务 ---
start_service() {
    print_info "启动服务..."
    cd "$INSTALL_DIR"

    print_info "正在强制清理旧容器 (如果存在)..."
    docker stop watchtower-notifier &>/dev/null || true
    docker rm watchtower-notifier &>/dev/null || true
    docker stop watchtower &>/dev/null || true
    docker rm watchtower &>/dev/null || true
    
    print_info "正在启动新服务 (v2.4)..."
    
    # 自动检测 compose 命令
    COMPOSE_CMD=""
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        print_error "未找到 Docker Compose 命令"
        exit 1
    fi

    if $COMPOSE_CMD up -d; then
        print_success "服务启动成功"
        sleep 3
    else
        print_error "服务启动失败"
        exit 1
    fi
}

# --- 显示完成信息 ---
show_completion() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_success "🎉 部署完成！"
    echo ""
    echo "📁 安装目录: $INSTALL_DIR"
    echo ""
    if [ -n "$SERVER_NAME" ]; then
        echo "📱 你应该很快会收到带 [${SERVER_NAME}] 前缀的 Telegram 启动通知"
    else
        echo "📱 你应该很快会收到 Telegram 启动通知"
    fi
    echo ""
    echo "🔧 管理命令:"
    echo "   cd $INSTALL_DIR"
    echo "   ./manage.sh logs      # 查看日志"
    echo "   ./manage.sh restart   # 重启服务"
    echo "   ./manage.sh test      # 发送测试通知"
    echo "   ./manage.sh status    # 查看状态"
    echo ""
    echo "📝 提示:"
    echo "   • 仅在容器更新成功/失败时发送通知"
    echo "   • 检查间隔: $((POLL_INTERVAL / 60)) 分钟"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# --- 主函数 ---
main() {
    show_banner
    check_requirements
    get_user_input
    create_docker_compose
    create_monitor_script
    create_management_script
    start_service
    show_completion
}

main