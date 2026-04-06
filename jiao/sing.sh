#!/bin/bash 

BASE_DIR="/etc/sing-box"
SB_BIN=""
ARGO_BIN=""
ARCH="amd64"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo_green() { echo -e "${GREEN}$1${RESET}"; }
echo_red() { echo -e "${RED}$1${RESET}"; }

scan_bins() {
    SB_BIN=""
    ARGO_BIN=""

    # 1. 第一优先级：显式检查 /etc/sing-box 目录
    if [ -d "$BASE_DIR" ]; then
        [ -x "$BASE_DIR/sing-box" ] && SB_BIN="$BASE_DIR/sing-box"
        [ -x "$BASE_DIR/cloudflared" ] && ARGO_BIN="$BASE_DIR/cloudflared"
        [ -x "$BASE_DIR/argo" ] && ARGO_BIN="$BASE_DIR/argo"
    fi

    # 2. 第二优先级：如果还没找到，扫描系统路径
    if [ -z "$SB_BIN" ] || [ -z "$ARGO_BIN" ]; then
        SEARCH_DIRS=("/usr/bin" "/usr/local/bin" "/root" "/etc")

        for dir in "${SEARCH_DIRS[@]}"; do
            [ -d "$dir" ] || continue
            
            # 寻找 sing-box
            if [ -z "$SB_BIN" ]; then
                found=$(find "$dir" -maxdepth 1 -type f -executable -name "sing-box*" ! -name "*.bak" 2>/dev/null | head -n 1)
                [ -n "$found" ] && SB_BIN="$found"
            fi

            # 寻找 argo (cloudflared)
            if [ -z "$ARGO_BIN" ]; then
                found=$(find "$dir" -maxdepth 1 -type f -executable \( -name "cloudflared*" -o -name "argo*" \) 2>/dev/null | head -n 1)
                [ -n "$found" ] && ARGO_BIN="$found"
            fi
        done
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo_red "不支持的架构"; exit 1 ;;
    esac
}

get_current_version() {
    if [ -x "$1" ]; then
        # 提取版本号，过滤掉多余信息
        "$1" version 2>/dev/null | head -n 1 | awk '{print $3}'
    else
        echo "未安装"
    fi
}

get_latest_stable() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/'
}

get_latest_prerelease() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | awk '/"tag_name"/ {gsub(/[",]/, "", $2); tag=$2} /"prerelease": true/ {print tag; exit}'
}

get_latest_argo() {
    curl -s "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep '"tag_name"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/'
}

update_sing_box() {
    latest="$1"
    [ -z "$latest" ] && { echo_red "获取版本失败"; return; }
    
    url="https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${latest#v}-linux-${ARCH}.tar.gz"
    echo_green "正在从 $url 下载..."

    tmp=$(mktemp -d)
    cd "$tmp" || exit 1

    if curl -L -o sb.tar.gz "$url"; then
        tar -xzf sb.tar.gz
        cp "$SB_BIN" "$SB_BIN.bak" # 备份
        mv sing-box*/sing-box "$SB_BIN"
        chmod +x "$SB_BIN"
        systemctl restart sing-box 2>/dev/null
        echo_green "✅ 更新成功！当前版本: $(get_current_version "$SB_BIN")"
    else
        echo_red "❌ 下载失败"
    fi
    cd / && rm -rf "$tmp"
}

update_argo() {
    latest=$(get_latest_argo)
    url="https://github.com/cloudflare/cloudflared/releases/download/${latest}/cloudflared-linux-${ARCH}"
    
    cp "$ARGO_BIN" "$ARGO_BIN.bak"
    if curl -L -o "$ARGO_BIN" "$url"; then
        chmod +x "$ARGO_BIN"
        systemctl restart argo 2>/dev/null
        echo_green "✅ Argo 更新成功！"
    else
        echo_red "❌ 下载失败"
        mv "$ARGO_BIN.bak" "$ARGO_BIN"
    fi
}

menu() {
    clear
    scan_bins
    detect_arch

    echo_red "=============================="
    echo_red "     SING-BOX & ARGO 管理器"
    echo_red "=============================="
    
    echo -e "${GREEN}程序路径:${RESET}"
    echo -e "  sing-box: ${RED}${SB_BIN:-未找到}${RESET}"
    echo -e "  argo:     ${RED}${ARGO_BIN:-未找到}${RESET}"
    echo
    
    echo -e "${GREEN}当前版本信息:${RESET}"
    echo -e "  sing-box: ${RED}$(get_current_version "$SB_BIN")${RESET}"
    echo -e "  argo:     ${RED}$(get_current_version "$ARGO_BIN")${RESET}"
    echo -e "  系统架构: ${RED}$ARCH${RESET}"
    echo

    # 异步获取版本，减少等待感
    echo_green "检查最新版本中..."
    latest_sb_stable=$(get_latest_stable)
    latest_sb_pre=$(get_latest_prerelease)
    latest_argo=$(get_latest_argo)

    echo_green "1) 更新 sing-box [ 稳定版: $latest_sb_stable ]"
    echo_green "2) 更新 sing-box [ 测试版: $latest_sb_pre ]"
    echo_green "3) 更新 argo     [ 最新版: $latest_argo ]"
    echo_red   "4) 退出程序"
    echo

    read -rp "$(echo -e ${YELLOW}请选择序号后回车:${RESET} ) " choice

    case "$choice" in
        1) update_sing_box "$latest_sb_stable" ;;
        2) update_sing_box "$latest_sb_pre" ;;
        3) update_argo ;;
        4) exit 0 ;;
        *) echo_red "无效选项" ;;
    esac

    echo
    read -rp "按回车键返回主菜单..."
}

while true; do
    menu
done
