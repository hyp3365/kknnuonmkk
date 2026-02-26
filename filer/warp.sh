cat << 'EOF' > /usr/local/bin/warp
#!/bin/bash

# ====================================================
# 项目: WARP 安装管理助手 
# ====================================================

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${NC}" && exit 1

# 汉化状态函数
translate_status() {
    case "$1" in
        "Connected") echo -e "${GREEN}已连接 (正常)${NC}" ;;
        "Disconnected") echo -e "${RED}已断开${NC}" ;;
        "Connecting") echo -e "${YELLOW}正在连接...${NC}" ;;
        "UnableToConnect") echo -e "${RED}连接失败 (请检查网络)${NC}" ;;
        *) echo -e "${YELLOW}${1:-未知}${NC}" ;;
    esac
}

# 获取当前状态和 IP 的函数
show_status() {
    echo -e "${BLUE}--- 当前网络状态 ---${NC}"
    if ! command -v warp-cli &> /dev/null; then
        echo -e "${RED}WARP 未安装${NC}"
        return
    fi
    
    # 屏蔽 stderr 避免看到 Rust Broken pipe 报错
    raw_status=$(warp-cli --accept-tos status 2>/dev/null | grep "Status update" | awk '{print $NF}')
    
    # 如果已连接，尝试获取 IP
    if [[ "$raw_status" == "Connected" ]]; then
        info=$(curl -s --max-time 3 -x socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace)
        ip=$(echo "$info" | grep "ip=" | cut -d= -f2)
        loc=$(echo "$info" | grep "loc=" | cut -d= -f2)
        
        echo -ne "${GREEN}连接状态:${NC} "
        translate_status "$raw_status"
        echo -e "${GREEN}出口 IP :${NC} ${ip:-"获取中..."} (${loc:-"未知地区"})"
    else
        echo -ne "${YELLOW}连接状态:${NC} "
        translate_status "$raw_status"
    fi
    echo -e "${BLUE}--------------------${NC}"
}

# 换 IP 函数
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

# 安装/更新函数
install_warp() {
    echo -e "${BLUE}开始安装/更新官方 WARP 客户端...${NC}"
    apt-get update && apt-get install -y curl gpg lsb-release
    
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    
    apt-get update && apt-get install -y cloudflare-warp
    
    warp-cli --accept-tos registration new >/dev/null 2>&1
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos connect
    
    echo -e "${GREEN}安装并初始化成功！输入 warp 即可管理。${NC}"
}

# 彻底卸载函数
uninstall_warp() {
    echo -e "${RED}正在清理所有文件...${NC}"
    warp-cli --accept-tos disconnect > /dev/null 2>&1
    warp-cli --accept-tos registration delete > /dev/null 2>&1
    apt-get purge -y cloudflare-warp > /dev/null 2>&1
    apt-get autoremove -y > /dev/null 2>&1
    
    rm -rf /var/lib/cloudflare-warp
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f /usr/local/bin/warp
    
    echo -e "${GREEN}卸载完成！你的服务器已干干净净。${NC}"
    exit 0
}

# 主菜单
clear
echo -e "${BLUE}====================================${NC}"
echo -e "${BLUE}      WARP 快捷管理助手 (v1.3.2)     ${NC}"
echo -e "${BLUE}====================================${NC}"
show_status
echo -e "${YELLOW}1.${NC} 安装/更新"
echo -e "${YELLOW}2.${NC} 更换IP"
echo -e "${YELLOW}3.${NC} 刷新当前状态"
echo -e "${YELLOW}4.${NC} 彻底卸载"
echo -e "${YELLOW}0.${NC} 退出"
echo -e "${BLUE}====================================${NC}"
read -p "选择操作: " choice

case $choice in
    1) install_warp ;;
    2) change_ip ;;
    3) clear; show_status ;;
    4) uninstall_warp ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效选项${NC}" ;;
esac
EOF

chmod +x /usr/local/bin/warp
warp
