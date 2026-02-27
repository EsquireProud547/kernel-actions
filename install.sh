#!/bin/bash

# ==============================================================================
# Linux 内核与 BBRv3 管理脚本
# 版本: v1.0
# 支持: Debian/Ubuntu 系发行版 (AMD64/ARM64)
# ==============================================================================

# ---------------------------- 配置区 ----------------------------
# GitHub 仓库配置（格式：用户名/仓库名）
GITHUB_REPO="EsquireProud547/kernel-actions"

# 颜色定义
declare -r GREEN='\033[1;32m'
declare -r YELLOW='\033[33m'
declare -r BLUE='\033[36m'
declare -r PURPLE='\033[1;35m'
declare -r RED='\033[31m'
declare -r RESET='\033[0m'

# 系统配置文件路径
declare -r SYSCTL_CONF="/etc/sysctl.d/99-custom-kernel.conf"
declare -r MODULES_CONF="/etc/modules-load.d/custom-qdisc.conf"

# ---------------------------- 初始化检查 ----------------------------

# 系统兼容性检查：仅支持 Debian/Ubuntu 系发行版
check_system_compatibility() {
    if ! command -v apt-get &> /dev/null; then
        echo -e "${RED}错误：此脚本仅支持基于 Debian/Ubuntu 的系统！${RESET}"
        exit 1
    fi
}

# 依赖项自动安装检测
install_dependencies() {
    local required_cmds=("curl" "wget" "dpkg" "awk" "sed" "sysctl" "jq" "grep" "sha256sum")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${YELLOW}缺少依赖：$cmd，正在安装...${RESET}"
            if ! sudo apt-get update > /dev/null 2>&1 && \
               sudo apt-get install -y "$cmd" > /dev/null 2>&1; then
                echo -e "${RED}错误：安装 $cmd 失败${RESET}"
                exit 1
            fi
        fi
    done
}

# 系统架构检测与 Debian 架构映射
detect_architecture() {
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64)  
            DEB_ARCH="amd64"
            ;;
        aarch64) 
            DEB_ARCH="arm64"
            ;;
        *)
            echo -e "${RED}错误：仅支持 AMD64 (x86_64) 和 ARM64 (aarch64) 架构${RESET}"
            echo -e "${RED}当前架构：$arch${RESET}"
            exit 1
            ;;
    esac
    
    ARCH="$arch"
}

# ---------------------------- 内核管理函数 ----------------------------

# 检测当前运行内核的构建类型（BBRv3 集成版或原版）
check_current_kernel_type() {
    local kernel_ver=$(uname -r)
    
    if [[ "$kernel_ver" == *"bbrv3"* ]]; then
        echo -e "${GREEN}BBRv3 集成版${RESET}"
    else
        echo -e "${YELLOW}原版或其他${RESET}"
    fi
}

# 清理 sysctl 配置文件中的网络相关配置项
clean_sysctl_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

# 尝试加载指定的队列算法内核模块
# 参数：$1=目标算法, $2=当前算法
load_qdisc_module() {
    local target_qdisc="$1"
    local current_qdisc="$2"
    local module_name="sch_$target_qdisc"
    
    # 先尝试直接设置
    if sudo sysctl -w net.core.default_qdisc="$target_qdisc" > /dev/null 2>&1; then
        sudo sysctl -w net.core.default_qdisc="$current_qdisc" > /dev/null 2>&1
        return 0
    fi
    
    # 尝试加载模块
    if sudo modprobe "$module_name" 2>/dev/null; then
        sudo sysctl -w net.core.default_qdisc="$current_qdisc" > /dev/null 2>&1
        return 0
    else
        return 1
    fi
}

# ---------------------------- 配置管理函数 ----------------------------

# 交互式保存网络优化配置
ask_to_save() {
    local target_algo="$ALGO"
    local target_qdisc="$QDISC"
    local current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "${BLUE}正在临时应用配置...${RESET}"
    
    # 尝试加载模块并应用配置
    load_qdisc_module "$target_qdisc" "$current_qdisc"
    sudo sysctl -w net.core.default_qdisc="$target_qdisc" > /dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$target_algo" > /dev/null 2>&1
    
    # 验证配置
    local new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local new_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    
    if [[ "$new_qdisc" == "$target_qdisc" && "$new_algo" == "$target_algo" ]]; then
        echo -e "${GREEN}✓ 配置已临时生效！${RESET}"
        echo -e "   队列算法：${GREEN}$new_qdisc${RESET}"
        echo -e "   拥塞控制：${GREEN}$new_algo${RESET}"
        
        # 询问是否永久保存
        echo -n -e "${BLUE}是否永久保存？(y/n): ${RESET}"
        read -r SAVE
        
        if [[ "$SAVE" =~ ^[yY]$ ]]; then
            save_permanent_config "$target_qdisc" "$target_algo"
        else
            echo -e "${YELLOW}已取消永久保存，重启后配置将失效${RESET}"
        fi
    else
        echo -e "${RED}✘ 应用失败！内核可能不支持该组合。${RESET}"
        echo -e "   期望值：$target_qdisc + $target_algo"
        echo -e "   实际值：$new_qdisc + $new_algo"
    fi
}

# 保存永久配置
save_permanent_config() {
    local target_qdisc="$1"
    local target_algo="$2"
    
    clean_sysctl_conf
    
    echo "net.core.default_qdisc=$target_qdisc" | sudo tee -a "$SYSCTL_CONF" > /dev/null
    echo "net.ipv4.tcp_congestion_control=$target_algo" | sudo tee -a "$SYSCTL_CONF" > /dev/null
    sudo sysctl --system > /dev/null 2>&1
    
    # 处理模块自启
    if [[ "$target_qdisc" != "fq" && "$target_qdisc" != "fq_codel" ]]; then
        echo "sch_$target_qdisc" | sudo tee "$MODULES_CONF" > /dev/null
        echo -e "${GREEN}✓ 模块 sch_$target_qdisc 已设置为开机自启${RESET}"
    else
        sudo rm -f "$MODULES_CONF"
    fi
    
    echo -e "${GREEN}✓ 配置已永久保存${RESET}"
}

# 更新系统引导加载程序
update_bootloader() {
    echo -e "${BLUE}正在更新引导加载程序...${RESET}"
    
    if command -v update-grub &> /dev/null; then
        if ! sudo update-grub; then
            echo -e "${YELLOW}警告：update-grub 执行异常${RESET}"
        fi
    else
        echo -e "${YELLOW}提示：未找到 update-grub（ARM 系统通常自动处理）${RESET}"
    fi
}

# ---------------------------- 软件包管理函数 ----------------------------

# 安装下载的 Debian 软件包
install_packages() {
    local tmp_dir="/tmp/kernel-install-$$"
    
    # 创建临时目录
    if ! mkdir -p "$tmp_dir"; then
        echo -e "${RED}错误：创建临时目录失败${RESET}"
        return 1
    fi
    
    # 移动下载的文件
    mv /tmp/linux-*.deb "$tmp_dir/" 2>/dev/null || true
    mv /tmp/checksums.txt "$tmp_dir/" 2>/dev/null || true
    
    # 检查是否存在 deb 包
    if ! ls "$tmp_dir"/*.deb &> /dev/null; then
        echo -e "${RED}错误：未找到 .deb 包${RESET}"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    cd "$tmp_dir" || return 1
    
    # 校验文件完整性
    verify_checksums
    
    # 执行安装
    echo -e "${BLUE}正在安装新内核...${RESET}"
    if sudo apt install -y ./*.deb; then
        update_bootloader
        echo -e "${GREEN}✓ 安装成功！${RESET}"
        prompt_reboot
    else
        echo -e "${RED}✘ 安装失败${RESET}"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    rm -rf "$tmp_dir"
}

# 校验文件完整性
verify_checksums() {
    if [[ -f checksums.txt ]]; then
        echo -e "${BLUE}正在校验下载文件的完整性...${RESET}"
        if sha256sum -c checksums.txt --quiet; then
            echo -e "${GREEN}✓ 所有文件校验通过${RESET}"
        else
            echo -e "${RED}✘ 文件校验失败，请重新下载${RESET}"
            rm -rf "$tmp_dir"
            exit 1
        fi
    else
        echo -e "${YELLOW}警告：未找到 checksums.txt，跳过校验${RESET}"
    fi
}

# 提示重启
prompt_reboot() {
    echo -n -e "${YELLOW}立即重启？(y/n): ${RESET}"
    read -r REBOOT
    
    if [[ "$REBOOT" =~ ^[yY]$ ]]; then
        sudo reboot
    else
        echo -e "${YELLOW}请手动重启以应用新内核${RESET}"
    fi
}

# ---------------------------- GitHub  releases 下载函数 ----------------------------

# 从 GitHub Releases 获取并安装内核
# 参数：$1=模式 (latest_bbrv3/latest_vanilla/list_all)
fetch_and_install() {
    local mode="$1"
    local api_url="https://api.github.com/repos/$GITHUB_REPO/releases"
    
    echo -e "${BLUE}正在从 GitHub ($GITHUB_REPO) 获取版本信息...${RESET}"
    
    # 获取 API 响应
    local response=$(curl -sL "$api_url") || {
        echo -e "${RED}错误：无法连接 GitHub API${RESET}"
        return 1
    }
    
    if [[ -z "$response" ]]; then
        echo -e "${RED}错误：API 响应为空${RESET}"
        return 1
    fi
    
    # 检查 API 错误
    if echo "$response" | jq -e '.message' > /dev/null 2>&1; then
        local error_msg=$(echo "$response" | jq -r '.message')
        echo -e "${RED}API 错误：$error_msg${RESET}"
        return 1
    fi
    
    # 确定目标版本
    local target_tag=""
    local target_name=""
    
    case "$mode" in
        "list_all")
            select_version_interactive "$response"
            return $?
            ;;
        "latest_bbrv3")
            target_tag=$(find_latest_release "$response" "With BBRv3")
            ;;
        "latest_vanilla")
            target_tag=$(find_latest_release "$response" "Vanilla")
            ;;
    esac
    
    if [[ -z "$target_tag" ]]; then
        echo -e "${RED}错误：未找到匹配的 Release${RESET}"
        return 1
    fi
    
    download_and_install_version "$response" "$target_tag"
}

# 交互式版本选择
select_version_interactive() {
    local response="$1"
    
    echo -e "${BLUE}可用版本列表（匹配架构 $DEB_ARCH）：${RESET}"
    
    local releases=$(echo "$response" | jq -r --arg arch "$DEB_ARCH" '
        .[] |
        select(.assets[] | .name | contains($arch) and endswith(".deb")) |
        "\(.tag_name)|\(.name)"' | head -n 15)
    
    if [[ -z "$releases" ]]; then
        echo -e "${RED}错误：未找到匹配的 Release${RESET}"
        return 1
    fi
    
    # 显示列表
    local i=1
    while IFS='|' read -r tag name; do
        echo -e "${YELLOW} $i. ${RESET} $name ${BLUE}($tag)${RESET}"
        release_array+=("$tag|$name")
        ((i++))
    done <<< "$releases"
    
    # 用户选择
    echo -n -e "${BLUE}请输入编号: ${RESET}"
    read -r choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#release_array[@]} )); then
        echo -e "${RED}错误：无效选择${RESET}"
        return 1
    fi
    
    local selected="${release_array[$((choice-1))]}"
    local target_tag="${selected%%|*}"
    
    download_and_install_version "$response" "$target_tag"
}

# 查找最新版本
find_latest_release() {
    local response="$1"
    local filter_key="$2"
    
    echo "$response" | jq -r --arg key "$filter_key" --arg arch "$DEB_ARCH" '
        .[] |
        select(.name | contains($key)) |
        select(.assets[] | .name | contains($arch) and endswith(".deb")) |
        .tag_name' | head -n 1
}

# 下载并安装指定版本
download_and_install_version() {
    local response="$1"
    local target_tag="$2"
    
    echo -e "${GREEN}找到目标版本：$target_tag${RESET}"
    echo -e "${BLUE}正在获取下载链接...${RESET}"
    
    # 解析资源
    local assets=$(echo "$response" | jq -r --arg tag "$target_tag" '
        .[] |
        select(.tag_name == $tag) |
        .assets[] |
        "\(.name)|\(.browser_download_url)"')
    
    if [[ -z "$assets" ]]; then
        echo -e "${RED}错误：未找到附件${RESET}"
        return 1
    fi
    
    # 分类 URL
    local deb_urls=()
    local checksum_url=""
    
    while IFS='|' read -r name url; do
        if [[ "$name" == *.deb && "$name" == *"$DEB_ARCH"* ]]; then
            deb_urls+=("$url")
        elif [[ "$name" == "checksums.txt" ]]; then
            checksum_url="$url"
        fi
    done <<< "$assets"
    
    if [[ ${#deb_urls[@]} -eq 0 ]]; then
        echo -e "${RED}错误：未找到匹配的 .deb 文件${RESET}"
        return 1
    fi
    
    # 清理旧文件
    rm -f /tmp/linux-*.deb /tmp/checksums.txt
    
    # 下载校验文件
    if [[ -n "$checksum_url" ]]; then
        echo -e "${YELLOW}下载校验文件...${RESET}"
        if ! wget -q --show-progress "$checksum_url" -O /tmp/checksums.txt; then
            echo -e "${YELLOW}警告：下载 checksums.txt 失败，继续安装...${RESET}"
            rm -f /tmp/checksums.txt
        fi
    fi
    
    # 下载软件包
    echo -e "${YELLOW}下载软件包...${RESET}"
    for url in "${deb_urls[@]}"; do
        if ! wget -q --show-progress "$url" -P /tmp/; then
            echo -e "${RED}错误：下载失败 $url${RESET}"
            rm -f /tmp/linux-*.deb /tmp/checksums.txt
            return 1
        fi
    done
    
    install_packages
}

# ---------------------------- 系统维护函数 ----------------------------

# 清理旧内核
remove_all_old_kernels() {
    echo -e "${BLUE}扫描内核包...${RESET}"
    
    local current_kernel=$(uname -r)
    local all_kernel_pkgs=()
    
    # 获取所有内核包
    while IFS= read -r pkg; do
        all_kernel_pkgs+=("$pkg")
    done < <(dpkg -l | awk '/^ii/ && ($2 ~ /^linux-(image|headers|modules)-/){print $2}')
    
    if [[ ${#all_kernel_pkgs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未发现内核包${RESET}"
        return
    fi
    
    # 筛选旧内核
    local to_remove=()
    for pkg in "${all_kernel_pkgs[@]}"; do
        if [[ "$pkg" != *"$current_kernel"* ]]; then
            to_remove+=("$pkg")
        fi
    done
    
    if [[ ${#to_remove[@]} -eq 0 ]]; then
        echo -e "${GREEN}✓ 无旧内核需要清理${RESET}"
        return
    fi
    
    # 确认删除
    echo -e "${RED}即将删除以下内核包：${RESET}"
    printf '  - %s\n' "${to_remove[@]}"
    echo -n -e "${BLUE}确定删除？(y/N): ${RESET}"
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}已取消删除操作${RESET}"
        return
    fi
    
    # 执行删除
    if sudo apt-get remove --purge -y "${to_remove[@]}"; then
        sudo apt-get autoremove -y || echo -e "${YELLOW}警告：自动清理失败${RESET}"
        update_bootloader
        echo -e "${GREEN}✓ 清理完成${RESET}"
    else
        echo -e "${RED}错误：删除失败${RESET}"
    fi
}

# ---------------------------- 交互式配置函数 ----------------------------

# 交互式网络算法选择
custom_select_algorithm() {
    echo -e "${BLUE}检测可用算法...${RESET}"
    
    # TCP 算法选择
    select_tcp_algorithm
    echo
    
    # 队列算法选择
    select_qdisc_algorithm
    echo
    
    # 保存配置
    ask_to_save
}

# 选择 TCP 拥塞控制算法
select_tcp_algorithm() {
    local tcp_avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    
    if [[ -z "$tcp_avail" ]]; then
        echo -e "${YELLOW}无法获取可用 TCP 算法列表${RESET}"
        echo -n -e "${BLUE}请输入 TCP 算法名称: ${RESET}"
        read -r ALGO
    else
        read -ra tcp_array <<< "$tcp_avail"
        echo -e "${GREEN}可用 TCP 拥塞控制算法：${RESET}"
        
        for i in "${!tcp_array[@]}"; do
            echo -e "  $((i+1)). ${tcp_array[$i]}"
        done
        
        echo -n -e "${BLUE}请选择（输入编号或算法名称）: ${RESET}"
        read -r tcp_choice
        
        if [[ "$tcp_choice" =~ ^[0-9]+$ ]] && \
           (( tcp_choice >= 1 && tcp_choice <= ${#tcp_array[@]} )); then
            ALGO="${tcp_array[$((tcp_choice-1))]}"
        else
            ALGO="$tcp_choice"
        fi
    fi
}

# 选择队列算法
select_qdisc_algorithm() {
    echo -e "${YELLOW}常见队列算法：fq, fq_pie, cake, fq_codel, pfifo_fast${RESET}"
    echo -n -e "${BLUE}请输入队列算法名称: ${RESET}"
    read -r QDISC
}

# ---------------------------- 主程序入口 ----------------------------

# 初始化
initialize() {
    check_system_compatibility
    install_dependencies
    detect_architecture
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${PURPLE}        Linux 内核与 BBRv3 管理脚本${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    
    local current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    local kernel_type=$(check_current_kernel_type)
    
    echo -e "  当前内核：${GREEN}$(uname -r)${RESET} [$kernel_type]"
    echo -e "  系统架构：${GREEN}$ARCH${RESET} (Debian: ${GREEN}$DEB_ARCH${RESET})"
    echo -e "  TCP 算法：${GREEN}$current_algo${RESET}"
    echo -e "  队列算法：${GREEN}$current_qdisc${RESET}"
    echo -e "  仓库来源：${YELLOW}$GITHUB_REPO${RESET}"
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo -e "  ${YELLOW}1.${RESET} 安装最新 BBRv3 内核"
    echo -e "  ${YELLOW}2.${RESET} 安装最新原版内核"
    echo -e "  ${YELLOW}3.${RESET} 选择指定版本安装"
    echo -e "  ${YELLOW}4.${RESET} 启用 BBR + FQ"
    echo -e "  ${YELLOW}5.${RESET} 启用 BBR + FQ_PIE"
    echo -e "  ${YELLOW}6.${RESET} 启用 BBR + CAKE"
    echo -e "  ${YELLOW}7.${RESET} 自定义设置 TCP + 队列算法"
    echo -e "  ${YELLOW}8.${RESET} 删除所有旧内核"
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# 处理用户选择
handle_user_choice() {
    echo -n -e "${BLUE}请选择操作 (1-8): ${RESET}"
    read -r ACTION
    
    echo
    
    case "$ACTION" in
        1)
            fetch_and_install "latest_bbrv3"
            ;;
        2)
            fetch_and_install "latest_vanilla"
            ;;
        3)
            fetch_and_install "list_all"
            ;;
        4)
            ALGO="bbr"
            QDISC="fq"
            ask_to_save
            ;;
        5)
            ALGO="bbr"
            QDISC="fq_pie"
            ask_to_save
            ;;
        6)
            ALGO="bbr"
            QDISC="cake"
            ask_to_save
            ;;
        7)
            custom_select_algorithm
            ;;
        8)
            remove_all_old_kernels
            ;;
        *)
            echo -e "${RED}错误：无效选项${RESET}"
            return 1
            ;;
    esac
}

# 主函数
main() {
    initialize
    show_main_menu
    handle_user_choice
}

# 执行主程序
main
