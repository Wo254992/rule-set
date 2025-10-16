#!/bin/bash
# Xray 代理一键部署脚本（命令执行修复版）
# 支持 VLESS Reality
# 说明：建议以 root 或有 sudo 权限的账户运行

set -euo pipefail
IFS=$'\n\t'

# 颜色定义
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# 打印函数
print_info()    { echo -e "${BLUE}[信息]${NC} $*"; }
print_success() { echo -e "${GREEN}[成功]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[警告]${NC} $*"; }
print_error()   { echo -e "${RED}[错误]${NC} $*"; }

# 默认工作目录
DEFAULT_WORK_DIR="${HOME:-/root}/xray-proxy"
WORK_DIR="$DEFAULT_WORK_DIR"
ADD_MODE=false
declare -a COMPOSE_CMD_ARR=()

# 临时清理
_tmp_files=()
cleanup() {
    for f in "${_tmp_files[@]:-}"; do [ -e "$f" ] && rm -f "$f" || true; done
}
trap cleanup EXIT

# =================================================================
# 环境准备函数
# =================================================================
install_dependencies() {
    local tools_to_check=("jq" "curl")
    local missing_tools=()
    for tool in "${tools_to_check[@]}"; do
        if ! command -v "$tool" &>/dev/null; then missing_tools+=("$tool"); fi
    done
    if [ ${#missing_tools[@]} -eq 0 ]; then return 0; fi

    print_info "需要安装工具: ${missing_tools[*]}..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_tools[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y epel-release || true
        yum install -y "${missing_tools[@]}"
    elif command -v apk &>/dev/null; then
        apk add --no-cache "${missing_tools[@]}"
    else
        print_error "无法自动安装依赖，请手动安装: ${missing_tools[*]}" && exit 1
    fi
    print_success "依赖安装完成"
}

install_docker() {
    if command -v docker &>/dev/null; then print_success "Docker 已安装"; return 0; fi
    print_warning "未检测到 Docker，尝试使用官方脚本安装..."
    if curl -fsSL https://get.docker.com | sh; then
        if command -v systemctl &>/dev/null; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl start docker >/dev/null 2>&1 || true
            systemctl enable docker >/dev/null 2>&1 || true
        fi
        print_success "Docker 安装完成"
    else
        print_error "Docker 安装失败，请检查网络或手动安装" && exit 1
    fi
}

install_docker_compose() {
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD_ARR=("docker" "compose")
        print_success "检测到 'docker compose' 可用"
        return 0
    fi
    if command -v docker-compose &>/dev/null 2>&1; then
        COMPOSE_CMD_ARR=("docker-compose")
        print_success "检测到 'docker-compose' 可用"
        return 0
    fi
    
    print_warning "未检测到 Docker Compose，将尝试安装..."
    local arch; arch=$(uname -m)
    local dst="${HOME:-/root}/.docker/cli-plugins/docker-compose"
    mkdir -p "$(dirname "$dst")"
    if curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" -o "$dst"; then
        chmod +x "$dst"
        COMPOSE_CMD_ARR=("docker" "compose")
        print_success "Docker Compose 安装成功"
    else
        print_error "未能安装 Docker Compose，请手动安装" && exit 1
    fi
}

# =================================================================
# 脚本主逻辑
# =================================================================
install_dependencies
install_docker
install_docker_compose

clear
echo -e "${GREEN}================================================"
echo "          Xray 代理一键部署脚本 (命令执行修复版)"
echo "        支持: VLESS Reality"
echo "================================================"
echo -e "${NC}\n"

# 部署检测
print_info "正在全局检测已有的 Xray 代理容器..."
CONTAINER_ID=$(docker ps -a --format '{{.ID}}\t{{.Names}}' | awk -F'\t' '$2 == "xray-proxy" {print $1; exit}')
if [ -z "${CONTAINER_ID:-}" ]; then
    CONTAINER_ID=$(docker ps -a --filter "label=com.docker.compose.service=xray" --format "{{.ID}}" | head -n1 || true)
fi

if [ -n "${CONTAINER_ID:-}" ]; then
    CONFIG_PATH=$(docker inspect "$CONTAINER_ID" 2>/dev/null | jq -r '.[0].Mounts[]? | select(.Destination=="/etc/xray/config.json") | .Source' || true)
    if [ -n "${CONFIG_PATH:-}" ] && [ -f "$CONFIG_PATH" ]; then
        EXISTING_WORK_DIR=$(dirname "$CONFIG_PATH")
        print_warning "检测到已部署的 Xray 代理 (位于: ${EXISTING_WORK_DIR})"
        echo -e "\n请选择操作:\n  1) 添加新节点\n  2) ${RED}重新部署 (彻底清除)${NC}\n  3) 退出"
        read -p "请选择 (1/2/3): " deploy_mode
        case ${deploy_mode:-} in
            1) ADD_MODE=true; WORK_DIR="$EXISTING_WORK_DIR"; print_info "将在目录 ${WORK_DIR} 中添加新节点..." ;;
            2)
                print_error "警告：此操作将永久删除容器及位于 ${EXISTING_WORK_DIR} 的所有配置！"
                read -p "确认彻底清除并重新部署吗? (y/n): " confirm
                if [ "${confirm:-}" != "y" ]; then print_info "已取消"; exit 0; fi
                print_info "正在清理旧的部署..."
                (cd "$EXISTING_WORK_DIR" && "${COMPOSE_CMD_ARR[@]}" down -v --remove-orphans >/dev/null 2>&1) || true
                docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
                rm -rf "$EXISTING_WORK_DIR"
                if [ -L "/usr/local/bin/xray" ]; then sudo rm -f /usr/local/bin/xray || rm -f /usr/local/bin/xray || true; fi
                print_success "旧部署已彻底清理。"
                ADD_MODE=false; WORK_DIR="$DEFAULT_WORK_DIR"
                ;;
            3) print_info "已退出"; exit 0 ;;
            *) print_error "无效选择"; exit 1 ;;
        esac
    else
        print_warning "检测到名为 xray-proxy 的容器，但无法定位其配置文件。建议手动清理: docker rm -f ${CONTAINER_ID}"
        exit 1
    fi
else
    print_success "未检测到现有部署，将进行全新安装。"
fi

# 节点处理
declare -a nodes
if [ "$ADD_MODE" = true ] && [ -f "${WORK_DIR}/nodes.json" ]; then
    print_info "加载现有节点配置..."
    mapfile -t nodes < <(jq -c '.nodes[]' "${WORK_DIR}/nodes.json")
    print_success "已加载 ${#nodes[@]} 个现有节点"
fi

echo -e "\n${GREEN}请粘贴节点配置 (支持 Clash/V2RayN)，完成后按 Ctrl+D。${NC}"
echo -e "${YELLOW}如果不导入新节点，可直接按 Ctrl+D 跳过。${NC}"

temp_file=$(mktemp)
_tmp_files+=("$temp_file")
cat > "$temp_file"

if [ -s "$temp_file" ]; then
    print_info "正在智能解析节点配置..."
    parsed_content=""
    if grep -qE "^\s*proxies:" "$temp_file"; then
        print_info "检测到 Clash (YAML) 格式，尝试提取代理..."
        parsed_content=$(awk '/^\s*proxies:/ {p=1; next} p' "$temp_file" | sed 's/^[[:space:]]*- //g' | jq -s '.')
        if ! echo "$parsed_content" | jq -e 'type == "array" and length > 0' &>/dev/null; then
             print_error "无法从 Clash (YAML) 配置中提取有效的代理列表。"; exit 1
        fi
        print_info "YAML 格式解析成功。"
    elif jq -e 'type == "array"' "$temp_file" &>/dev/null; then
        parsed_content=$(cat "$temp_file"); print_info "输入被识别为标准 JSON 数组。"
    elif parsed_content=$(jq -s '.' "$temp_file" 2>/dev/null) && jq -e 'type == "array" and length > 0' <<< "$parsed_content" &>/dev/null; then
        print_info "输入被识别为 JSON 对象流。"
    else
        print_error "无法解析输入内容。请确保粘贴的是有效的 JSON 或 Clash (YAML) 内容。"; exit 1
    fi
    
    original_count=$(echo "$parsed_content" | jq 'length')
    print_success "检测到 $original_count 个原始节点条目。"
    print_info "正在使用 jq 过滤无效节点..."

    filter_regex="剩余|重置|到期|官网|套餐"
    filtered_nodes_json=$(echo "$parsed_content" | jq --arg re "$filter_regex" '[.[] | select((.name // .ps // "") | test($re; "i") | not) | select((.type // .protocol // "") != "hysteria2" and (.type // .protocol // "") != "hy2" and (.type // .protocol // "") != "hysteria")]')
    
    newly_added_nodes=()
    mapfile -t newly_added_nodes < <(echo "$filtered_nodes_json" | jq -c '.[]')
    
    nodes+=("${newly_added_nodes[@]}")
    
    filtered_count=${#newly_added_nodes[@]}
    skipped_count=$((original_count - filtered_count))

    print_warning "已跳过 $skipped_count 个无效节点 (包含流量/到期等信息或 Hysteria2 协议)。"
    if [ "$filtered_count" -eq 0 ]; then
        print_error "未从您的输入中找到任何可用的有效新节点。"
    else
        print_success "成功导入 $filtered_count 个新节点。"
    fi
fi

if [ "${#nodes[@]}" -eq 0 ]; then
    print_error "没有任何可用的节点配置，脚本退出。"; exit 1
fi

# 标准化节点
standardize_node() {
    local j="$1"
    t=$(echo "$j" | jq -r '.type // .protocol // "vless"')
    t=${t,,}
    if [[ "$t" == "hysteria2" || "$t" == "hy2" || "$t" == "hysteria" ]]; then
        print_warning "跳过 Hysteria2 节点: $(echo "$j" | jq -r '.name // .ps // "未命名"')"
        return 1
    fi
    t="vless"
    
    name=$(echo "$j" | jq -r '.name // .ps // "未命名"')
    server=$(echo "$j" | jq -r '.server // .address // .add // empty')
    port=$(echo "$j" | jq -r '.port // empty')
    uuid=$(echo "$j" | jq -r '.uuid // .id // empty')
    sni=$(echo "$j" | jq -r '.sni // .servername // .serverName // empty')
    publicKey=$(echo "$j" | jq -r '."reality-opts"."public-key" // .publicKey // .pbk // empty')
    shortId=$(echo "$j" | jq -r '."reality-opts"."short-id" // .shortId // .sid // empty')

    jq -n --arg t "$t" --arg name "$name" --arg server "$server" --arg port "$port" --arg uuid "$uuid" \
          --arg sni "$sni" --arg publicKey "$publicKey" --arg shortId "$shortId" \
          '{type:$t,name:$name,server:$server,port:$port,uuid:$uuid,sni:$sni,publicKey:$publicKey,shortId:$shortId}'
}

print_info "标准化所有节点配置..."
filtered_nodes=()
for i in "${!nodes[@]}"; do
    if standardize_node "${nodes[$i]}" >/dev/null 2>&1; then
        filtered_nodes+=("$(standardize_node "${nodes[$i]}")")
    fi
done
nodes=("${filtered_nodes[@]}")
if [ "${#nodes[@]}" -eq 0 ]; then
    print_error "所有节点均为不支持的协议，脚本退出。"; exit 1
fi
print_success "所有 (${#nodes[@]}个) 节点配置已标准化。"

# 选择默认节点
echo ""
print_info "请选择默认使用的节点:"
for i in "${!nodes[@]}"; do
    echo "  $((i+1))) [$(echo "${nodes[$i]}" | jq -r .type)] $(echo "${nodes[$i]}" | jq -r .name)"
done
read -p "请输入节点编号 (1-${#nodes[@]}): " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#nodes[@]}" ]; then
    print_error "无效编号"; exit 1
fi
selected_node="${nodes[$((choice-1))]}"
print_success "已选择节点: $(echo "$selected_node" | jq -r '.name')"

# 设置监听地址
if [ "$ADD_MODE" = false ]; then
    echo ""
    print_info "请选择代理监听范围:"
    echo -e "  1) ${GREEN}仅本机 (127.0.0.1)${NC} (推荐)\n  2) ${YELLOW}局域网/公网 (0.0.0.0)${NC}"
    read -p "请选择 (1/2, 默认 1): " listen_choice
    LISTEN_ADDRESS=$([ "${listen_choice:-1}" = "2" ] && echo "0.0.0.0" || echo "127.0.0.1")
    print_success "代理将监听于: $LISTEN_ADDRESS"
else
    LISTEN_ADDRESS=$(cat "${WORK_DIR}/listen.conf" 2>/dev/null || echo "127.0.0.1")
    print_info "沿用/默认监听配置: $LISTEN_ADDRESS"
fi

mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
echo "$LISTEN_ADDRESS" > listen.conf

# 生成 Xray 配置
generate_xray_config() {
    local node_json="$1"; local listen_addr="$2"
    local inbounds; inbounds=$(jq -n --arg l "$listen_addr" '[{port:1080,listen:$l,protocol:"socks",settings:{auth:"noauth",udp:true}},{port:1081,listen:$l,protocol:"http",settings:{}}]')
    local t; t=$(echo "$node_json" | jq -r '.type')
    jq -n --argjson i "$inbounds" --arg s "$(echo "$node_json"|jq -r .server)" --arg p "$(echo "$node_json"|jq -r .port)" \
          --arg u "$(echo "$node_json"|jq -r .uuid)" --arg sni "$(echo "$node_json"|jq -r .sni)" --arg pk "$(echo "$node_json"|jq -r .publicKey)" \
          --arg sid "$(echo "$node_json"|jq -r .shortId)" \
          '{log:{loglevel:"warning"},inbounds:$i,outbounds:[{protocol:"vless",settings:{vnext:[{address:$s,port:($p | tonumber),users:[{id:$u,encryption:"none",flow:"xtls-rprx-vision"}]}]},streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:$sni,fingerprint:"chrome",show:false,publicKey:$pk,shortId:$sid}}}]}'
}
print_info "生成 Xray 配置文件..."
generate_xray_config "$selected_node" "$LISTEN_ADDRESS" > config.json
print_success "Xray 配置文件生成完成 ($WORK_DIR/config.json)"

# 保存节点列表
print_info "保存节点列表..."
(printf "%s\n" "${nodes[@]}" | jq -s '.') | jq '{"nodes": .}' > nodes.json
print_success "节点列表已保存 ($WORK_DIR/nodes.json)"

# 生成管理脚本
print_info "生成管理脚本..."
cat > "${WORK_DIR}/xray.sh" <<'XRAYSCRIPT'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
cd "$(dirname "$(readlink -f "$0")")" || exit 1

if ! command -v jq &>/dev/null; then echo -e "${RED}错误: 管理脚本需要 'jq'，请安装它。${NC}"; exit 1; fi

declare -a COMPOSE_CMD_ARR=()
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD_ARR=("docker" "compose")
elif command -v docker-compose &>/dev/null 2>&1; then
    COMPOSE_CMD_ARR=("docker-compose")
else
    echo -e "${RED}错误: 未找到 Docker Compose${NC}"; exit 1
fi

LISTEN_ADDRESS=$(cat listen.conf)
generate_xray_config(){ local n="$1";local l="$2";local i;i=$(jq -n --arg l "$l" '[{port:1080,listen:$l,protocol:"socks",settings:{auth:"noauth",udp:true}},{port:1081,listen:$l,protocol:"http",settings:{}}]');jq -n --argjson i "$i" --arg s "$(echo "$n"|jq -r .server)" --arg p "$(echo "$n"|jq -r .port)" --arg u "$(echo "$n"|jq -r .uuid)" --arg sni "$(echo "$n"|jq -r .sni)" --arg pk "$(echo "$n"|jq -r .publicKey)" --arg sid "$(echo "$n"|jq -r .shortId)" '{log:{loglevel:"warning"},inbounds:$i,outbounds:[{protocol:"vless",settings:{vnext:[{address:$s,port:($p | tonumber),users:[{id:$u,encryption:"none",flow:"xtls-rprx-vision"}]}]},streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:$sni,fingerprint:"chrome",show:false,publicKey:$pk,shortId:$sid}}}]}';}
show_menu(){ echo -e "${GREEN}======================================\n          Xray 节点管理\n======================================${NC}\n  1) 切换节点\n  2) 查看当前配置\n  3) 查看日志\n  4) 重启服务\n  5) 停止服务\n  6) 启动服务\n  7) 测试代理\n  0) 退出\n";}
action="${1:-}";if [ -z "$action" ]; then show_menu; read -p "请选择操作: " action; fi
case ${action:-} in
1) if [ ! -f "nodes.json" ]; then echo -e "${RED}错误: 节点配置文件不存在${NC}";exit 1;fi;echo -e "\n${BLUE}可用节点:${NC}";mapfile -t nodes < <(jq -c '.nodes[]' nodes.json);for i in "${!nodes[@]}"; do echo "  $((i+1))) [$(echo "${nodes[$i]}"|jq -r .type)] $(echo "${nodes[$i]}"|jq -r .name)";done;echo "";read -p "请选择节点 (1-${#nodes[@]}): " choice;if ! [[ "$choice" =~ ^[0-9]+$ ]]||[ "$choice" -lt 1 ]||[ "$choice" -gt "${#nodes[@]}" ]; then echo -e "${RED}无效选择${NC}";exit 1;fi;idx=$((choice-1));node_json="${nodes[$idx]}";node_name=$(echo "$node_json"|jq -r .name);echo -e "\n${BLUE}正在生成新配置: $node_name...${NC}";generate_xray_config "$node_json" "$LISTEN_ADDRESS" > config.json;echo -e "${GREEN}已切换到节点: $node_name${NC}\n${YELLOW}正在重启服务...${NC}";"${COMPOSE_CMD_ARR[@]}" restart;echo -e "${GREEN}服务重启完成${NC}";;
2) echo -e "\n${BLUE}当前 Xray 配置:${NC}";jq . config.json;;
3) echo -e "\n${BLUE}查看实时日志 (按 Ctrl+C 退出):${NC}";"${COMPOSE_CMD_ARR[@]}" logs -f;;
4) echo -e "\n${YELLOW}正在重启服务...${NC}";"${COMPOSE_CMD_ARR[@]}" restart;echo -e "${GREEN}服务重启完成${NC}";;
5) echo -e "\n${YELLOW}正在停止服务...${NC}";"${COMPOSE_CMD_ARR[@]}" down;echo -e "${GREEN}服务已停止${NC}";;
6) echo -e "\n${YELLOW}正在启动服务...${NC}";"${COMPOSE_CMD_ARR[@]}" up -d;echo -e "${GREEN}服务启动完成${NC}";;
7) echo -e "\n${YELLOW}正在测试代理...${NC}";proxy_addr="${LISTEN_ADDRESS/0.0.0.0/127.0.0.1}";if curl -s --proxy "socks5://${proxy_addr}:1080" https://www.google.com/generate_204 --connect-timeout 5 >/dev/null; then echo -e "${GREEN}代理工作正常 (SOCKS5)${NC}";else echo -e "${RED}代理连接失败 (SOCKS5)${NC}";fi;;
0) exit 0;;
*) echo -e "${RED}无效操作${NC}";exit 1;;
esac
exit 0
XRAYSCRIPT
chmod +x "${WORK_DIR}/xray.sh"
print_success "管理脚本创建完成: ${WORK_DIR}/xray.sh"

# 创建全局命令
target_path="/usr/local/bin/xray"
print_info "正在创建全局命令 'xray'..."
if ln -sf "${WORK_DIR}/xray.sh" "$target_path" 2>/dev/null; then
    print_success "全局命令创建成功: ${target_path}"
elif command -v sudo &>/dev/null; then
    print_warning "需要 sudo 权限来创建全局命令..."
    sudo ln -sf "${WORK_DIR}/xray.sh" "$target_path"
    print_success "全局命令创建成功 (使用 sudo): ${target_path}"
else
    print_error "无法创建全局命令。请手动创建符号链接:\nsudo ln -sf \"${WORK_DIR}/xray.sh\" ${target_path}"
fi

# 生成 Docker Compose 文件
print_info "生成 Docker Compose 文件..."
cat > docker-compose.yml <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-proxy
    restart: always
    volumes:
      - ./config.json:/etc/xray/config.json
    command: ["-config", "/etc/xray/config.json"]
    network_mode: "host"
    labels:
      - "com.docker.compose.service=xray"
EOF
print_success "Docker Compose 文件创建完成"

# 启动服务
print_info "正在启动 Xray 服务..."
"${COMPOSE_CMD_ARR[@]}" up -d

echo -e "\n${GREEN}======================================================="
echo -e "             🎉 Xray 代理部署完成 🎉"
echo -e "=======================================================${NC}\n"
echo -e "${YELLOW}代理信息:${NC}"
echo -e "  SOCKS5 代理地址: ${BLUE}${LISTEN_ADDRESS}:1080${NC}"
echo -e "  HTTP 代理地址:   ${BLUE}${LISTEN_ADDRESS}:1081${NC}\n"
echo -e "${YELLOW}管理命令:${NC}"
echo -e "  在任何目录下输入 ${GREEN}xray${NC} 即可管理节点和代理服务。"
echo -e "    - ${GREEN}xray 1${NC} : 切换节点"
echo -e "    - ${GREEN}xray 3${NC} : 查看日志"
echo -e "    - ${GREEN}xray 4${NC} : 重启服务\n"
print_success "部署脚本执行完毕"