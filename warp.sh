#!/bin/bash

# ====================================================
# 项目: WARP安装
# ====================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${NC}" && exit 1

translate_status() {
    case "$1" in
        "Connected") echo -e "${GREEN}已连接 (正常)${NC}" ;;
        "Disconnected") echo -e "${RED}已断开${NC}" ;;
        "Connecting") echo -e "${YELLOW}正在连接...${NC}" ;;
        *) echo -e "${YELLOW}${1:-未知}${NC}" ;;
    esac
}
show_status() {
    echo -e "${BLUE}--- 当前网络状态 ---${NC}"
    if ! command -v warp-cli &> /dev/null; then
        echo -e "${RED}WARP 未安装${NC}"
        return
    fi
    
    raw_status=$(warp-cli --accept-tos status 2>/dev/null | grep "Status update" | awk '{print $NF}')
    
    if [[ "$raw_status" == "Connected" ]]; then
        
        ip_info=$(curl -s --max-time 5 -x socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace)
        ip=$(echo "$ip_info" | grep "ip=" | cut -d= -f2)
        loc=$(echo "$ip_info" | grep "loc=" | cut -d= -f2)
        
        echo -ne "${GREEN}连接状态:${NC} "
        translate_status "$raw_status"
        echo -e "${GREEN}出口 IP :${NC} ${ip:-获取中...} (${loc:-未知地区})"
    else
        echo -ne "${YELLOW}连接状态:${NC} "
        translate_status "$raw_status"
    fi
    echo -e "${BLUE}--------------------${NC}"
}

# --- 安装函数 ---
install_warp() {
    echo -e "${BLUE}开始自动执行安装流程...${NC}"
    apt-get update && apt-get install -y curl gpg lsb-release
    
    # 添加官方仓库
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list
    
    apt-get update && apt-get install -y cloudflare-warp
    
    # 初始化配置
    warp-cli --accept-tos registration new >/dev/null 2>&1
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos connect
    echo -e "${GREEN}WARP 安装完成 快捷命令warp${NC}"
}

# --- 深度换 IP 函数 ---
change_ip() {
    echo -e "${BLUE}正在申请全新身份 (重置注册)...${NC}"
    warp-cli --accept-tos registration delete >/dev/null 2>&1
    sleep 1
    warp-cli --accept-tos registration new >/dev/null 2>&1
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
    warp-cli --accept-tos connect >/dev/null 2>&1
    
    echo -n "正在连接"
    for i in {1..12}; do
        if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
            echo -e " ${GREEN}[成功]${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    show_status
}

# --- 彻底卸载 ---
uninstall_warp() {
    echo -e "${RED}正在启动卸载...${NC}"
    warp-cli --accept-tos disconnect >/dev/null 2>&1
    warp-cli --accept-tos registration delete >/dev/null 2>&1
    apt-get purge -y cloudflare-warp >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    rm -rf /var/lib/cloudflare-warp /etc/apt/sources.list.d/cloudflare-client.list /usr/local/bin/warp
    echo -e "${GREEN}所有相关文件已清理干净！${NC}"
    exit 0
}

# --- 主逻辑控制 ---
# 检查是否带了启动参数 (如 warp 1)
if [ -n "$1" ]; then
    case $1 in
        1) install_warp ;;
        2) change_ip ;;
        4) uninstall_warp ;;
        *) echo "无效参数" ;;
    esac
    exit 0
fi

# 常规交互菜单
clear
echo -e "${BLUE}====================================${NC}"
echo -e "${BLUE}      WARP     ${NC}"
echo -e "${BLUE}====================================${NC}"
show_status
echo -e "${YELLOW}1.${NC} 安装/更新"
echo -e "${YELLOW}2.${NC} 更换IP"
echo -e "${YELLOW}3.${NC} 刷新"
echo -e "${YELLOW}4.${NC} 卸载"
echo -e "${YELLOW}0.${NC} 退出"
echo -e "${BLUE}====================================${NC}"
read -p "选择操作: " choice

case $choice in
    1) install_warp ;;
    2) change_ip ;;
    3) exec $0 ;;
    4) uninstall_warp ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效选项${NC}" ;;
esac

