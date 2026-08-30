#!/bin/bash

# 限制脚本仅支持基于 Debian/Ubuntu 的系统
if ! command -v apt-get &> /dev/null; then
    echo -e "\033[31m此脚本仅支持 Debian/Ubuntu 系统，请在支持 apt-get 的系统上运行！\033[0m"
    exit 1
fi

# 在 root 环境且未安装 sudo 时提供兼容包装
if ! command -v sudo &> /dev/null; then
    if [[ "$(id -u)" -eq 0 ]]; then
        sudo() { "$@"; }
    else
        echo -e "\033[31m缺少依赖：sudo。请先安装 sudo 后重试。\033[0m"
        exit 1
    fi
fi

# 检查并安装必要的依赖 (已移除 jq)
REQUIRED_CMDS=("curl" "wget" "dpkg" "awk" "sed" "sysctl")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "\033[33m缺少依赖：$cmd，正在安装...\033[0m"
        sudo apt-get update && sudo apt-get install -y $cmd > /dev/null 2>&1
    fi
done

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    echo -e "\033[31m(￣□￣)哇！这个脚本只支持 ARM 和 x86_64 架构哦~ 您的系统架构是：$ARCH\033[0m"
    exit 1
fi

# 获取当前 BBR 状态
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
CURRENT_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')

# 配置文件路径 (保持原名以便兼容清理旧配置)
SYSCTL_CONF="/etc/sysctl.d/99-joeyblog.conf"
MODULES_CONF="/etc/modules-load.d/joeyblog-qdisc.conf"
SECURITY_MODPROBE_CONF="/etc/modprobe.d/99-joeyblog-security.conf"

SPEEDTEST_BIN="speedtest"
OOKLA_SPEEDTEST_VERSION="1.2.0"

# ================= 核心内核管理功能 =================

revert_to_official_kernel_and_uninstall_bbrv3() {
    echo -e "\033[36m正在更新软件包列表...\033[0m"
    sudo apt-get update -y

    # shellcheck disable=SC1091
    . /etc/os-release

    local arch
    arch=$(uname -m)

    echo -e "\033[36m正在安装系统官方稳定版内核...\033[0m"
    if [[ "$ID" == "ubuntu" ]]; then
        sudo apt-get install -y linux-image-generic linux-headers-generic
    elif [[ "$ID" == "debian" ]]; then
        if [[ "$arch" == "x86_64" ]]; then
            sudo apt-get install -y linux-image-amd64 linux-headers-amd64
        elif [[ "$arch" == "aarch64" ]]; then
            sudo apt-get install -y linux-image-arm64 linux-headers-arm64
        fi
    else
        echo -e "\033[33m未能精准识别发行版，尝试通用安装命令...\033[0m"
        sudo apt-get install -y linux-image-generic || sudo apt-get install -y linux-image-amd64
    fi

    echo -e "\033[36m正在查找并卸载自定义的 BBRv3 (joeyblog) 内核...\033[0m"
    local custom_pkgs
    custom_pkgs=$(dpkg -l | awk '/^ii/ && $2 ~ /joeyblog/ {print $2}')
    
    if [[ -n "$custom_pkgs" ]]; then
        echo -e "\033[33m找到以下自定义内核包：\033[0m"
        echo "$custom_pkgs" | sed 's/^/  - /'
        # 批量卸载
        echo "$custom_pkgs" | xargs sudo apt-get remove --purge -y
        echo -e "\033[1;32m自定义内核包已彻底卸载！\033[0m"
    else
        echo -e "\033[32m系统中未发现 BBRv3 (joeyblog) 自定义内核包。\033[0m"
    fi

    echo -e "\033[36m正在更新引导加载程序...\033[0m"
    if command -v update-grub &> /dev/null; then
        sudo update-grub
    fi

    echo -e "\033[1;32m官方内核恢复及清理完成！\033[0m"
    echo -n -e "\033[33m需要重启系统来加载官方内核。是否立即重启？ (y/n): \033[0m"
    read -r REBOOT_NOW
    if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
        sudo reboot
    else
        echo -e "\033[33m请记得稍后手动执行 'sudo reboot' 来应用更改。\033[0m"
    fi
}

install_official_kernel_bbr3() {
    echo -e "\033[36m正在准备安装支持 BBR3 的官方高版本内核...\033[0m"
    sudo apt-get update -y
    
    # shellcheck disable=SC1091
    . /etc/os-release
    local arch
    arch=$(uname -m)

    if [[ "$ID" == "ubuntu" ]]; then
        echo -e "\033[36m正在为 Ubuntu 安装最新的 HWE 内核 (通常包含最新的 BBR 补丁)...\033[0m"
        sudo apt-get install --install-recommends -y linux-generic-hwe-22.04 || sudo apt-get install -y linux-image-generic
    elif [[ "$ID" == "debian" ]]; then
        echo -e "\033[36m正在为 Debian 启用 backports 源并安装最新内核...\033[0m"
        if grep -q "bullseye" /etc/os-release; then
            echo "deb http://deb.debian.org/debian bullseye-backports main" | sudo tee /etc/apt/sources.list.d/backports.list
        elif grep -q "bookworm" /etc/os-release; then
            echo "deb http://deb.debian.org/debian bookworm-backports main" | sudo tee /etc/apt/sources.list.d/backports.list
        fi
        sudo apt-get update -y
        
        # 尝试通过 lsb_release 获取版本代号，若失败则回退默认包名
        local codename
        codename=$(lsb_release -cs 2>/dev/null || awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release)
        
        if [[ "$arch" == "x86_64" ]]; then
            sudo apt-get install -t "${codename}-backports" -y linux-image-amd64 linux-headers-amd64 2>/dev/null || sudo apt-get install -y linux-image-amd64
        elif [[ "$arch" == "aarch64" ]]; then
            sudo apt-get install -t "${codename}-backports" -y linux-image-arm64 linux-headers-arm64 2>/dev/null || sudo apt-get install -y linux-image-arm64
        fi
    else
        echo -e "\033[33m未能精准识别发行版，尝试通用安装命令...\033[0m"
        sudo apt-get install -y linux-image-generic || sudo apt-get install -y linux-image-amd64
    fi

    echo -e "\033[36m正在更新引导加载程序...\033[0m"
    if command -v update-grub &> /dev/null; then
        sudo update-grub
    fi

    echo -e "\033[1;32m内核安装执行完毕！(由于不同发行版的官方编译策略，若原生仍未带BBRv3，请考虑 Xanmod 源)\033[0m"
    echo -n -e "\033[33m是否立即重启系统以应用新内核？ (y/n): \033[0m"
    read -r REBOOT_NOW
    if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
        sudo reboot
    fi
}

# ================= 网络优化与测速功能 =================

clean_sysctl_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

clean_smart_tuning_conf() {
    sudo touch "$SYSCTL_CONF"
    local keys=(
        "net.core.rmem_max" "net.core.wmem_max" "net.core.optmem_max"
        "net.core.netdev_max_backlog" "net.core.somaxconn" "net.ipv4.tcp_wmem"
        "net.ipv4.tcp_rmem" "net.ipv4.tcp_limit_output_bytes" 
        "net.ipv4.tcp_slow_start_after_idle" "net.ipv4.tcp_notsent_lowat"
        "net.ipv4.tcp_autocorking" "net.ipv4.tcp_no_metrics_save"
        "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_fastopen"
        "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_moderate_rcvbuf" "net.ipv4.tcp_ecn"
    )
    for key in "${keys[@]}"; do
        sudo sed -i "/${key}/d" "$SYSCTL_CONF"
    done
}

apply_apac_tuning() {
    echo -e "\033[36m正在应用亚太机器 TCP 调优...\033[0m"
    if sudo sysctl -w net.ipv4.tcp_wmem="4096 16384 12582912" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_rmem="4096 131072 33554432" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_limit_output_bytes="4194304" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_slow_start_after_idle="0" > /dev/null; then
        echo -e "\033[1;32m✔ 亚太机器 TCP 调优已立即生效\033[0m"
    else
        echo -e "\033[31m✘ 亚太机器 TCP 调优应用失败。\033[0m"
        return 1
    fi

    clean_smart_tuning_conf
    {
        echo "net.ipv4.tcp_wmem = 4096 16384 12582912"
        echo "net.ipv4.tcp_rmem = 4096 131072 33554432"
        echo "net.ipv4.tcp_limit_output_bytes = 4194304"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
    } | sudo tee -a "$SYSCTL_CONF" > /dev/null
    echo -e "\033[1;32m✔ 亚太机器 TCP 调优已永久写入配置\033[0m"
}

is_positive_number() {
    awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

get_tcp_buffer_cap_mb() {
    local mem_kb
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    if ! [[ "$mem_kb" =~ ^[0-9]+$ ]]; then echo 64; elif (( mem_kb < 524288 )); then echo 16; elif (( mem_kb < 1048576 )); then echo 32; else echo 64; fi
}

calculate_smart_buffer_mb() {
    local bandwidth="$1"
    local region="$2"
    local cap_mb="$3"
    local buffer_mb=16

    bandwidth="${bandwidth%.*}"
    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || (( bandwidth <= 0 )); then bandwidth=1000; fi

    if [[ "$region" == "overseas" ]]; then
        if (( bandwidth < 500 )); then buffer_mb=16; elif (( bandwidth < 1000 )); then buffer_mb=48; else buffer_mb=64; fi
    else
        if (( bandwidth < 500 )); then buffer_mb=8; elif (( bandwidth < 1000 )); then buffer_mb=12; elif (( bandwidth < 2000 )); then buffer_mb=16; elif (( bandwidth < 5000 )); then buffer_mb=24; elif (( bandwidth < 10000 )); then buffer_mb=28; else buffer_mb=32; fi
    fi

    if (( buffer_mb > cap_mb )); then buffer_mb="$cap_mb"; fi
    echo "$buffer_mb"
}

get_ookla_speedtest_download_url() {
    local cpu_arch
    cpu_arch=$(uname -m)
    case "$cpu_arch" in
        x86_64) echo "https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_SPEEDTEST_VERSION}-linux-x86_64.tgz" ;;
        aarch64) echo "https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_SPEEDTEST_VERSION}-linux-aarch64.tgz" ;;
        *) return 1 ;;
    esac
}

is_ookla_speedtest() {
    local bin_path="${1:-}"
    [[ -n "$bin_path" ]] || return 1
    "$bin_path" --version 2>&1 | grep -q "Speedtest by Ookla ${OOKLA_SPEEDTEST_VERSION}"
}

remove_speedtest_cli() {
    local speedtest_path=""
    speedtest_path=$(command -v speedtest 2>/dev/null || true)
    if [[ -n "$speedtest_path" ]] && ! is_ookla_speedtest "$speedtest_path"; then
        if dpkg -S "$speedtest_path" 2>/dev/null | grep -q '^speedtest-cli:'; then
            sudo apt-get remove --purge -y speedtest-cli > /dev/null 2>&1 || true
        fi
        if [[ "$speedtest_path" != "/usr/local/bin/speedtest" ]]; then
            sudo rm -f "$speedtest_path" 2>/dev/null || true
        fi
    fi
    hash -r 2>/dev/null || true
}

install_ookla_speedtest() {
    local download_url
    download_url=$(get_ookla_speedtest_download_url) || return 1
    echo -e "\033[33m正在安装 Ookla speedtest ${OOKLA_SPEEDTEST_VERSION}...\033[0m"
    (
        cd /tmp || exit 1
        rm -rf speedtest speedtest.tgz speedtest.5 speedtest.md
        wget -q "$download_url" -O speedtest.tgz
        tar -xzf speedtest.tgz
        sudo mv speedtest /usr/local/bin/speedtest
        sudo chmod +x /usr/local/bin/speedtest
        rm -f speedtest.tgz speedtest.5 speedtest.md
    ) || return 1
    SPEEDTEST_BIN="/usr/local/bin/speedtest"
    hash -r 2>/dev/null || true
}

ensure_ookla_speedtest() {
    remove_speedtest_cli
    if command -v speedtest > /dev/null 2>&1; then
        SPEEDTEST_BIN=$(command -v speedtest)
        if is_ookla_speedtest "$SPEEDTEST_BIN"; then return 0; fi
    fi
    install_ookla_speedtest
}

run_speedtest_once() {
    local servers_list
    local speedtest_output=""
    local attempt=0

    servers_list=$("$SPEEDTEST_BIN" --accept-license --accept-gdpr --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
    [[ -z "$servers_list" ]] && servers_list="auto"

    for server_id in $servers_list; do
        attempt=$((attempt + 1))
        (( attempt > 5 )) && break

        if [[ "$server_id" == "auto" ]]; then
            speedtest_output=$("$SPEEDTEST_BIN" --accept-license --accept-gdpr 2>&1)
        else
            speedtest_output=$("$SPEEDTEST_BIN" --accept-license --accept-gdpr --server-id="$server_id" 2>&1)
        fi

        SPEEDTEST_DOWNLOAD=$(echo "$speedtest_output" | sed -nE 's/.*[Dd]ownload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
        SPEEDTEST_UPLOAD=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)

        if is_positive_number "$SPEEDTEST_UPLOAD" && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then return 0; fi
    done
    return 1
}

run_speedtest_measurement() {
    SPEEDTEST_DOWNLOAD=""
    SPEEDTEST_UPLOAD=""
    ensure_ookla_speedtest || return 1
    echo -e "\033[36m正在运行 Ookla Speedtest 测速，请稍候...\033[0m"
    if ! run_speedtest_once; then
        remove_speedtest_cli
        install_ookla_speedtest || return 1
        run_speedtest_once || true
    fi
    if is_positive_number "$SPEEDTEST_UPLOAD"; then
        echo -e "\033[36m  Download: \033[1;32m${SPEEDTEST_DOWNLOAD:-0} Mbit/s\033[0m"
        echo -e "\033[36m  Upload:   \033[1;32m${SPEEDTEST_UPLOAD} Mbit/s\033[0m"
        return 0
    fi
    return 1
}

read_positive_value() {
    local prompt="$1"
    local default_value="$2"
    local value=""
    while true; do
        echo -n -e "$prompt" >&2
        read -r value
        value="${value:-$default_value}"
        if is_positive_number "$value"; then echo "$value"; return 0; fi
        echo -e "\033[31m请输入有效的正数。\033[0m" >&2
    done
}

select_tuning_rtt() {
    local choice=""
    while true; do
        echo -e "\033[36m请选择 buffer 档位模式：\033[0m"
        echo -e "\033[33m 1. 亚太档位（通常 RTT < 100ms）\033[0m"
        echo -e "\033[33m 2. 美欧档位（通常 RTT 150-300ms）\033[0m"
        echo -n -e "\033[36m请选择 (1-2): \033[0m"
        read -r choice
        case "$choice" in
            1) SMART_REGION="亚太"; SMART_REGION_CODE="asia"; return 0 ;;
            2) SMART_REGION="美欧"; SMART_REGION_CODE="overseas"; return 0 ;;
        esac
    done
}

load_qdisc_module() {
    local qdisc_name="$1"
    local module_name="sch_$qdisc_name"

    [[ "$qdisc_name" == "fq" ]] && return 0

    if lsmod | grep -q "^${module_name//-/_}"; then
        return 0
    fi

    if modinfo "$module_name" > /dev/null 2>&1; then
        sudo modprobe "$module_name" 2>/dev/null
        return $?
    fi

    return 1
}

apply_smart_bandwidth_tuning() {
    local upload_mbps=""
    local download_mbps=""
    local cap_mb=""
    local buffer_mb=""
    local buffer_bytes=""
    local smart_algo="bbr"
    local smart_qdisc="fq"

    echo -e "\033[36m正在准备 BBR 智能带宽优化...\033[0m"
    if ! load_qdisc_module "$smart_qdisc"; then
        echo -e "\033[31m✘ 错误：当前内核不支持或缺失 $smart_qdisc 模块。\033[0m"
        return 1
    fi
    sudo sysctl -w net.core.default_qdisc="$smart_qdisc" > /dev/null
    sudo sysctl -w net.ipv4.tcp_congestion_control="$smart_algo" > /dev/null

    if run_speedtest_measurement; then
        upload_mbps="${SPEEDTEST_UPLOAD%.*}"
    else
        upload_mbps=$(read_positive_value "\033[36m请输入上传带宽(Mbit/s，默认 1000): \033[0m" "1000")
    fi

    select_tuning_rtt
    cap_mb=$(get_tcp_buffer_cap_mb)
    buffer_mb=$(calculate_smart_buffer_mb "$upload_mbps" "$SMART_REGION_CODE" "$cap_mb")
    buffer_bytes=$((buffer_mb * 1024 * 1024))

    sudo sysctl -w net.core.rmem_max="$buffer_bytes" > /dev/null
    sudo sysctl -w net.core.wmem_max="$buffer_bytes" > /dev/null
    sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 $buffer_bytes" > /dev/null
    sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 $buffer_bytes" > /dev/null

    clean_sysctl_conf
    clean_smart_tuning_conf
    {
        echo "net.core.default_qdisc=$smart_qdisc"
        echo "net.ipv4.tcp_congestion_control=$smart_algo"
        echo "net.core.rmem_max = $buffer_bytes"
        echo "net.core.wmem_max = $buffer_bytes"
        echo "net.ipv4.tcp_wmem = 4096 65536 $buffer_bytes"
        echo "net.ipv4.tcp_rmem = 4096 87380 $buffer_bytes"
    } | sudo tee -a "$SYSCTL_CONF" > /dev/null

    echo -e "\033[1;32m✔ 智能优化配置已永久写入配置\033[0m"
}

apply_extreme_speedtest_tuning() {
    local extreme_algo="bbr"
    local extreme_qdisc="fq"
    local buffer_bytes="1073741824"

    echo -e "\033[36m正在应用极限测速挑战模式...\033[0m"
    if ! load_qdisc_module "$extreme_qdisc"; then
        echo -e "\033[31m✘ 错误：当前内核不支持或缺失 $extreme_qdisc 模块。\033[0m"
        return 1
    fi
    sudo sysctl -w net.core.default_qdisc="$extreme_qdisc" > /dev/null
    sudo sysctl -w net.ipv4.tcp_congestion_control="$extreme_algo" > /dev/null

    clean_sysctl_conf
    {
        echo "net.core.default_qdisc=$extreme_qdisc"
        echo "net.ipv4.tcp_congestion_control=$extreme_algo"
        echo "net.core.rmem_max = $buffer_bytes"
        echo "net.core.wmem_max = $buffer_bytes"
    } | sudo tee -a "$SYSCTL_CONF" > /dev/null
    echo -e "\033[1;32m✔ 疯批模式配置已永久写入配置\033[0m"
}

clear_network_optimizations() {
    echo -e "\033[36m正在清空网络优化配置...\033[0m"
    clean_sysctl_conf
    clean_smart_tuning_conf
    sudo rm -f "$MODULES_CONF"
    sudo rm -f "$SECURITY_MODPROBE_CONF"
    sudo sysctl --system > /dev/null 2>&1 || true
    echo -e "\033[1;32m✔ 已清空所有关联的网络优化持久配置\033[0m"
}

ensure_iproute2_tools() {
    if command -v ip > /dev/null 2>&1 && command -v tc > /dev/null 2>&1; then return 0; fi
    sudo apt-get update > /dev/null 2>&1 || true
    sudo apt-get install -y iproute2 > /dev/null 2>&1
}

get_default_route_interfaces() {
    { ip -o route show default 2>/dev/null || true; ip -o -6 route show default 2>/dev/null || true; } | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u
}

apply_qdisc_to_active_interfaces() {
    local qdisc_name="$1"
    local iface
    ensure_iproute2_tools || return 0
    while IFS= read -r iface; do
        [[ -n "$iface" ]] && sudo tc qdisc replace dev "$iface" root "$qdisc_name" 2>/dev/null || true
    done < <(get_default_route_interfaces)
}

persist_qdisc_module() {
    local qdisc_name="$1"
    local module_name="sch_$qdisc_name"
    if [[ "$qdisc_name" == "fq" ]]; then sudo rm -f "$MODULES_CONF"; return 0; fi
    if modinfo "$module_name" > /dev/null 2>&1 || lsmod | grep -q "^${module_name//-/_}"; then
        echo "$module_name" | sudo tee "$MODULES_CONF" > /dev/null
    else
        sudo rm -f "$MODULES_CONF"
    fi
}

ask_to_save() {
    echo -e "\033[36m正在应用配置...\033[0m"
    
    if ! load_qdisc_module "$QDISC"; then
        echo -e "\033[31m✘ 错误：当前内核不支持或缺失 $QDISC 模块，配置应用终止！\033[0m"
        return 1
    fi

    sudo sysctl -w net.core.default_qdisc="$QDISC" > /dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$ALGO" > /dev/null 2>&1
    apply_qdisc_to_active_interfaces "$QDISC" || return 1
    
    NEW_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    NEW_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    
    if [[ "$NEW_QDISC" == "$QDISC" && "$NEW_ALGO" == "$ALGO" ]]; then
        echo -e "\033[1;32m✔ 配置已立即生效！\033[0m"
    else
        echo -e "\033[31m✘ 配置应用失败！\033[0m"
        return 1
    fi
    
    echo -n -e "\033[36m(｡♥‿♥｡) 要将这些配置永久保存吗？(y/n): \033[0m"
    read -r SAVE
    if [[ "$SAVE" == "y" || "$SAVE" == "Y" ]]; then
        clean_sysctl_conf
        echo "net.core.default_qdisc=$QDISC" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        echo "net.ipv4.tcp_congestion_control=$ALGO" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        sudo sysctl --system > /dev/null 2>&1
        persist_qdisc_module "$QDISC"
    fi
}

print_separator() {
    echo -e "\033[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# ================= 主菜单 =================
clear
print_separator
echo -e "\033[1;35m(☆ω☆)✧*｡ 欢迎使用 BBR 综合管理与调优脚本 ｡*✧(☆ω☆)\033[0m"
print_separator
echo -e "\033[36m当前 TCP 拥塞控制算法：\033[0m\033[1;32m${CURRENT_ALGO:-未设置}\033[0m"
echo -e "\033[36m当前队列管理算法：    \033[0m\033[1;32m${CURRENT_QDISC:-未设置}\033[0m"
print_separator

echo -e "\033[1;33m╭( ･ㅂ･)و ✧ 请选择以下操作：\033[0m"
echo -e "\033[33m 1. 🔄 恢复系统官方内核并彻底卸载 BBRv3 (joeyblog)\033[0m"
echo -e "\033[33m 2. 🔍 检查 BBR 状态与当前内核信息\033[0m"
echo -e "\033[33m 3. ⚡ 启用 BBR + FQ\033[0m"
echo -e "\033[33m 4. ⚡ 启用 BBR + FQ_CODEL\033[0m"
echo -e "\033[33m 5. ⚡ 启用 BBR + FQ_PIE\033[0m"
echo -e "\033[33m 6. ⚡ 启用 BBR + CAKE\033[0m"
echo -e "\033[33m 7. 🌏 亚太机器 TCP 调优\033[0m"
echo -e "\033[33m 8. 🧠 BBR 智能带宽优化\033[0m"
echo -e "\033[33m 9. 🧹 清空网络优化配置\033[0m"
echo -e "\033[33m10. 🧨 BBR 疯批模式（极限测速挑战）\033[0m"
echo -e "\033[33m11. 🚀 安装支持 BBRv3 的官方/高版本稳定内核\033[0m"
print_separator
echo -n -e "\033[36m请选择一个操作 (1-11): \033[0m"
read -r ACTION

case "$ACTION" in
    1)
        revert_to_official_kernel_and_uninstall_bbrv3
        ;;
    2)
        echo -e "\033[36m=== 系统 BBR 与内核版本状态检查 ===\033[0m"
        echo -e "\033[33m当前运行内核：$(uname -r)\033[0m"
        
        BBR_MODULE_INFO=$(modinfo tcp_bbr 2>/dev/null)
        if [[ -n "$BBR_MODULE_INFO" ]]; then
            BBR_VERSION=$(echo "$BBR_MODULE_INFO" | awk '/^version:/ {print $2}')
            if [[ "$BBR_VERSION" == "3" ]]; then
                echo -e "\033[32m当前 BBR 模块版本：v3 (可能来自自定义内核)\033[0m"
            else
                echo -e "\033[32m当前 BBR 模块版本：v1 (标准版 BBR)\033[0m"
            fi
        else
            echo -e "\033[32m未检测到独立的 tcp_bbr 模块（可能已直接编译进内核中）。\033[0m"
        fi
        
        echo -e "\n\033[36m当前系统中安装的内核包列表：\033[0m"
        dpkg -l | awk '/^ii/ && $2 ~ /^linux-image-/ {print "  - " $2 " (" $3 ")"}'
        
        if dpkg -l | grep -q "joeyblog"; then
            echo -e "\n\033[31m检测到您依然安装了 BBRv3 (joeyblog) 内核，若需卸载请选择主菜单的选项 1。\033[0m"
        fi
        ;;
    3) ALGO="bbr"; QDISC="fq"; ask_to_save ;;
    4) ALGO="bbr"; QDISC="fq_codel"; ask_to_save ;;
    5) ALGO="bbr"; QDISC="fq_pie"; ask_to_save ;;
    6) ALGO="bbr"; QDISC="cake"; ask_to_save ;;
    7) apply_apac_tuning ;;
    8) apply_smart_bandwidth_tuning ;;
    9) clear_network_optimizations ;;
    10) apply_extreme_speedtest_tuning ;;
    11) install_official_kernel_bbr3 ;;
    *) echo -e "\033[31m无效的选项，请输入 1-11 之间的数字。\033[0m" ;;
esac
