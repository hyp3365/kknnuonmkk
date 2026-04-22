#!/bin/bash 

# --- 基础配置 ---
BASE_DIR="/etc/sing-box"
SB_BIN=""
ARGO_BIN=""
ARCH="amd64"

# --- 颜色与格式定义 ---
RED="\033[1;31m"      
GREEN="\033[1;32m"    
YELLOW="\033[1;33m"   
PURPLE="\033[1;35m"   
BLUE="\033[1;34m"     
RESET="\033[0m"

# 搜索二进制文件逻辑
scan_bins() {
    SB_BIN=""
    ARGO_BIN=""
    if [ -d "$BASE_DIR" ]; then
        [ -x "$BASE_DIR/sing-box" ] && SB_BIN="$BASE_DIR/sing-box"
        [ -x "$BASE_DIR/cloudflared" ] && ARGO_BIN="$BASE_DIR/cloudflared"
        [ -x "$BASE_DIR/argo" ] && ARGO_BIN="$BASE_DIR/argo"
    fi
    if [ -z "$SB_BIN" ] || [ -z "$ARGO_BIN" ]; then
        for dir in "/usr/bin" "/usr/local/bin" "/root"; do
            [ -d "$dir" ] || continue
            [ -z "$SB_BIN" ] && SB_BIN=$(find "$dir" -maxdepth 1 -type f -executable -name "sing-box*" ! -name "*.bak" 2>/dev/null | head -n 1)
            [ -z "$ARGO_BIN" ] && ARGO_BIN=$(find "$dir" -maxdepth 1 -type f -executable \( -name "cloudflared*" -o -name "argo*" \) 2>/dev/null | head -n 1)
        done
    fi
    [ -z "$SB_BIN" ] && SB_BIN="/usr/local/bin/sing-box"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo -e "${RED}❌ 不支持的架构${RESET}"; exit 1 ;;
    esac
}

get_current_version() {
    if [ -x "$1" ]; then
        local first_line=$("$1" version 2>/dev/null | head -n 1)
        local ver=$(echo "$first_line" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?')
        [ -n "$ver" ] && echo "$ver" || echo "$first_line" | awk '{print $1,$2}'
    else
        echo "未安装"
    fi
}

get_latest_stable() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}

get_latest_prerelease() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | grep '"tag_name":' | head -n 10 | grep -E "alpha|beta|rc" | head -n 1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}

get_latest_awg() {
    curl -s "https://api.github.com/repos/hoaxisr/amnezia-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}

get_latest_argo() {
    curl -s "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}

update_sb() {
    tag="$1"
    [ -z "$tag" ] && return
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${tag#v}-linux-${ARCH}.tar.gz"
    tmp=$(mktemp -d)
    echo -e "${BLUE}▶ 正在从官方源下载 [ ${tag} ]...${RESET}"
    if curl -L -o "$tmp/sb.tgz" "$url"; then
        tar -xzf "$tmp/sb.tgz" -C "$tmp"
        [ -f "$SB_BIN" ] && cp "$SB_BIN" "$SB_BIN.bak" 2>/dev/null
        mv "$tmp"/sing-box*/sing-box "$SB_BIN" && chmod +x "$SB_BIN"
        systemctl restart sing-box 2>/dev/null
        echo -e "${GREEN}✅ 官方版本更新成功!${RESET}"
    else
        echo -e "${RED}❌ 下载失败，请检查网络环境。${RESET}"
    fi
    rm -rf "$tmp"
}

update_awg_sb() {
    tag="$1"
    [ -z "$tag" ] && return
    url="https://github.com/hoaxisr/amnezia-box/releases/download/${tag}/sing-box-linux-${ARCH}.tar.gz"
    tmp=$(mktemp -d)
    echo -e "${PURPLE}▶ 正在下载 [ ${tag} ]...${RESET}"
    if curl -L -o "$tmp/awg.tgz" "$url"; then
        tar -xzf "$tmp/awg.tgz" -C "$tmp"
        [ -f "$SB_BIN" ] && cp "$SB_BIN" "$SB_BIN.bak" 2>/dev/null
        find "$tmp" -type f -name "sing-box" -exec mv {} "$SB_BIN" \;
        chmod +x "$SB_BIN"
        systemctl restart sing-box 2>/dev/null
        echo -e "${GREEN}✅ hoaxisr分支版更新成功!${RESET}"
    else
        echo -e "${RED}❌ 下载失败，请确保该版本包含 ${ARCH} 架构文件。${RESET}"
    fi
    rm -rf "$tmp"
}

update_argo() {
    tag=$(get_latest_argo)
    url="https://github.com/cloudflare/cloudflared/releases/download/${tag}/cloudflared-linux-${ARCH}"
    echo -e "${BLUE}▶ 正在下载 Cloudflared Argo...${RESET}"
    [ -f "$ARGO_BIN" ] && cp "$ARGO_BIN" "$ARGO_BIN.bak" 2>/dev/null
    if curl -L -o "$ARGO_BIN" "$url"; then
        chmod +x "$ARGO_BIN"
        systemctl restart argo 2>/dev/null
        echo -e "${GREEN}✅ Argo 更新成功!${RESET}"
    else
        echo -e "${RED}❌ 下载失败${RESET}"
        [ -f "$ARGO_BIN.bak" ] && mv "$ARGO_BIN.bak" "$ARGO_BIN"
    fi
}

# --- 主循环界面 ---
while true; do
    clear
    scan_bins
    detect_arch
    
    echo -e "${YELLOW}=================================================${RESET}"
    echo -e "           ${GREEN}SING-BOX 更新${RESET}"
    echo -e "${YELLOW}=================================================${RESET}"
    echo -e "${BLUE}程序路径:${RESET}"
    echo -e "  sing-box:  ${RED}${SB_BIN:-未找到}${RESET}"
    echo -e "  argo:      ${RED}${ARGO_BIN:-未找到}${RESET}"
    echo
    echo -e "${BLUE}当前版本信息:${RESET}"
    echo -e "  sing-box:  ${RED}$(get_current_version "$SB_BIN")${RESET}"
    echo -e "  argo:      ${RED}$(get_current_version "$ARGO_BIN")${RESET}"
    echo -e "  系统架构:  ${RED}$ARCH${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    echo -e "${GREEN}正在获取版本信息...${RESET}"
    v_stable=$(get_latest_stable)
    v_pre=$(get_latest_prerelease)
    v_awg=$(get_latest_awg)
    v_argo=$(get_latest_argo)

    echo -e "1) ${GREEN}更新 sing-box${RESET}  [ ${YELLOW}官方稳定版: ${v_stable:-获取中}${RESET} ]"
    echo -e "2) ${GREEN}更新 sing-box${RESET}  [ ${YELLOW}官方测试版: ${v_pre:-获取中}${RESET} ]"
    echo -e "3) ${GREEN}更新 argo   ${RESET}  [ ${YELLOW}最新版本: ${v_argo:-获取中}${RESET} ]"
    echo -e "4) ${PURPLE}更新 sing-box${RESET} [ ${YELLOW}hoaxisr分支版: ${v_awg:-获取中}${RESET} ]"
    echo -e "0) ${RED}退出程序${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    echo
    read -p "请输入序号并回车: " choice
    case "$choice" in
        1) update_sb "$v_stable" ;;
        2) update_sb "$v_pre" ;;
        3) update_argo ;;
        4) update_awg_sb "$v_awg" ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请输入 0-4 之间的数字。${RESET}" ;;
    esac
    echo
    read -p "按回车键继续..."
done
