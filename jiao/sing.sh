#!/bin/bash 

BASE_DIR="/etc/sing-box"
SB_BIN=""
ARGO_BIN=""
ARCH="amd64"

GREEN="\033[32m"
RESET="\033[0m"

echo_green() {
    echo -e "${GREEN}$1${RESET}"
}

scan_bins() {
    SB_BIN=""
    ARGO_BIN=""

    for f in "$BASE_DIR"/*; do
        [ -f "$f" ] || continue
        [ -x "$f" ] || continue

        case "$f" in
            *.bak|*.old|*.backup)
                continue
                ;;
        esac

        name=$(basename "$f")

        case "$name" in
            *sing*|*Sing*|*SING*)
                SB_BIN="$f"
                ;;
            *argo*|*cloudflared*|*Argo*|*ARGO*)
                ARGO_BIN="$f"
                ;;
        esac
    done
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo_green "不支持的架构"; exit 1 ;;
    esac
}

get_current_version() {
    if [ -x "$1" ]; then
        "$1" version 2>/dev/null | head -n 1
    else
        echo "未安装"
    fi
}

get_latest_stable() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | grep '"tag_name"' | head -n 1 \
    | sed -E 's/.*"([^"]+)".*/\1/'
}

get_latest_prerelease() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" \
    | awk '
        /"tag_name"/ {
            gsub(/[",]/, "", $2);
            tag=$2
        }
        /"prerelease": true/ {
            print tag;
            exit
        }
    '
}

get_latest_argo() {
    curl -s "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
    | grep '"tag_name"' | head -n 1 \
    | sed -E 's/.*"([^"]+)".*/\1/'
}

backup_file() {
    cp "$1" "$1.bak"
}

rollback_file() {
    if [ -f "$1.bak" ]; then
        mv "$1.bak" "$1"
        chmod +x "$1"
        echo_green "已回滚到更新前版本"
    fi
}

update_sing_box() {
    latest="$1"
    url="https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${latest#v}-linux-${ARCH}.tar.gz"

    tmp=$(mktemp -d)
    cd "$tmp" || exit 1

    backup_file "$SB_BIN"

    if ! curl -L -o sb.tar.gz "$url"; then
        rollback_file "$SB_BIN"
        echo_green "下载失败"
        return
    fi

    if ! tar -xzf sb.tar.gz; then
        rollback_file "$SB_BIN"
        echo_green "解压失败"
        return
    fi

    mv sing-box*/sing-box "$SB_BIN"
    chmod +x "$SB_BIN"

    cd /
    rm -rf "$tmp"

    systemctl restart sing-box 2>/dev/null

    echo_green "sing-box 已更新到 $latest"
}

update_argo() {
    latest=$(get_latest_argo)
    url="https://github.com/cloudflare/cloudflared/releases/download/${latest}/cloudflared-linux-${ARCH}"

    backup_file "$ARGO_BIN"

    if ! curl -L -o "$ARGO_BIN" "$url"; then
        rollback_file "$ARGO_BIN"
        echo_green "下载失败"
        return
    fi

    chmod +x "$ARGO_BIN"

    systemctl restart argo 2>/dev/null

    echo_green "argo 已更新到 $latest"
}

menu() {
    clear
    scan_bins
    detect_arch

    latest_sb_stable=$(get_latest_stable)
    latest_sb_pre=$(get_latest_prerelease)
    latest_argo=$(get_latest_argo)

    echo_green "=============================="
    echo_green "     sing-box & argo 更新器"
    echo_green "=============================="
    echo

    echo_green "二进制路径:"
    echo_green "  sing-box: ${SB_BIN:-未找到}"
    echo_green "  argo:     ${ARGO_BIN:-未找到}"
    echo

    echo_green "系统架构: $ARCH"
    echo

    echo_green "当前版本:"
    echo_green "  sing-box: $(get_current_version "$SB_BIN")"
    echo_green "  argo:     $(get_current_version "$ARGO_BIN")"
    echo

    echo_green "最新稳定版:"
    echo_green "  sing-box: $latest_sb_stable"
    echo_green "  argo:     $latest_argo"
    echo

    echo_green "最新测试版:"
    echo_green "  sing-box: $latest_sb_pre"
    echo

    echo_green "1) 更新 sing-box（稳定版）"
    echo_green "2) 更新 sing-box（测试版）"
    echo_green "3) 更新 argo"
    echo_green "4) 退出"
    echo

    read -rp "$(echo -e ${GREEN}请选择操作:${RESET} ) " choice

    case "$choice" in
        1) [ -n "$SB_BIN" ] && update_sing_box "$latest_sb_stable" || echo_green "未找到 sing-box" ;;
        2) [ -n "$SB_BIN" ] && update_sing_box "$latest_sb_pre" || echo_green "未找到 sing-box" ;;
        3) [ -n "$ARGO_BIN" ] && update_argo || echo_green "未找到 argo" ;;
        4) exit 0 ;;
        *) echo_green "无效选项" ;;
    esac

    read -rp "$(echo -e ${GREEN}按回车继续...${RESET})"
}

while true; do
    menu
done
