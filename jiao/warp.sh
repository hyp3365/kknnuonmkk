#!/bin/bash

# ====================================================
# 项目: WARP-GO 极速轻量版管理脚本
# ====================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CONF_DIR="/etc/warp-go"
BIN_PATH="/usr/local/bin/warp-go"
SERVICE_PATH="/etc/systemd/system/warp-go.service"
PROXY_PORT=40000

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${NC}" && exit 1

# 获取系统 CPU 架构
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo -e "${RED}不支持的系统架构!${NC}"; exit 1 ;;
    esac
}

# 检查服务运行状态
check_service() {
    if systemctl is-active --quiet warp-go 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 状态检测逻辑 (支持双栈显示)
show_status() {
    echo -e "${BLUE}--- 当前网络状态 (WARP-GO) ---${NC}"
    if [ ! -f "$BIN_PATH" ]; then
        echo -e "${RED}WARP-GO 未安装${NC}"
        echo -e "${BLUE}--------------------------------${NC}"
        return
    fi

    if check_service; then
        echo -e "${GREEN}连接状态:${NC} 运行中 (SOCKS5: $PROXY_PORT)"
        
        # 通过 Socks5 代理并发检测 IPv4 与 IPv6
        ipv4=$(curl -4 -s --max-time 3 -x socks5h://127.0.0.1:${PROXY_PORT} https://4.ipw.cn 2>/dev/null)
        ipv6=$(curl -6 -s --max-time 3 -x socks5h://127.0.0.1:${PROXY_PORT} https://6.ipw.cn 2>/dev/null)

        echo -e "${GREEN}IPv4 出口:${NC} ${ipv4:-未连通/无IPv4通道}"
        echo -e "${GREEN}IPv6 出口:${NC} ${ipv6:-未连通/无IPv6通道}"
    else
        echo -e "${RED}连接状态:${NC} 已停止 / 未连通"
    fi
    echo -e "${BLUE}--------------------------------${NC}"
}

# --- 极速安装函数 ---
install_warp() {
    echo -e "${BLUE}开始安装 WARP-GO (极速轻量版)...${NC}"
    
    # 清理官方旧版的占用（如果存在）
    if command -v warp-cli &>/dev/null; then
        echo -e "${YELLOW}检测到官方 cloudflare-warp，正在清理冲突...${NC}"
        systemctl stop warp-svc >/dev/null 2>&1
        apt-get purge -y cloudflare-warp >/dev/null 2>&1
    fi

    # 只安装核心基础组件 (无需任何桌面/多媒体依赖)
    apt-get update -y && apt-get install -y --no-install-recommends curl ca-certificates >/dev/null 2>&1

    local ARCH=$(get_arch)
    mkdir -p "$CONF_DIR"

    echo -e "${BLUE}正在下载核心程序...${NC}"
    # 主下载节点
    curl -fsSL "https://gitlab.com/ProjectWARP/warp-go/-/raw/main/warp-go_linux_${ARCH}?inline=false" -o "$BIN_PATH"
    
    # 备用下载节点
    if [ $? -ne 0 ] || [ ! -s "$BIN_PATH" ]; then
        echo -e "${YELLOW}切换备用节点下载...${NC}"
        curl -fsSL "https://raw.githubusercontent.com/fscemen/warp-go/main/warp-go_linux_${ARCH}" -o "$BIN_PATH"
    fi

    if [ ! -s "$BIN_PATH" ]; then
        echo -e "${RED}下载失败，请检查 VPS 访问 GitLab/GitHub 的网络连通性！${NC}"
        exit 1
    fi

    chmod +x "$BIN_PATH"

    echo -e "${BLUE}正在自动注册账户并生成配置...${NC}"
    "$BIN_PATH" --register --config="$CONF_DIR/warp.conf" >/dev/null 2>&1

    if [ ! -f "$CONF_DIR/warp.conf" ]; then
        echo -e "${RED}WARP 账号注册失败！${NC}"
        exit 1
    fi

    # 配置守护进程 (启动 SOCKS5 代理模式)
    cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=WARP-GO Service
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH --config=$CONF_DIR/warp.conf --proxy=socks5://127.0.0.1:$PROXY_PORT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp-go >/dev/null 2>&1
    systemctl restart warp-go

    # 注入全局快捷指令 warp
    cp -f "$0" /usr/local/bin/warp 2>/dev/null
    chmod +x /usr/local/bin/warp 2>/dev/null

    sleep 2
    echo -e "${GREEN}WARP-GO 安装完成！总占用不到 15MB！${NC}"
    echo -e "${GREEN}快捷指令: ${YELLOW}warp${NC}"
    echo ""
    show_status
}

# --- 更换 IP 函数 ---
change_ip() {
    echo -e "${BLUE}正在重置身份申请全新 IP...${NC}"
    systemctl stop warp-go >/dev/null 2>&1
    rm -f "$CONF_DIR/warp.conf"
    
    "$BIN_PATH" --register --config="$CONF_DIR/warp.conf" >/dev/null 2>&1
    systemctl restart warp-go
    
    echo -n "正在连接"
    for i in {1..10}; do
        if check_service; then
            echo -e " ${GREEN}[成功]${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    show_status
}

# --- 彻底卸载函数 ---
uninstall_warp() {
    echo -e "${RED}正在启动卸载...${NC}"
    systemctl stop warp-go >/dev/null 2>&1
    systemctl disable warp-go >/dev/null 2>&1
    rm -rf "$SERVICE_PATH" "$CONF_DIR" "$BIN_PATH" /usr/local/bin/warp
    systemctl daemon-reload
    echo -e "${GREEN}WARP-GO 已彻底清理完毕！${NC}"
    exit 0
}

# --- 命令行参数入口 ---
if [ -n "$1" ]; then
    case $1 in
        1) install_warp ;;
        2) change_ip ;;
        3) show_status ;;
        4) uninstall_warp ;;
        *) echo "无效参数" ;;
    esac
    exit 0
fi

# --- 菜单交互界面 ---
clear
echo -e "${BLUE}====================================${NC}"
echo -e "${BLUE}       WARP-GO 管理脚本         ${NC}"
echo -e "${BLUE}====================================${NC}"
show_status
echo -e "${YELLOW}1.${NC} 安装/更新"
echo -e "${YELLOW}2.${NC} 更换IP "
echo -e "${YELLOW}3.${NC} 刷新状态"
echo -e "${YELLOW}4.${NC} 卸载"
echo -e "${YELLOW}0.${NC} 退出"
echo -e "${BLUE}====================================${NC}"
read -p "选择操作: " choice

case $choice in
    1) install_warp ;;
    2) change_ip ;;
    3) exec "$0" ;;
    4) uninstall_warp ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效选项${NC}" ;;
esac
