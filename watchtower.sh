#!/bin/bash

# Watchtower 部署/更新脚本
# 自动配置代理和清理旧镜像

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 打印函数
print_info() { echo -e "${BLUE}[信息]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

# 显示欢迎信息
clear
echo -e "${GREEN}"
echo "================================================"
echo "   Watchtower 部署/更新脚本"
echo "================================================"
echo -e "${NC}"
echo ""

# 检测 Docker Compose 命令
print_info "检查 Docker Compose..."
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

# 工作目录
WORK_DIR=~/watchtower
print_info "准备工作目录: $WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 检查 Xray 代理是否运行
echo ""
print_info "检查 Xray 代理状态..."
if docker ps | grep -q xray-proxy; then
    print_success "Xray 代理正在运行"
    USE_PROXY=true
else
    print_warning "未检测到 Xray 代理容器"
    read -p "是否继续部署（Telegram 通知可能无法使用）? (y/n): " continue_deploy
    if [ "$continue_deploy" != "y" ]; then
        echo ""
        print_info "请先部署 Xray 代理:"
        echo "  cd ~/xray-proxy && docker compose up -d"
        exit 0
    fi
    USE_PROXY=false
fi

# 询问 Telegram 配置
echo ""
print_info "配置 Telegram 通知..."
read -p "请输入 Bot Token (留空跳过通知): " BOT_TOKEN

if [ -n "$BOT_TOKEN" ]; then
    read -p "请输入 Chat ID: " CHAT_ID
    
    if [ -z "$CHAT_ID" ]; then
        print_warning "未提供 Chat ID，将禁用通知"
        NOTIFICATION_URL=""
    else
        NOTIFICATION_URL="telegram://${BOT_TOKEN}@telegram?chats=${CHAT_ID}&parsemode=HTML"
        print_success "Telegram 通知已配置"
    fi
else
    print_warning "未配置 Telegram 通知"
    NOTIFICATION_URL=""
fi

# 询问监控的容器
echo ""
print_info "配置监控容器..."
echo -e "${YELLOW}提示: 可以输入多个容器名，用逗号或空格分隔${NC}"
echo -e "${YELLOW}示例: danmu-api,danmu-app 或 danmu-api danmu-app${NC}"
echo -e "${YELLOW}留空则监控所有容器${NC}"
read -p "请输入要监控的容器名: " MONITOR_CONTAINERS

# 处理输入
if [ -z "$MONITOR_CONTAINERS" ]; then
    print_info "将监控所有容器"
    CONTAINER_COMMAND=""
    CONTAINER_LIST="所有容器"
else
    # 将逗号和多个空格统一处理
    MONITOR_CONTAINERS=$(echo "$MONITOR_CONTAINERS" | tr ',' ' ' | tr -s ' ')
    CONTAINER_COMMAND="command: [$MONITOR_CONTAINERS]"
    CONTAINER_LIST="$MONITOR_CONTAINERS"
    print_success "已配置监控: $MONITOR_CONTAINERS"
fi

# 备份现有配置
if [ -f docker-compose.yml ]; then
    print_info "备份现有配置..."
    cp docker-compose.yml docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S)
    print_success "配置已备份"
fi

# 生成配置
print_info "生成 docker-compose.yml..."

# 代理配置
PROXY_CONFIG=""
if [ "$USE_PROXY" = true ]; then
    PROXY_CONFIG="
      # 使用本地 Xray 代理连接 Telegram
      - HTTP_PROXY=http://127.0.0.1:1081
      - HTTPS_PROXY=http://127.0.0.1:1081
      - NO_PROXY=localhost,127.0.0.1,*.local,169.254.0.0/16"
fi

# 通知配置
NOTIFICATION_CONFIG=""
if [ -n "$NOTIFICATION_URL" ]; then
    NOTIFICATION_CONFIG="
      - WATCHTOWER_NOTIFICATIONS=shoutrrr
      - WATCHTOWER_NOTIFICATION_URL=${NOTIFICATION_URL}
      - WATCHTOWER_NOTIFICATION_REPORT=true"
fi

# 生成 docker-compose.yml
cat > docker-compose.yml <<EOF
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
      - WATCHTOWER_POLL_INTERVAL=3600
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_REMOVE_VOLUMES=false
      - WATCHTOWER_INCLUDE_STOPPED=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_DEBUG=false
      - WATCHTOWER_RUN_ONCE=false${PROXY_CONFIG}${NOTIFICATION_CONFIG}
    ${CONTAINER_COMMAND}
    # 使用 host 网络访问本地代理
    network_mode: host
EOF

print_success "docker-compose.yml 生成完成"

# 获取当前镜像 ID
OLD_IMAGE_ID=""
if docker ps -a --format '{{.Names}}' | grep -q "^watchtower-monitor$"; then
    OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' watchtower-monitor 2>/dev/null || echo "")
    if [ -n "$OLD_IMAGE_ID" ]; then
        print_info "记录当前镜像: ${OLD_IMAGE_ID:0:12}"
    fi
fi

# 停止现有容器
print_info "检查并停止所有现有 Watchtower 容器..."

# 停止所有 watchtower 容器
watchtower_containers=$(docker ps -a --filter "ancestor=containrrr/watchtower" --format "{{.Names}}" 2>/dev/null || echo "")
if [ -n "$watchtower_containers" ]; then
    print_warning "发现现有 Watchtower 容器: $watchtower_containers"
    for container in $watchtower_containers; do
        print_info "停止并删除容器: $container"
        docker stop "$container" >/dev/null 2>&1 || true
        docker rm "$container" >/dev/null 2>&1 || true
    done
    print_success "已清理所有旧 Watchtower 容器"
fi

# 如果是用 compose 部署的，也停止
if [ -f docker-compose.yml ]; then
    print_info "停止 docker-compose 中的容器..."
    $COMPOSE_CMD down 2>/dev/null || true
fi

# 拉取最新镜像
print_info "拉取最新镜像..."
if docker pull containrrr/watchtower:latest; then
    print_success "镜像拉取成功"
    
    # 获取新镜像 ID
    NEW_IMAGE_ID=$(docker inspect --format='{{.Id}}' containrrr/watchtower:latest)
    
    # 清理旧镜像
    if [ -n "$OLD_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
        print_info "检测到镜像更新，清理旧镜像..."
        if docker rmi "$OLD_IMAGE_ID" 2>/dev/null; then
            print_success "旧镜像已删除: ${OLD_IMAGE_ID:0:12}"
        else
            print_warning "旧镜像清理失败"
        fi
    fi
else
    print_warning "镜像拉取失败，尝试使用现有镜像"
fi

# 启动容器
print_info "启动新容器..."
$COMPOSE_CMD up -d

# 等待启动
print_info "等待容器启动..."
sleep 5

# 检查容器状态（多次尝试）
MAX_RETRY=3
for i in $(seq 1 $MAX_RETRY); do
    if docker ps | grep -q watchtower-monitor; then
        print_success "Watchtower 容器启动成功！"
        break
    else
        if [ $i -eq $MAX_RETRY ]; then
            print_error "容器启动失败，查看日志:"
            echo ""
            $COMPOSE_CMD logs --tail 50
            echo ""
            print_warning "可能的原因:"
            echo "  1. 还有其他 Watchtower 实例在运行"
            echo "  2. 端口或资源冲突"
            echo ""
            print_info "尝试手动清理所有 Watchtower 容器:"
            echo "  docker ps -a | grep watchtower"
            echo "  docker stop \$(docker ps -a --filter 'ancestor=containrrr/watchtower' -q)"
            echo "  docker rm \$(docker ps -a --filter 'ancestor=containrrr/watchtower' -q)"
            exit 1
        fi
        print_warning "第 $i 次检查失败，等待重试..."
        sleep 3
    fi
done

# 清理悬空镜像
print_info "清理悬空镜像..."
dangling_count=$(docker images -f "dangling=true" -q | wc -l)
if [ "$dangling_count" -gt 0 ]; then
    docker image prune -f >/dev/null 2>&1
    print_success "已清理 $dangling_count 个悬空镜像"
fi

# 显示配置信息
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "工作目录: ${BLUE}$WORK_DIR${NC}"
echo -e "监控容器: ${BLUE}$CONTAINER_LIST${NC}"
echo -e "检查间隔: ${BLUE}1 小时${NC}"
if [ "$USE_PROXY" = true ]; then
    echo -e "代理状态: ${GREEN}已启用${NC} (http://127.0.0.1:1081)"
else
    echo -e "代理状态: ${YELLOW}未启用${NC}"
fi
if [ -n "$NOTIFICATION_URL" ]; then
    echo -e "TG 通知: ${GREEN}已启用${NC}"
else
    echo -e "TG 通知: ${YELLOW}未启用${NC}"
fi
echo ""
echo -e "${YELLOW}常用命令:${NC}"
echo -e "  查看日志: ${BLUE}cd $WORK_DIR && $COMPOSE_CMD logs -f${NC}"
echo -e "  重启服务: ${BLUE}cd $WORK_DIR && $COMPOSE_CMD restart${NC}"
echo -e "  停止服务: ${BLUE}cd $WORK_DIR && $COMPOSE_CMD down${NC}"
echo -e "  手动检查: ${BLUE}cd $WORK_DIR && $COMPOSE_CMD exec watchtower /watchtower --run-once${NC}"
echo ""
echo -e "${YELLOW}功能说明:${NC}"
echo "  ✅ 自动监控指定容器"
echo "  ✅ 发现更新时自动拉取新镜像"
echo "  ✅ 自动重启容器应用更新"
echo "  ✅ 自动清理旧镜像释放空间"
if [ "$USE_PROXY" = true ]; then
    echo "  ✅ 通过 Xray 代理连接 Telegram"
fi
if [ -n "$NOTIFICATION_URL" ]; then
    echo "  ✅ 更新完成后发送 Telegram 通知"
fi
echo ""
print_success "Watchtower 已启动并开始监控！"