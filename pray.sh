#!/bin/bash
# SOCKS5 代理服务器安装脚本 (带用户认证)

# 确保以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 权限运行此脚本 (e.g., sudo $0)"
  exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== SOCKS5 代理服务器安装 (安全版) ===${NC}"

# 提示用户输入配置信息
read -p "请输入 SOCKS5 端口 [默认: 1080]: " SOCKS_PORT
SOCKS_PORT=${SOCKS_PORT:-1080}

read -p "请输入 SOCKS5 用户名: " SOCKS_USER
while [ -z "$SOCKS_USER" ]; do
    echo -e "${RED}用户名不能为空!${NC}"
    read -p "请输入 SOCKS5 用户名: " SOCKS_USER
done

read -sp "请输入 SOCKS5 密码: " SOCKS_PASS
echo
while [ -z "$SOCKS_PASS" ]; do
    echo -e "${RED}密码不能为空!${NC}"
    read -sp "请输入 SOCKS5 密码: " SOCKS_PASS
    echo
done

echo -e "\n${YELLOW}--- 正在更新软件包列表 ---${NC}"
apt-get update

echo -e "${YELLOW}--- 正在安装 dante-server ---${NC}"
apt-get install dante-server -y

if [ $? -ne 0 ]; then
    echo -e "${RED}dante-server 安装失败。退出。${NC}"
    exit 1
fi

echo -e "${YELLOW}--- 创建 SOCKS5 用户 ---${NC}"
# 创建系统用户(如果不存在)
if ! id "$SOCKS_USER" &>/dev/null; then
    useradd -r -s /bin/false "$SOCKS_USER"
    echo -e "${GREEN}用户 $SOCKS_USER 创建成功${NC}"
else
    echo -e "${YELLOW}用户 $SOCKS_USER 已存在${NC}"
fi

# 设置用户密码
echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd

echo -e "${YELLOW}--- 备份原始配置文件 ---${NC}"
[ -f /etc/danted.conf ] && mv /etc/danted.conf /etc/danted.conf.bak.$(date +%Y%m%d%H%M%S)

# 自动检测主网络接口
INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo -e "${YELLOW}无法自动检测网络接口。将默认使用 eth0。${NC}"
    INTERFACE="eth0"
fi

echo -e "${GREEN}--- 将使用网络接口: $INTERFACE ---${NC}"

echo -e "${YELLOW}--- 正在创建安全配置文件 (/etc/danted.conf) ---${NC}"
cat > /etc/danted.conf <<EOF
# Dante SOCKS5 服务器配置 (安全版)
logoutput: /var/log/danted.log

# 监听配置
internal: 0.0.0.0 port = $SOCKS_PORT
external: $INTERFACE

# 认证方法: 使用用户名/密码
socksmethod: username

# 客户端认证方法
clientmethod: none

# 运行用户
user.privileged: root
user.unprivileged: nobody

# 客户端连接规则
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

# SOCKS 命令规则
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    command: bind connect udpassociate
    log: connect disconnect error
    socksmethod: username
}
EOF

echo -e "${YELLOW}--- 设置日志文件权限 ---${NC}"
touch /var/log/danted.log
chmod 644 /var/log/danted.log

echo -e "${YELLOW}--- 正在重启 dante-server 服务 ---${NC}"
systemctl restart danted
systemctl enable danted

sleep 2

echo -e "${YELLOW}--- 检查服务状态 ---${NC}"
if systemctl is-active --quiet danted; then
    echo -e "${GREEN}danted 服务运行正常${NC}"
    systemctl status danted --no-pager -l
else
    echo -e "${RED}danted 服务启动失败!${NC}"
    echo "请检查日志: tail -f /var/log/danted.log"
    exit 1
fi

# 获取服务器 IP
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}')

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}          SOCKS5 代理服务器配置完成!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "服务器地址: ${YELLOW}$SERVER_IP${NC}"
echo -e "端口: ${YELLOW}$SOCKS_PORT${NC}"
echo -e "用户名: ${YELLOW}$SOCKS_USER${NC}"
echo -e "密码: ${YELLOW}$SOCKS_PASS${NC}"
echo -e "认证方式: ${YELLOW}用户名/密码${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "\n测试命令:"
echo -e "  ${YELLOW}curl -x socks5://$SOCKS_USER:$SOCKS_PASS@$SERVER_IP:$SOCKS_PORT https://ifconfig.me${NC}"
echo -e "\n查看日志:"
echo -e "  ${YELLOW}tail -f /var/log/danted.log${NC}"
echo -e "\n管理命令:"
echo -e "  启动: ${YELLOW}systemctl start danted${NC}"
echo -e "  停止: ${YELLOW}systemctl stop danted${NC}"
echo -e "  重启: ${YELLOW}systemctl restart danted${NC}"
echo -e "  状态: ${YELLOW}systemctl status danted${NC}"
echo -e "${GREEN}============================================================${NC}\n"