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

# 搜索二进制文件逻辑
scan_bins() {
    SB_BIN=""
    ARGO_BIN=""
    # 优先找 /etc/sing-box
    if [ -d "$BASE_DIR" ]; then
        [ -x "$BASE_DIR/sing-box" ] && SB_BIN="$BASE_DIR/sing-box"
        [ -x "$BASE_DIR/cloudflared" ] && ARGO_BIN="$BASE_DIR/cloudflared"
        [ -x "$BASE_DIR/argo" ] && ARGO_BIN="$BASE_DIR/argo"
    fi
    # 找不到再搜系统路径
    if [ -z "$SB_BIN" ] || [ -z "$ARGO_BIN" ]; then
        for dir in "/usr/bin" "/usr/local/bin" "/root"; do
            [ -d "$dir" ] || continue
            [ -z "$SB_BIN" ] && SB_BIN=$(find "$dir" -maxdepth 1 -type f -executable -name "sing-box*" ! -name "*.bak" 2>/dev/null | head -n 1)
            [ -z "$ARGO_BIN" ] && ARGO_BIN=$(find "$dir" -maxdepth 1 -type f -executable \( -name "cloudflared*" -o -name "argo*" \) 2>/dev/null | head -n 1)
        done
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构${RESET}"; exit 1 ;;
    esac
}

# ----------------- 核心修复：精准抓取版本号 -----------------
get_current_version() {
    if [ -x "$1" ]; then
        local first_line=$("$1" version 2>/dev/null | head -n 1)
        # 使用正则严格匹配数字版本号，忽略前面的文字
        local ver=$(echo "$first_line" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?')
        
        if [ -n "$ver" ]; then
            echo "$ver"
        else
            echo "$first_line" | awk '{print $1,$2}'
        fi
    else
        echo "未安装"
    fi
}
# ------------------------------------------------------------

# 增强版版本抓取，解决显示 "eyes" 的问题
get_latest_stable() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}

get_latest_prerelease() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | grep '"tag_name":' | head -n 10 | grep -E "alpha|beta|rc" | head -n 1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}

get_latest_argo() {
    curl -s "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}

update_sb() {
    tag="$1"
    [ -z "$tag" ] && return
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${tag#v}-linux-${ARCH}.tar.gz"
    tmp=$(mktemp -d)
    echo -e "${GREEN}正在下载...${RESET}"
    if curl -L -o "$tmp/sb.tgz" "$url"; then
        tar -xzf "$tmp/sb.tgz" -C "$tmp"
        cp "$SB_BIN" "$SB_BIN.bak" 2>/dev/null
        mv "$tmp"/sing-box*/sing-box "$SB_BIN" && chmod +x "$SB_BIN"
        systemctl restart sing-box 2>/dev/null
        echo -e "${GREEN}✅ 更新成功!${RESET}"
    else
        echo -e "${RED}❌ 下载失败${RESET}"
    fi
    rm -rf "$tmp"
}

update_argo() {
    tag=$(get_latest_argo)
    url="https://github.com/cloudflare/cloudflared/releases/download/${tag}/cloudflared-linux-${ARCH}"
    echo -e "${GREEN}正在下载...${RESET}"
    cp "$ARGO_BIN" "$ARGO_BIN.bak" 2>/dev/null
    if curl -L -o "$ARGO_BIN" "$url"; then
        chmod +x "$ARGO_BIN"
        systemctl restart argo 2>/dev/null
        echo -e "${GREEN}✅ Argo 更新成功!${RESET}"
    else
        echo -e "${RED}❌ 下载失败${RESET}"
        [ -f "$ARGO_BIN.bak" ] && mv "$ARGO_BIN.bak" "$ARGO_BIN"
    fi
}

# 主界面
while true; do
    clear
    scan_bins
    detect_arch
    
    # 1. 红色段：路径信息
    echo -e "${GREEN}程序路径:${RESET}"
    echo -e "  sing-box: ${RED}${SB_BIN:-未找到}${RESET}"
    echo -e "  argo:     ${RED}${ARGO_BIN:-未找到}${RESET}"
    echo

    # 2. 红色段：当前版本
    echo -e "${GREEN}当前版本信息:${RESET}"
    echo -e "  sing-box: ${RED}$(get_current_version "$SB_BIN")${RESET}"
    echo -e "  argo:     ${RED}$(get_current_version "$ARGO_BIN")${RESET}"
    echo -e "  系统架构: ${RED}$ARCH${RESET}"
    echo

    # 3. 检查云端版本
    echo -e "${GREEN}检查最新版本中...${RESET}"
    v_stable=$(get_latest_stable)
    v_pre=$(get_latest_prerelease)
    v_argo=$(get_latest_argo)

    # 4. 绿色/黄色段：操作菜单
    echo -e "1) ${GREEN}更新 sing-box${RESET} [ ${YELLOW}稳定版: ${v_stable:-获取中}${RESET} ]"
    echo -e "2) ${GREEN}更新 sing-box${RESET} [ ${YELLOW}测试版: ${v_pre:-获取中}${RESET} ]"
    echo -e "3) ${GREEN}更新 argo    ${RESET} [ ${YELLOW}最新版: ${v_argo:-获取中}${RESET} ]"
    echo -e "0) ${RED}退出程序${RESET}"
    echo

    read -p "请选择序号后回车: " choice
    case "$choice" in
        1) update_sb "$v_stable" ;;
        2) update_sb "$v_pre" ;;
        3) update_argo ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误${RESET}" ;;
    esac
    echo
    read -p "按回车继续..."
done
