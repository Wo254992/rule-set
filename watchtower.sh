#!/bin/bash
# Docker 容器监控 - 一键部署脚本（v3.3.0 终极版）
# 功能: 监控容器更新，发送中文 Telegram 通知
# 重构: 所有逻辑内联到主循环，彻底解决变量传递问题

# --- 颜色定义 ---
set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
║   Docker 容器监控部署脚本 v3.3.0 终极版           ║
║   Watchtower + Telegram 中文通知                   ║
║   重构: 内联所有逻辑，彻底解决变量传递问题        ║
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

# --- 列出所有运行中的容器供选择 ---
select_containers() {
    print_info "获取运行中的容器列表..."

    local containers=($(docker ps --format '{{.Names}}' | grep -v "^watchtower" || true))

    if [ ${#containers[@]} -eq 0 ]; then
        print_warning "当前没有运行中的容器"
        echo ""
        read -p "是否继续安装？(稍后可手动修改配置) [y/n]: " continue_install
        if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
            exit 0
        fi
        CONTAINER_NAMES=""
        return
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "发现以下容器 (共 ${#containers[@]} 个):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local index=1
    for container in "${containers[@]}"; do
        local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "unknown")
        local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        printf "${CYAN}%2d)${NC} %-25s ${YELLOW}[%s]${NC} %s\n" "$index" "$container" "$status" "$image"
        ((index++))
    done

    echo ""
    echo "请选择要监控的容器 (支持多选):"
    echo "  • 输入编号，多个用空格分隔 (例如: 1 3 5)"
    echo "  • 输入 'all' 监控所有容器"
    echo "  • 输入容器名称 (例如: nginx mysql)"
    echo ""
    read -p "请选择: " selection

    if [[ "$selection" == "all" ]]; then
        CONTAINER_NAMES=""
        print_info "已选择监控所有容器"
        return
    fi

    local selected_containers=()
    for item in $selection; do
        if [[ "$item" =~ ^[0-9]+$ ]]; then
            if [ "$item" -ge 1 ] && [ "$item" -le "${#containers[@]}" ]; then
                selected_containers+=("${containers[$((item-1))]}")
            else
                print_warning "忽略无效编号: $item"
            fi
        else
            if [[ " ${containers[*]} " =~ " ${item} " ]]; then
                selected_containers+=("$item")
            else
                print_warning "容器 '$item' 不在运行列表中，已忽略"
            fi
        fi
    done

    if [ ${#selected_containers[@]} -eq 0 ]; then
        print_error "未选择任何有效容器"
        exit 1
    fi

    CONTAINER_NAMES="${selected_containers[*]}"
    echo ""
    print_success "已选择 ${#selected_containers[@]} 个容器:"
    for c in "${selected_containers[@]}"; do
        echo "  ✓ $c"
    done
}

# --- 获取用户输入 ---
get_user_input() {
    print_info "开始配置..."
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1️⃣  配置 Telegram Bot"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    while true; do
        read -p "请输入 Bot Token: " BOT_TOKEN
        if [ -n "$BOT_TOKEN" ]; then
            break
        fi
        print_warning "不能为空，请重新输入"
    done

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

    if [[ ! "$MONITOR_ALL" =~ ^[Yy]$ ]]; then
        echo ""
        select_containers
    else
        CONTAINER_NAMES=""
    fi

    echo ""
    read -p "是否自动清理旧镜像? (y/n, 默认: y): " CLEANUP
    CLEANUP=${CLEANUP:-y}
    [[ "$CLEANUP" =~ ^[Yy]$ ]] && CLEANUP="true" || CLEANUP="false"

    echo ""
    read -p "是否启用自动回滚? (更新失败时恢复旧版本, y/n, 默认: y): " ENABLE_ROLLBACK
    ENABLE_ROLLBACK=${ENABLE_ROLLBACK:-y}
    [[ "$ENABLE_ROLLBACK" =~ ^[Yy]$ ]] && ENABLE_ROLLBACK="true" || ENABLE_ROLLBACK="false"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "3️⃣  配置服务器"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    read -p "请输入服务器名称 (可选, 用于区分通知来源): " SERVER_NAME
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

    echo ""
    print_success "配置完成"
}

# --- 创建 .env 文件 ---
create_env_file() {
    print_info "创建 .env 配置文件..."
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/.env" << EOF
# Telegram 配置
BOT_TOKEN=${BOT_TOKEN}
CHAT_ID=${CHAT_ID}

# 服务器配置
SERVER_NAME=${SERVER_NAME}

# 监控配置
POLL_INTERVAL=${POLL_INTERVAL}
CLEANUP=${CLEANUP}
ENABLE_ROLLBACK=${ENABLE_ROLLBACK}
EOF
    chmod 600 "$INSTALL_DIR/.env"
    print_success ".env 文件已创建并设置安全权限"
}

# --- 创建 .gitignore ---
create_gitignore() {
    cat > "$INSTALL_DIR/.gitignore" << EOF
.env
*.log
data/
backups/
EOF
}

# --- 创建数据目录 ---
create_data_dir() {
    print_info "创建数据目录..."
    mkdir -p "$INSTALL_DIR/data"
    print_success "数据目录已创建"
}

# --- 创建 docker-compose.yml ---
create_docker_compose() {
    print_info "创建 docker-compose.yml..."
    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:
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
      - WATCHTOWER_CLEANUP=\${CLEANUP}
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_INCLUDE_STOPPED=false
      - WATCHTOWER_NO_RESTART=false
      - WATCHTOWER_TIMEOUT=10s
      - WATCHTOWER_POLL_INTERVAL=\${POLL_INTERVAL}
      - WATCHTOWER_DEBUG=false
      - WATCHTOWER_LOG_LEVEL=info
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "sh", "-c", "ps aux | grep -v grep | grep -q watchtower"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
EOF

    if [[ ! "$MONITOR_ALL" =~ ^[Yy]$ ]] && [ -n "$CONTAINER_NAMES" ]; then
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
      - ./data:/data
    environment:
      - TZ=Asia/Shanghai
      - BOT_TOKEN=\${BOT_TOKEN}
      - CHAT_ID=\${CHAT_ID}
      - SERVER_NAME=\${SERVER_NAME}
      - ENABLE_ROLLBACK=\${ENABLE_ROLLBACK}
      - POLL_INTERVAL=\${POLL_INTERVAL}
    command: sh /monitor.sh
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "sh", "-c", "ps aux | grep -v grep | grep -q 'docker logs'"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 15s
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
EOF
    print_success "配置文件已创建"
}

# --- 创建 monitor.sh (v3.2.1 修复版) ---
create_monitor_script() {
    print_info "创建监控脚本..."
    cat > "$INSTALL_DIR/monitor.sh" << 'MONITOR_SCRIPT'
#!/bin/sh

echo "正在安装依赖..."
apk add --no-cache curl docker-cli coreutils grep sed tzdata jq >/dev/null 2>&1

TELEGRAM_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
STATE_FILE="/data/container_state.db"
TEMP_LOG="/tmp/watchtower_events.log"

# 确保数据目录存在
mkdir -p /data

if [ -n "$SERVER_NAME" ]; then
    SERVER_TAG="<b>[${SERVER_NAME}]</b> "
else
    SERVER_TAG=""
fi

send_telegram() {
    message="$1"
    max_retries=3
    retry=0
    wait_time=5

    while [ $retry -lt $max_retries ]; do
        response=$(curl -s -w "\n%{http_code}" -X POST "$TELEGRAM_API" \
            --data-urlencode "chat_id=${CHAT_ID}" \
            --data-urlencode "text=${SERVER_TAG}${message}" \
            --data-urlencode "parse_mode=HTML" \
            --connect-timeout 10 --max-time 30 2>&1)
        
        curl_exit_code=$?
        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
        
        if [ $curl_exit_code -ne 0 ]; then
            echo "  ✗ Curl 执行失败 (退出码: $curl_exit_code)" >&2
        elif [ "$http_code" = "200" ]; then
            if echo "$body" | grep -q '"ok":true'; then
                echo "  ✓ Telegram 通知发送成功"
                return 0
            else
                error_desc=$(echo "$body" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')
                echo "  ✗ Telegram API 错误: ${error_desc:-未知错误}" >&2
                
                if echo "$error_desc" | grep -qiE "chat not found|bot was blocked|user is deactivated"; then
                    echo "  ✗ 致命错误，停止重试" >&2
                    return 1
                fi
            fi
        else
            echo "  ✗ HTTP 请求失败 (状态码: $http_code)" >&2
        fi

        retry=$((retry + 1))
        if [ $retry -lt $max_retries ]; then
            echo "  ↻ ${wait_time}秒后重试 ($retry/$max_retries)..." >&2
            sleep $wait_time
            wait_time=$((wait_time * 2))
        fi
    done

    echo "  ✗ Telegram 通知最终失败 (已重试 $max_retries 次)" >&2
    return 1
}

get_time() { date '+%Y-%m-%d %H:%M:%S'; }
get_image_name() { echo "$1" | sed 's/:.*$//'; }
get_short_id() { echo "$1" | sed 's/sha256://' | head -c 12 || echo "unknown"; }

get_danmu_version() {
    container_name="$1"
    check_running="${2:-true}"
    
    if ! echo "$container_name" | grep -qE "danmu-api|danmu_api"; then
        echo ""
        return
    fi
    
    version=""
    
    if [ "$check_running" = "true" ]; then
        for i in $(seq 1 30); do
            if docker exec "$container_name" test -f /app/danmu_api/configs/globals.js 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi
    
    version=$(docker exec "$container_name" cat /app/danmu_api/configs/globals.js 2>/dev/null | \
              grep -m 1 "VERSION:" | sed -E "s/.*VERSION: '([^']+)'.*/\1/" 2>/dev/null || echo "")
    
    if [ -z "$version" ]; then
        image_id=$(docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null)
        if [ -n "$image_id" ] && [ "$image_id" != "sha256:unknown" ]; then
            version=$(docker run --rm --entrypoint cat "$image_id" \
                      /app/danmu_api/configs/globals.js 2>/dev/null | \
                      grep -m 1 "VERSION:" | sed -E "s/.*VERSION: '([^']+)'.*/\1/" 2>/dev/null || echo "")
        fi
    fi
    
    echo "$version"
}

format_version() {
    img_tag="$1"
    img_id="$2"
    container_name="$3"

    tag=$(echo "$img_tag" | grep -oE ':[^:]+$' | sed 's/://' || echo "latest")
    id_short=$(get_short_id "$img_id")
    
    if echo "$container_name" | grep -qE "danmu-api|danmu_api"; then
        real_version=$(get_danmu_version "$container_name")
        if [ -n "$real_version" ]; then
            echo "v${real_version} (${id_short})"
            return
        fi
    fi

    echo "$tag ($id_short)"
}

save_container_state() {
    container="$1"
    image_tag="$2"
    image_id="$3"
    version_info="$4"

    # 修复: 确保文件可写且格式正确
    if [ ! -f "$STATE_FILE" ]; then
        touch "$STATE_FILE" || {
            echo "  ✗ 无法创建状态文件" >&2
            return 1
        }
    fi

    echo "$container|$image_tag|$image_id|$version_info|$(date +%s)" >> "$STATE_FILE"
}

get_container_state() {
    container="$1"

    if [ ! -f "$STATE_FILE" ]; then
        echo "unknown:tag|sha256:unknown|"
        return
    fi

    state=$(grep "^${container}|" "$STATE_FILE" 2>/dev/null | tail -n 1)
    if [ -z "$state" ]; then
        echo "unknown:tag|sha256:unknown|"
        return
    fi

    echo "$state" | cut -d'|' -f2,3,4
}

rollback_container() {
    container="$1"
    old_tag="$2"
    old_id="$3"

    echo "  → 正在执行回滚操作..."

    config=$(docker inspect "$container" 2>/dev/null)
    if [ -z "$config" ]; then
        echo "  ✗ 无法获取容器配置，回滚失败"
        return 1
    fi

    docker stop "$container" >/dev/null 2>&1 || true
    docker rm "$container" >/dev/null 2>&1 || true

    echo "  → 尝试使用旧镜像 $old_id 重启容器..."

    docker tag "$old_id" "${old_tag}-rollback" 2>/dev/null || {
        echo "  ✗ 旧镜像不存在，无法回滚"
        return 1
    }

    echo "  ✓ 回滚操作已触发，请手动检查容器状态"
    return 0
}

cleanup_old_states() {
    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    # 修复: 使用更健壮的日期计算
    cutoff_time=$(( $(date +%s) - 604800 ))  # 7天前
    temp_file="${STATE_FILE}.tmp"

    # 清空临时文件
    : > "$temp_file"

    if [ -s "$STATE_FILE" ]; then
        while IFS='|' read -r container image_tag image_id version_info timestamp || [ -n "$container" ]; do
            [ -z "$container" ] && continue
            
            # 验证 timestamp 格式
            if echo "$timestamp" | grep -qE '^[0-9]+$' && [ "$timestamp" -ge "$cutoff_time" ]; then
                echo "$container|$image_tag|$image_id|$version_info|$timestamp" >> "$temp_file"
            fi
        done < "$STATE_FILE"
    fi

    if [ -f "$temp_file" ]; then
        mv "$temp_file" "$STATE_FILE" 2>/dev/null || {
            echo "  ✗ 无法更新状态文件" >&2
            rm -f "$temp_file"
        }
    fi
}

process_container_update() {
    container_name="$1"
    old_tag_full="$2"
    old_id_full="$3"
    old_version_info="$4"

    echo "  → 等待容器 $container_name 更新完成..."
    sleep 5

    echo "  → 检查容器启动状态..."
    for i in $(seq 1 60); do
        status=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")
        if [ "$status" = "true" ]; then
            echo "  → 容器已启动，等待服务就绪..."
            sleep 5
            break
        fi
        sleep 1
    done

    status=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")
    new_tag_full=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "unknown:tag")
    new_id_full=$(docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null || echo "sha256:unknown")

    new_version_info=""
    if echo "$container_name" | grep -qE "danmu-api|danmu_api"; then
        if [ "$status" = "true" ]; then
            echo "  → 正在读取 danmu-api 版本信息..."
            new_version_info=$(get_danmu_version "$container_name" "true")
            
            if [ -z "$new_version_info" ]; then
                echo "  → 首次读取失败，5秒后重试..."
                sleep 5
                new_version_info=$(get_danmu_version "$container_name" "true")
            fi
            
            if [ -n "$new_version_info" ]; then
                echo "  → 检测到版本: v${new_version_info}"
            else
                echo "  → 警告: 无法读取版本号，将使用镜像标签"
            fi
        fi
    fi
    
    save_container_state "$container_name" "$new_tag_full" "$new_id_full" "$new_version_info"

    img_name=$(get_image_name "$new_tag_full")
    time=$(get_time)

    old_ver_display=$(format_version "$old_tag_full" "$old_id_full" "$container_name")
    new_ver_display=$(format_version "$new_tag_full" "$new_id_full" "$container_name")
    
    if [ -n "$old_version_info" ] || [ -n "$new_version_info" ]; then
        old_id_short=$(get_short_id "$old_id_full")
        new_id_short=$(get_short_id "$new_id_full")
        
        if [ -n "$old_version_info" ]; then
            old_ver_display="v${old_version_info} (${old_id_short})"
        fi
        if [ -n "$new_version_info" ]; then
            new_ver_display="v${new_version_info} (${new_id_short})"
        fi
    fi

    if [ "$status" = "true" ]; then
        success_message="✨ <b>容器更新成功</b>

━━━━━━━━━━━━━━━━━━━━
📦 <b>容器名称</b>
   <code>${container_name}</code>

🎯 <b>镜像信息</b>
   <code>${img_name}</code>

🔄 <b>版本变更</b>
   <code>${old_ver_display}</code>
   ➜
   <code>${new_ver_display}</code>

⏰ <b>更新时间</b>
   <code>${time}</code>
━━━━━━━━━━━━━━━━━━━━

✅ 容器已成功启动并运行正常"

        echo "  → 发送成功通知到 Telegram..."
        send_telegram "$success_message"
    else
        rollback_msg=""
        if [ "$ENABLE_ROLLBACK" = "true" ]; then
            if rollback_container "$container_name" "$old_tag_full" "$old_id_full"; then
                rollback_msg="
🔄 已尝试自动回滚到旧版本"
            else
                rollback_msg="
⚠️ 自动回滚失败，请手动处理"
            fi
        fi
        
        failure_message="❌ <b>容器启动失败</b>

━━━━━━━━━━━━━━━━━━━━
📦 <b>容器名称</b>
   <code>${container_name}</code>

🎯 <b>镜像信息</b>
   <code>${img_name}</code>

🔄 <b>版本变更</b>
   旧: <code>${old_ver_display}</code>
   新: <code>${new_ver_display}</code>

⏰ <b>更新时间</b>
   <code>${time}</code>
━━━━━━━━━━━━━━━━━━━━

⚠️ 更新后无法启动${rollback_msg}
💡 检查: <code>docker logs ${container_name}</code>"

        echo "  → 发送失败通知到 Telegram..."
        send_telegram "$failure_message"
    fi
}

echo "=========================================="
echo "Docker 容器监控通知服务 v3.3.0"
echo "服务器: ${SERVER_NAME:-N/A}"
echo "启动时间: $(get_time)"
echo "回滚功能: ${ENABLE_ROLLBACK:-false}"
echo "=========================================="
echo ""

cleanup_old_states

echo "正在等待 watchtower 容器完全启动..."
while true; do
    if docker inspect -f '{{.State.Running}}' watchtower 2>/dev/null | grep -q "true"; then
        echo "Watchtower 已启动，准备监控日志"
        break
    else
        sleep 2
    fi
done

echo "正在初始化容器状态数据库..."
for container in $(docker ps --format '{{.Names}}'); do
    if [ "$container" = "watchtower" ] || [ "$container" = "watchtower-notifier" ]; then
        continue
    fi

    image_tag=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "unknown:tag")
    image_id=$(docker inspect --format='{{.Image}}' "$container" 2>/dev/null || echo "sha256:unknown")
    
    version_info=$(get_danmu_version "$container" "false")
    
    save_container_state "$container" "$image_tag" "$image_id" "$version_info"
    
    if [ -n "$version_info" ]; then
        echo "  → 已保存 $container 的状态到数据库 (版本: v${version_info})"
    else
        echo "  → 已保存 $container 的状态到数据库"
    fi
done

container_count=$(docker ps --format '{{.Names}}' | grep -vE '^watchtower|^watchtower-notifier$' | wc -l)
echo "初始化完成，已记录 ${container_count} 个容器状态"

sleep 3

monitored_containers=$(docker exec watchtower ps aux 2>/dev/null | \
    grep "watchtower" | \
    grep -v "grep" | \
    sed 's/.*watchtower//' | \
    tr ' ' '\n' | \
    grep -v "^$" | \
    grep -v "^--" | \
    tail -n +2 || true)

if [ -z "$monitored_containers" ]; then
    monitored_containers=$(docker container inspect watchtower --format='{{range .Args}}{{println .}}{{end}}' 2>/dev/null | \
        grep -v "^--" | \
        grep -v "^$" || true)
fi

if [ -n "$monitored_containers" ]; then
    container_count=$(echo "$monitored_containers" | wc -l)
    monitor_list="<b>监控容器列表:</b>"
    for c in $monitored_containers; do
        monitor_list="$monitor_list
   • <code>$c</code>"
    done
else
    container_count=$(docker ps --format '{{.Names}}' | grep -vE "^watchtower$|^watchtower-notifier$" | wc -l)
    monitor_list="<b>监控范围:</b> 全部容器"
fi

startup_message="🚀 <b>监控服务启动成功</b>

━━━━━━━━━━━━━━━━━━━━
📊 <b>服务信息</b>
   版本: <code>v3.3.0</code>

🎯 <b>监控状态</b>
   容器数: <code>${container_count}</code>
   状态库: <code>已初始化</code>

${monitor_list}

🔄 <b>功能配置</b>
   自动回滚: <code>${ENABLE_ROLLBACK:-禁用}</code>
   检查间隔: <code>$((POLL_INTERVAL / 60))分钟</code>

⏰ <b>启动时间</b>
   <code>$(get_time)</code>
━━━━━━━━━━━━━━━━━━━━

✅ 服务正常运行中"

send_telegram "$startup_message"

echo "开始监控 Watchtower 日志..."

# 清理函数
cleanup() {
    echo "收到退出信号，正在清理..."
    rm -f /tmp/session_data.txt
    exit 0
}

trap cleanup INT TERM

# 主循环 - 直接处理，不使用管道
docker logs -f --tail 0 watchtower 2>&1 | while IFS= read -r line; do
    echo "[$(date '+%H:%M:%S')] $line"

    if echo "$line" | grep -q "Stopping /"; then
        container_name=$(echo "$line" | sed -n 's/.*Stopping \/\([^ ]*\).*/\1/p' | head -n1)
        if [ -n "$container_name" ]; then
            echo "[$(date '+%H:%M:%S')] → 捕获到停止: $container_name"

            old_state=$(get_container_state "$container_name")
            old_image_tag=$(echo "$old_state" | cut -d'|' -f1)
            old_image_id=$(echo "$old_state" | cut -d'|' -f2)
            old_version_info=$(echo "$old_state" | cut -d'|' -f3)

            # 写入临时文件存储会话数据
            echo "${container_name}|${old_image_tag}|${old_image_id}|${old_version_info}" >> /tmp/session_data.txt

            if [ -n "$old_version_info" ]; then
                echo "[$(date '+%H:%M:%S')]   → 已暂存旧信息: $old_image_tag ($old_image_id) v${old_version_info}"
            else
                echo "[$(date '+%H:%M:%S')]   → 已暂存旧信息: $old_image_tag ($old_image_id)"
            fi
        fi
    fi

    if echo "$line" | grep -q "Session done"; then
        updated=$(echo "$line" | grep -oP '(?<=Updated=)[0-9]+' || echo "0")

        echo "[$(date '+%H:%M:%S')] → Session 完成: Updated=$updated"

        if [ "$updated" -gt 0 ] && [ -f /tmp/session_data.txt ]; then
            echo "[$(date '+%H:%M:%S')] → 发现 ${updated} 处更新，立即处理..."
            
            # 显示会话数据
            echo "[$(date '+%H:%M:%S')] → 会话数据:"
            while IFS='|' read -r c_name old_tag old_id old_ver; do
                echo "[$(date '+%H:%M:%S')]     $c_name | $old_tag"
            done < /tmp/session_data.txt
            
            # 直接在这里处理每个容器（不依赖外部变量）
            while IFS='|' read -r container_name old_tag_full old_id_full old_version_info; do
                [ -z "$container_name" ] && continue
                
                echo "[$(date '+%H:%M:%S')] → 处理容器: $container_name"
                echo "[$(date '+%H:%M:%S')]   → 等待容器更新完成..."
                sleep 5
                
                # 检查容器状态
                for i in $(seq 1 60); do
                    status=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")
                    if [ "$status" = "true" ]; then
                        echo "[$(date '+%H:%M:%S')]   → 容器已启动"
                        sleep 5
                        break
                    fi
                    sleep 1
                done
                
                # 获取新镜像信息
                status=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "false")
                new_tag_full=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "unknown:tag")
                new_id_full=$(docker inspect --format='{{.Image}}' "$container_name" 2>/dev/null || echo "sha256:unknown")
                
                # 获取新版本信息（danmu-api）
                new_version_info=""
                if echo "$container_name" | grep -qE "danmu-api|danmu_api"; then
                    if [ "$status" = "true" ]; then
                        echo "[$(date '+%H:%M:%S')]   → 读取 danmu-api 版本..."
                        for retry in 1 2; do
                            for i in $(seq 1 30); do
                                if docker exec "$container_name" test -f /app/danmu_api/configs/globals.js 2>/dev/null; then
                                    break
                                fi
                                sleep 1
                            done
                            
                            new_version_info=$(docker exec "$container_name" cat /app/danmu_api/configs/globals.js 2>/dev/null | \
                                             grep -m 1 "VERSION:" | sed -E "s/.*VERSION: '([^']+)'.*/\1/" 2>/dev/null || echo "")
                            
                            if [ -n "$new_version_info" ]; then
                                echo "[$(date '+%H:%M:%S')]   → 检测到版本: v${new_version_info}"
                                break
                            elif [ $retry -eq 1 ]; then
                                echo "[$(date '+%H:%M:%S')]   → 首次读取失败，5秒后重试..."
                                sleep 5
                            fi
                        done
                    fi
                fi
                
                # 保存新状态
                echo "$container_name|$new_tag_full|$new_id_full|$new_version_info|$(date +%s)" >> "$STATE_FILE"
                
                # 格式化版本显示
                img_name=$(echo "$new_tag_full" | sed 's/:.*$//')
                time=$(date '+%Y-%m-%d %H:%M:%S')
                
                old_tag=$(echo "$old_tag_full" | grep -oE ':[^:]+$' | sed 's/://' || echo "latest")
                new_tag=$(echo "$new_tag_full" | grep -oE ':[^:]+$' | sed 's/://' || echo "latest")
                old_id_short=$(echo "$old_id_full" | sed 's/sha256://' | head -c 12)
                new_id_short=$(echo "$new_id_full" | sed 's/sha256://' | head -c 12)
                
                if [ -n "$old_version_info" ]; then
                    old_ver_display="v${old_version_info} (${old_id_short})"
                else
                    old_ver_display="$old_tag ($old_id_short)"
                fi
                
                if [ -n "$new_version_info" ]; then
                    new_ver_display="v${new_version_info} (${new_id_short})"
                else
                    new_ver_display="$new_tag ($new_id_short)"
                fi
                
                # 发送通知
                if [ "$status" = "true" ]; then
                    message="✨ <b>容器更新成功</b>

━━━━━━━━━━━━━━━━━━━━
📦 <b>容器名称</b>
   <code>${container_name}</code>

🎯 <b>镜像信息</b>
   <code>${img_name}</code>

🔄 <b>版本变更</b>
   <code>${old_ver_display}</code>
   ➜
   <code>${new_ver_display}</code>

⏰ <b>更新时间</b>
   <code>${time}</code>
━━━━━━━━━━━━━━━━━━━━

✅ 容器已成功启动并运行正常"
                    
                    echo "[$(date '+%H:%M:%S')]   → 发送成功通知..."
                else
                    message="❌ <b>容器启动失败</b>

━━━━━━━━━━━━━━━━━━━━
📦 <b>容器名称</b>
   <code>${container_name}</code>

🎯 <b>镜像信息</b>
   <code>${img_name}</code>

🔄 <b>版本变更</b>
   旧: <code>${old_ver_display}</code>
   新: <code>${new_ver_display}</code>

⏰ <b>更新时间</b>
   <code>${time}</code>
━━━━━━━━━━━━━━━━━━━━

⚠️ 更新后无法启动
💡 检查: <code>docker logs ${container_name}</code>"
                    
                    echo "[$(date '+%H:%M:%S')]   → 发送失败通知..."
                fi
                
                # 发送 Telegram 消息
                send_telegram "$message"
                
            done < /tmp/session_data.txt
            
            rm -f /tmp/session_data.txt
            echo "[$(date '+%H:%M:%S')] → 所有通知已处理完成"
            
        elif [ "$updated" -eq 0 ]; then
            rm -f /tmp/session_data.txt 2>/dev/null
        fi
    fi

    # 修复: 更精确的错误检测
    if echo "$line" | grep -qiE "level=error.*fatal|level=fatal"; then
        # 排除常见非关键错误
        if echo "$line" | grep -qiE "Skipping|Already up to date|No new images|connection refused.*timeout"; then
            continue
        fi
        
        # 提取容器名
        container_name=$(echo "$line" | sed -n 's/.*container[=: ]\+\([a-zA-Z0-9_.\-]\+\).*/\1/p' | head -n1)
        
        # 提取错误信息
        error=$(echo "$line" | sed -n 's/.*msg="\([^"]*\)".*/\1/p' | head -c 200)
        [ -z "$error" ] && error=$(echo "$line" | grep -oE "error=.*" | head -c 200)
        [ -z "$error" ] && error=$(echo "$line" | head -c 200)

                    # 只对真实容器发送通知
        if [ -n "$container_name" ] && [ "$container_name" != "watchtower" ] && [ "$container_name" != "watchtower-notifier" ]; then
            send_telegram "⚠️ <b>Watchtower 严重错误</b>

━━━━━━━━━━━━━━━━━━━━
📦 <b>容器</b>: <code>$container_name</code>
🔴 <b>错误</b>: <code>$error</code>
🕐 <b>时间</b>: <code>$(get_time)</code>
━━━━━━━━━━━━━━━━━━━━"
        fi
    fi
done

# 这个不会执行到，因为 docker logs -f 会一直运行
cleanup
MONITOR_SCRIPT
    chmod +x "$INSTALL_DIR/monitor.sh"
    print_success "监控脚本已创建"
}

# --- 创建全局管理脚本 ---
create_global_manage_script() {
    print_info "创建全局管理快捷方式..."

    cat > "$INSTALL_DIR/manage-global.sh" << GLOBAL_SCRIPT
#!/bin/bash
# 全局管理脚本 - 可在任意目录调用
cd "$INSTALL_DIR" && ./manage.sh "\$@"
GLOBAL_SCRIPT
    chmod +x "$INSTALL_DIR/manage-global.sh"

    local link_created=false

    if [ -w "/usr/local/bin" ]; then
        ln -sf "$INSTALL_DIR/manage-global.sh" "/usr/local/bin/manage" 2>/dev/null && link_created=true
    fi

    if [ "$link_created" = false ]; then
        print_warning "无法自动创建全局命令，请手动设置："
        echo ""
        echo "方式 1: 添加别名 (推荐)"
        echo "  echo 'alias manage=\"$INSTALL_DIR/manage.sh\"' >> ~/.bashrc"
        echo "  source ~/.bashrc"
        echo ""
        echo "方式 2: 手动创建符号链接 (需要 sudo)"
        echo "  sudo ln -sf $INSTALL_DIR/manage-global.sh /usr/local/bin/manage"
        echo ""
    else
        print_success "全局命令已创建，可在任意目录运行: manage"
    fi
}

# --- 创建管理脚本 ---
create_management_script() {
    print_info "创建管理脚本..."
    cat > "$INSTALL_DIR/manage.sh" << 'MANAGE_SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}错误: 未找到 docker compose 或 docker-compose${NC}"
    exit 1
fi

show_menu() {
    clear
    cat << "EOF"
╔════════════════════════════════════════════════════╗
║                                                    ║
║       Docker 容器监控 - 管理菜单 v3.3.0            ║
║                                                    ║
╚════════════════════════════════════════════════════╝
EOF
    echo ""
    echo -e "${CYAN}[服务管理]${NC}"
    echo "  1) 启动服务"
    echo "  2) 停止服务"
    echo "  3) 重启服务"
    echo "  4) 查看状态"
    echo ""
    echo -e "${CYAN}[日志查看]${NC}"
    echo "  5) 查看所有日志"
    echo "  6) 查看通知服务日志"
    echo "  7) 查看 Watchtower 日志"
    echo ""
    echo -e "${CYAN}[维护操作]${NC}"
    echo "  8) 更新服务镜像"
    echo "  9) 发送测试通知"
    echo " 10) 详细健康检查"
    echo " 11) 备份配置文件"
    echo " 12) 清理状态数据库"
    echo ""
    echo -e "${CYAN}[系统操作]${NC}"
    echo " 13) 查看配置信息"
    echo " 14) 编辑监控容器列表"
    echo "  0) 退出"
    echo ""
    echo "════════════════════════════════════════════════════"
}

execute_action() {
    case $1 in
        1)
            echo -e "${BLUE}[操作] 启动服务...${NC}"
            $COMPOSE_CMD up -d && echo -e "${GREEN}✓ 服务已启动${NC}" || echo -e "${RED}✗ 启动失败${NC}"
            ;;
        2)
            echo -e "${BLUE}[操作] 停止服务...${NC}"
            $COMPOSE_CMD down && echo -e "${GREEN}✓ 服务已停止${NC}" || echo -e "${RED}✗ 停止失败${NC}"
            ;;
        3)
            echo -e "${BLUE}[操作] 重启服务...${NC}"
            $COMPOSE_CMD restart && echo -e "${GREEN}✓ 服务已重启${NC}" || echo -e "${RED}✗ 重启失败${NC}"
            ;;
        4)
            echo -e "${BLUE}[信息] 服务状态${NC}"
            echo ""
            $COMPOSE_CMD ps
            echo ""
            echo -e "${CYAN}健康状态:${NC}"
            docker inspect --format='{{.Name}}: {{if .State.Health}}{{.State.Health.Status}}{{else}}N/A{{end}}' watchtower watchtower-notifier 2>/dev/null | sed 's/\///g' || echo "无健康检查信息"
            ;;
        5)
            echo -e "${BLUE}[日志] 查看所有日志 (Ctrl+C 退出)${NC}"
            echo ""
            $COMPOSE_CMD logs -f
            ;;
        6)
            echo -e "${BLUE}[日志] 查看通知服务日志 (Ctrl+C 退出)${NC}"
            echo ""
            $COMPOSE_CMD logs -f watchtower-notifier
            ;;
        7)
            echo -e "${BLUE}[日志] 查看 Watchtower 日志 (Ctrl+C 退出)${NC}"
            echo ""
            $COMPOSE_CMD logs -f watchtower
            ;;
        8)
            echo -e "${BLUE}[操作] 更新服务镜像...${NC}"
            $COMPOSE_CMD pull && $COMPOSE_CMD up -d && echo -e "${GREEN}✓ 服务已更新${NC}" || echo -e "${RED}✗ 更新失败${NC}"
            ;;
        9)
            echo -e "${BLUE}[操作] 发送测试通知...${NC}"
            echo "将重启通知服务以触发启动通知"
            $COMPOSE_CMD restart watchtower-notifier
            echo -e "${GREEN}✓ 已触发重启，请稍候查看 Telegram${NC}"
            ;;
        10)
            echo -e "${BLUE}[信息] 详细健康检查${NC}"
            echo ""
            echo "═══ 容器运行状态 ═══"
            docker ps -a --filter "name=watchtower" --format "table {{.Names}}\t{{.Status}}\t{{.State}}"
            echo ""
            echo "═══ 健康检查结果 ═══"
            docker inspect --format='{{.Name}}: {{if .State.Health}}{{.State.Health.Status}}{{else}}N/A{{end}}' watchtower watchtower-notifier 2>/dev/null | sed 's/\///g'
            echo ""
            echo "═══ 资源使用情况 ═══"
            docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" watchtower watchtower-notifier
            echo ""
            echo "═══ 最近日志 (最后20行) ═══"
            echo -e "${CYAN}Watchtower:${NC}"
            docker logs --tail 20 watchtower 2>&1 | tail -10
            echo ""
            echo -e "${CYAN}Notifier:${NC}"
            docker logs --tail 20 watchtower-notifier 2>&1 | tail -10
            ;;
        11)
            BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
            echo -e "${BLUE}[操作] 备份配置文件到 $BACKUP_DIR${NC}"
            mkdir -p "$BACKUP_DIR"
            cp docker-compose.yml "$BACKUP_DIR/" 2>/dev/null
            cp .env "$BACKUP_DIR/" 2>/dev/null
            cp monitor.sh "$BACKUP_DIR/" 2>/dev/null
            [ -f data/container_state.db ] && cp data/container_state.db "$BACKUP_DIR/"
            echo -e "${GREEN}✓ 配置已备份${NC}"
            ;;
        12)
            echo -e "${YELLOW}[警告] 这将清除容器状态历史记录${NC}"
            read -p "确认清理? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -f data/container_state.db
                echo -e "${GREEN}✓ 状态数据库已清理${NC}"
            else
                echo "已取消"
            fi
            ;;
        13)
            echo -e "${BLUE}[信息] 当前配置${NC}"
            echo ""
            if [ -f .env ]; then
                echo "═══ 监控配置 ═══"
                grep -E "^(SERVER_NAME|POLL_INTERVAL|CLEANUP|ENABLE_ROLLBACK)=" .env | while read line; do
                    key=$(echo "$line" | cut -d= -f1)
                    val=$(echo "$line" | cut -d= -f2)
                    case $key in
                        POLL_INTERVAL)
                            mins=$((val / 60))
                            echo "检查间隔: ${mins} 分钟 (${val}秒)"
                            ;;
                        SERVER_NAME)
                            echo "服务器名称: ${val:-未设置}"
                            ;;
                        CLEANUP)
                            echo "自动清理: $val"
                            ;;
                        ENABLE_ROLLBACK)
                            echo "自动回滚: $val"
                            ;;
                    esac
                done
                echo ""
                echo "═══ 监控容器 ═══"
                if grep -q "command:" docker-compose.yml; then
                    echo "监控特定容器:"
                    grep -A 10 "command:" docker-compose.yml | grep "^      -" | sed 's/      - /  • /'
                else
                    echo "监控所有容器"
                fi
                echo ""
                echo "═══ 状态数据库 ═══"
                if [ -f data/container_state.db ]; then
                    local count=$(wc -l < data/container_state.db 2>/dev/null || echo 0)
                    echo "记录数: $count"
                else
                    echo "状态数据库: 未初始化"
                fi
            else
                echo -e "${RED}未找到配置文件${NC}"
            fi
            ;;
        14)
            echo -e "${BLUE}[操作] 编辑监控容器列表${NC}"
            echo ""
            echo "当前运行的容器:"
            docker ps --format "  • {{.Names}} [{{.Image}}]"
            echo ""
            echo "当前监控配置:"
            if grep -q "command:" docker-compose.yml; then
                grep -A 10 "command:" docker-compose.yml | grep "^      -" | sed 's/      - /  • /'
                echo ""
                echo "修改方法:"
                echo "1. 编辑 docker-compose.yml"
                echo "2. 找到 watchtower 服务的 command 部分"
                echo "3. 添加或删除容器名称"
                echo "4. 运行选项 3 (重启服务)"
            else
                echo "当前监控所有容器"
                echo ""
                echo "如需改为监控特定容器:"
                echo "1. 编辑 docker-compose.yml"
                echo "2. 在 watchtower 服务下添加:"
                echo "   command:"
                echo "     - 容器名1"
                echo "     - 容器名2"
                echo "3. 运行选项 3 (重启服务)"
            fi
            echo ""
            read -p "是否现在编辑配置文件? (y/n): " edit
            if [[ "$edit" =~ ^[Yy]$ ]]; then
                ${EDITOR:-vi} docker-compose.yml
                echo ""
                read -p "是否重启服务以应用更改? (y/n): " restart
                if [[ "$restart" =~ ^[Yy]$ ]]; then
                    $COMPOSE_CMD restart
                    echo -e "${GREEN}✓ 服务已重启${NC}"
                fi
            fi
            ;;
        0)
            echo "退出管理菜单"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac
}

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            start)   execute_action 1 ;;
            stop)    execute_action 2 ;;
            restart) execute_action 3 ;;
            status)  execute_action 4 ;;
            logs)    
                if [ "$2" = "notifier" ]; then
                    execute_action 6
                elif [ "$2" = "watchtower" ]; then
                    execute_action 7
                else
                    execute_action 5
                fi
                ;;
            update)  execute_action 8 ;;
            test)    execute_action 9 ;;
            health)  execute_action 10 ;;
            backup)  execute_action 11 ;;
            clean)   execute_action 12 ;;
            config)  execute_action 13 ;;
            edit)    execute_action 14 ;;
            *)
                echo "用法: $0 {start|stop|restart|status|logs|update|test|health|backup|clean|config|edit}"
                echo "或运行 $0 进入交互式菜单"
                exit 1
                ;;
        esac
        exit 0
    fi
    
    while true; do
        show_menu
        read -p "请选择操作 [0-14]: " choice
        echo ""
        execute_action "$choice"
        echo ""
        read -p "按回车键继续..."
    done
}

main "$@"
MANAGE_SCRIPT
    chmod +x "$INSTALL_DIR/manage.sh"
    print_success "管理脚本已创建"
}

# --- 启动服务 ---
start_service() {
    print_info "启动服务..."
    cd "$INSTALL_DIR"

    print_info "正在清理旧容器..."
    docker stop watchtower-notifier watchtower &>/dev/null || true
    docker rm watchtower-notifier watchtower &>/dev/null || true

    print_info "正在启动新服务..."

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

        print_info "检查服务状态..."
        $COMPOSE_CMD ps
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
    print_success "🎉 部署完成！v3.3.0 终极版"
    echo ""
    echo "📁 安装目录: $INSTALL_DIR"
    echo ""
    if [ -n "$SERVER_NAME" ]; then
        echo "📱 你应该很快会收到带 [${SERVER_NAME}] 前缀的 Telegram 启动通知"
    else
        echo "📱 你应该很快会收到 Telegram 启动通知"
    fi
    echo ""
    echo "🔧 管理方式:"
    echo ""
    echo -e "   ${GREEN}方式 1: 交互式菜单 (推荐)${NC}"
    echo "   cd $INSTALL_DIR && ./manage.sh"
    echo ""
    echo -e "   ${GREEN}方式 2: 命令行快捷操作${NC}"
    echo "   cd $INSTALL_DIR"
    echo "   ./manage.sh start      # 启动服务"
    echo "   ./manage.sh stop       # 停止服务"
    echo "   ./manage.sh restart    # 重启服务"
    echo "   ./manage.sh status     # 查看状态"
    echo "   ./manage.sh logs       # 查看日志"
    echo ""
    echo "✨ v3.3.0 终极重构:"
    echo "   • 🔥 完全重写处理逻辑，所有代码内联到主循环"
    echo "   • ✅ 彻底解决管道子shell变量传递问题"
    echo "   • 📝 实时显示详细处理过程和调试信息"
    echo "   • ⚡ 简化架构，移除不必要的函数调用"
    echo "   • 🎯 确保每次更新都能触发通知"
    echo ""
    echo "📝 监控配置:"
    echo "   • 检查间隔: $((POLL_INTERVAL / 60)) 分钟"
    echo "   • 自动清理: $CLEANUP"
    echo "   • 自动回滚: $ENABLE_ROLLBACK"
    if [[ ! "$MONITOR_ALL" =~ ^[Yy]$ ]] && [ -n "$CONTAINER_NAMES" ]; then
        echo "   • 监控容器: $CONTAINER_NAMES"
    else
        echo "   • 监控范围: 所有容器"
    fi
    echo ""
    echo "⚠️  重要提示:"
    echo "   • 日志会实时显示每个更新的处理步骤"
    echo "   • 使用 ./manage.sh logs 查看详细日志"
    echo "   • 数据库文件位于: $INSTALL_DIR/data/"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# --- 主函数 ---
main() {
    show_banner
    check_requirements
    get_user_input
    create_env_file
    create_gitignore
    create_data_dir
    create_docker_compose
    create_monitor_script
    create_management_script
    create_global_manage_script
    start_service
    show_completion

    echo ""
    read -p "是否现在设置全局 'manage' 命令? (y/n, 默认: y): " setup_global
    setup_global=${setup_global:-y}

    if [[ "$setup_global" =~ ^[Yy]$ ]]; then
        echo ""
        print_info "正在设置全局命令..."

        if [ -n "$BASH_VERSION" ]; then
            RC_FILE="$HOME/.bashrc"
        elif [ -n "$ZSH_VERSION" ]; then
            RC_FILE="$HOME/.zshrc"
        else
            RC_FILE="$HOME/.profile"
        fi

        if grep -q "alias manage=" "$RC_FILE" 2>/dev/null; then
            print_warning "别名已存在，跳过添加"
        else
            echo "" >> "$RC_FILE"
            echo "# Docker 容器监控管理命令" >> "$RC_FILE"
            echo "alias manage='$INSTALL_DIR/manage.sh'" >> "$RC_FILE"
            print_success "已添加别名到 $RC_FILE"
        fi

        echo ""
        print_success "✅ 设置完成！请运行以下命令激活："
        echo ""
        echo "  source $RC_FILE"
        echo ""
        print_info "之后就可以在任意目录运行: manage"
    fi
}

main