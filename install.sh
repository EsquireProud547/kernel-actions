#!/bin/bash

# =============================================================================
# 脚本名称：Linux 内核自动化安装与管理工具
# 版本：v2.0
# 适配工作流：Linux 内核自动化构建系统 (x86_64)
# 
# 功能概述：
#   - 从 GitHub Releases 自动获取工作流编译的内核
#   - 支持分支筛选：Mainline / Stable / LTS (6.12/6.6/6.1/5.15/5.10)
#   - 支持编译器筛选：GCC-14 / LLVM (最新稳定版)
#   - 自动架构检测 (AMD64/ARM64) 与完整性校验
#   - 系统网络优化配置（TCP 拥塞控制与队列算法）
#   - 旧内核自动清理与引导管理
#
# 支持平台：
#   - Debian 12+ / Ubuntu 22.04+ 及其衍生发行版
#   - 架构：x86_64 (amd64), ARM64 (aarch64/arm64)
#
# 依赖工具：curl, wget, jq, dpkg, apt, sysctl, modprobe, sha256sum
# 工作流仓库：EsquireProud547/kernel-actions (可配置)
# =============================================================================

# 严格模式设置
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# 全局配置区
# =============================================================================

# GitHub 仓库配置（格式：用户名/仓库名）
declare -r GITHUB_REPO="${GITHUB_REPO:-EsquireProud547/kernel-actions}"
declare -r GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases"

# 系统配置路径
declare -r SYSCTL_CONF="/etc/sysctl.d/99-kernel-autotune.conf"
declare -r MODULES_CONF="/etc/modules-load.d/custom-qdisc.conf"

# 临时工作目录（脚本退出时自动清理）
declare -r TEMP_DIR="/tmp/kernel-deploy-$$"
trap 'cleanup_temp' EXIT INT TERM HUP

# 调试模式（设置 DEBUG=1 启用详细输出）
[[ "${DEBUG:-0}" == "1" ]] && set -x

# 全局状态变量
declare ARCH=""           # 系统架构 (x86_64/aarch64)
declare DEB_ARCH=""       # Debian 架构 (amd64/arm64)
declare SELECTED_TAG=""   # 用户选择的版本标签

# =============================================================================
# 输出与日志工具函数
# =============================================================================

# ANSI 颜色定义
declare -r C_GREEN='\033[1;32m'
declare -r C_YELLOW='\033[33m'
declare -r C_BLUE='\033[36m'
declare -r C_PURPLE='\033[1;35m'
declare -r C_RED='\033[31m'
declare -r C_CYAN='\033[1;34m'
declare -r C_GRAY='\033[37m'
declare -r C_RESET='\033[0m'

# 分级日志输出
log_info()    { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()      { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_error()   { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }
log_debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${C_CYAN}[DBG]${C_RESET} $*" >&2; }

# 格式化输出辅助
print_header() { echo -e "\n${C_PURPLE}▶ $*${C_RESET}"; }
print_sep()    { echo -e "${C_GRAY}────────────────────────────────────────────────${C_RESET}"; }
print_success() {
    echo -e "${C_GREEN}✓${C_RESET} $1"
    [[ -n "${2:-}" ]] && echo -e "  ${C_GRAY}$2${C_RESET}"
}

# =============================================================================
# 系统初始化和检查
# =============================================================================

# 清理临时资源（trap 调用）
cleanup_temp() {
    if [[ -d "${TEMP_DIR:-}" ]]; then
        rm -rf "${TEMP_DIR}"
        log_debug "已清理临时目录: ${TEMP_DIR}"
    fi
}

# 系统兼容性检查
check_system() {
    log_info "检查系统兼容性..."
    
    # 检查包管理系统（仅支持 apt）
    if ! command -v apt-get &>/dev/null; then
        log_error "此脚本仅支持 Debian/Ubuntu 系发行版（需要 apt-get）"
        exit 1
    fi
    
    # 检查 systemd 路径（用于 sysctl）
    if [[ ! -d /etc/sysctl.d ]]; then
        log_warn "未找到 /etc/sysctl.d，将回退到 /etc/sysctl.conf"
    fi
    
    # 检查 root 权限（部分操作需要）
    if [[ $EUID -ne 0 ]]; then
        log_warn "脚本未以 root 运行，将在需要时自动调用 sudo"
    fi
    
    log_ok "系统检查通过"
}

# 架构检测与映射
detect_arch() {
    log_info "检测系统架构..."
    
    local machine
    machine=$(uname -m)
    
    case "$machine" in
        x86_64|amd64)
            ARCH="x86_64"
            DEB_ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="aarch64"
            DEB_ARCH="arm64"
            ;;
        *)
            log_error "不支持的架构: $machine"
            log_error "工作流仅支持 x86_64 (amd64) 和 ARM64 (aarch64)"
            exit 1
            ;;
    esac
    
    log_ok "检测到架构: ${ARCH} (Debian: ${DEB_ARCH})"
}

# 依赖安装
install_deps() {
    log_info "检查依赖项..."
    
    local -a deps=("curl" "wget" "jq" "dpkg" "apt-get" "sysctl" "modprobe" "sha256sum")
    local -a missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            case "$cmd" in
                modprobe) missing+=("kmod") ;;
                sysctl)   missing+=("procps") ;;
                sha256sum) missing+=("coreutils") ;;
                dpkg|apt-get) ;; # 系统核心，无法自动安装
                *)        missing+=("$cmd") ;;
            esac
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "需要安装依赖: ${missing[*]}"
        log_info "更新软件源..."
        
        if ! sudo apt-get update -qq; then
            log_error "apt-get update 失败，请检查网络"
            exit 1
        fi
        
        if ! sudo apt-get install -y --no-install-recommends "${missing[@]}" 2>/dev/null; then
            log_error "依赖安装失败，请手动安装: ${missing[*]}"
            exit 1
        fi
    fi
    
    log_ok "依赖检查完成"
}

# 初始化入口
initialize() {
    check_system
    install_deps
    detect_arch
    
    # 创建临时目录
    mkdir -p "$TEMP_DIR"
}

# =============================================================================
# 内核状态检测
# =============================================================================

# 获取当前内核信息
get_current_kernel() {
    uname -r
}

# 判断内核类型（基于工作流命名规则）
# 工作流 LOCALVERSION: -${CACHE_KEY_COMPILER}-${RAND_SUFFIX}
get_kernel_type() {
    local ver
    ver=$(get_current_kernel)
    
    if [[ "$ver" =~ -gcc- ]]; then
        echo -e "${C_GREEN}GCC 构建${C_RESET}"
    elif [[ "$ver" =~ -llvm- ]]; then
        echo -e "${C_CYAN}LLVM 构建${C_RESET}"
    else
        echo -e "${C_GRAY}发行版默认${C_RESET}"
    fi
}

# 获取当前网络配置
get_net_config() {
    local algo
    local qdisc
    
    algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    
    echo "${algo}|${qdisc}"
}

# =============================================================================
# GitHub API 交互（核心）
# =============================================================================

# 获取 Releases 数据（带重试和错误处理）
api_fetch_releases() {
    local url="$1"
    local retries=3
    local delay=5
    
    for ((i=1; i<=retries; i++)); do
        log_debug "API 请求尝试 $i/$retries: $url"
        
        local response
        local http_code
        
        response=$(curl -sL -w "\n%{http_code}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            --connect-timeout 10 \
            --max-time 30 \
            "$url" 2>/dev/null || echo -e "\n000")
        
        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
        
        case "$http_code" in
            200)
                echo "$body"
                return 0
                ;;
            403)
                log_error "GitHub API 速率限制已达上限 (HTTP 403)"
                log_info "提示：未认证请求限制 60次/小时，建议稍后再试"
                return 1
                ;;
            404)
                log_error "仓库不存在或无法访问: $GITHUB_REPO (HTTP 404)"
                return 1
                ;;
            000)
                log_warn "网络连接失败，检查网络或代理设置"
                ;;
            *)
                log_warn "HTTP 错误: $http_code"
                ;;
        esac
        
        if [[ $i -lt $retries ]]; then
            log_info "等待 ${delay} 秒后重试..."
            sleep $delay
            delay=$((delay + 5))
        fi
    done
    
    log_error "无法连接到 GitHub API"
    return 1
}

# 解析 Release JSON（安全校验）
parse_releases() {
    local json="$1"
    
    # 检查 API 错误消息
    if echo "$json" | jq -e 'type == "object" and has("message")' &>/dev/null; then
        log_error "API 错误: $(echo "$json" | jq -r '.message')"
        return 1
    fi
    
    # 检查数组长度
    local count
    count=$(echo "$json" | jq 'length')
    
    if [[ "$count" == "0" ]]; then
        log_error "该仓库没有可用的 Release"
        return 1
    fi
    
    # 验证数据完整性
    if ! echo "$json" | jq -e '.[0].tag_name' &>/dev/null; then
        log_error "Release 数据格式异常（缺少 tag_name）"
        return 1
    fi
    
    echo "$json"
}

# =============================================================================
# 版本筛选逻辑（适配工作流分支与编译器）
# =============================================================================

# 从 Release 名称解析元数据
# 工作流 Release 名称: Linux 6.12.8 [stable] (amd64)
# Tag 格式: v6.12.8-gcc-14-a1b2c3d4 或 v6.12.8-llvm-22-a1b2c3d4
parse_release_meta() {
    local tag="$1"
    local name="$2"
    
    # 提取版本号（从 tag，更可靠）
    local kernel_ver
    kernel_ver=$(echo "$tag" | sed -E 's/^v//; s/-(gcc|llvm)-.*//')
    
    # 提取编译器类型和版本
    local compiler="unknown"
    local compiler_ver=""
    
    if [[ "$tag" =~ -gcc-([0-9]+)- ]]; then
        compiler="GCC"
        compiler_ver="${BASH_REMATCH[1]}"
    elif [[ "$tag" =~ -llvm-([0-9]+)- ]]; then
        compiler="LLVM"
        compiler_ver="${BASH_REMATCH[1]}"
    fi
    
    # 提取分支（从 Release 名称）
    local branch="unknown"
    if [[ "$name" =~ \[([a-z0-9\.\-]+)\] ]]; then
        branch="${BASH_REMATCH[1]}"
    fi
    
    echo "${kernel_ver}|${compiler}|${compiler_ver}|${branch}"
}

# 筛选函数：按分支
filter_by_branch() {
    local json="$1"
    local branch="$2"  # mainline/stable/longterm-6.12等
    
    if [[ "$branch" == "all" ]]; then
        echo "$json"
        return
    fi
    
    # 分支匹配逻辑
    # Release 名称格式: Linux 6.12.8 [stable] (amd64)
    echo "$json" | jq -r --arg branch "$branch" '
        [.[] | select(.name | contains("[" + $branch + "]"))]
    '
}

# 筛选函数：按编译器类型
filter_by_compiler() {
    local json="$1"
    local comp="$2"  # gcc/llvm/all
    
    if [[ "$comp" == "all" ]]; then
        echo "$json"
        return
    fi
    
    echo "$json" | jq -r --arg comp "$comp" '
        [.[] | select(.tag_name | contains("-" + $comp + "-"))]
    '
}

# 获取最新的匹配版本
get_latest_matching() {
    local json="$1"
    local arch="$2"
    
    # 选择包含指定架构 deb 包的最新 Release
    echo "$json" | jq -r --arg arch "$arch" '
        [.[] | select(.assets[] | 
            .name | contains($arch) and endswith(".deb")
        )] | 
        first |
        .tag_name
    '
}

# =============================================================================
# 交互式安装流程
# =============================================================================

# 显示版本选择菜单
select_version_menu() {
    local json="$1"
    
    print_header "可用内核版本（架构: $DEB_ARCH）"
    print_sep
    
    # 解析并准备数据
    local -a releases_data=()
    local idx=1
    
    # 限制显示数量（最新的15个）
    local filtered
    filtered=$(echo "$json" | jq --arg arch "$DEB_ARCH" '
        [.[] | select(.assets[] | .name | contains($arch) and endswith(".deb"))]
        | sort_by(.published_at) | reverse | .[:15]
    ')
    
    # 遍历生成菜单
    while IFS= read -r item; do
        local tag name published meta kernel compiler comp_ver branch
        
        tag=$(echo "$item" | jq -r '.tag_name')
        name=$(echo "$item" | jq -r '.name')
        published=$(echo "$item" | jq -r '.published_at')
        
        # 解析元数据
        meta=$(parse_release_meta "$tag" "$name")
        kernel=$(echo "$meta" | cut -d'|' -f1)
        compiler=$(echo "$meta" | cut -d'|' -f2)
        comp_ver=$(echo "$meta" | cut -d'|' -f3)
        branch=$(echo "$meta" | cut -d'|' -f4)
        
        # 格式化日期
        local date_str
        date_str=$(date -d "$published" '+%Y-%m-%d' 2>/dev/null || echo "$published")
        
        # 显示格式
        local comp_icon="🔧"
        [[ "$compiler" == "LLVM" ]] && comp_icon="⚡"
        
        printf "  %s %2d. ${C_YELLOW}%-12s${C_RESET} %-8s %s %s\n" \
            "$comp_icon" "$idx" "$kernel" "[$branch]" "$compiler $comp_ver" "($date_str)"
        
        releases_data+=("$tag")
        ((idx++))
    done < <(echo "$filtered" | jq -c '.[]')
    
    if [[ ${#releases_data[@]} -eq 0 ]]; then
        log_error "未找到适用于 $DEB_ARCH 的版本"
        return 1
    fi
    
    print_sep
    echo ""
    
    # 用户输入
    local choice
    while true; do
        echo -n -e "${C_BLUE}请输入编号 (1-${#releases_data[@]}): ${C_RESET}"
        read -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#releases_data[@]} )); then
            SELECTED_TAG="${releases_data[$((choice-1))]}"
            return 0
        else
            log_warn "无效输入，请输入 1-${#releases_data[@]} 的数字"
        fi
    done
}

# 快速安装（最新 Stable）
install_latest_stable() {
    log_info "获取最新 Stable 版本..."
    
    local releases_json
    if ! releases_json=$(fetch_and_parse); then
        return 1
    fi
    
    # 筛选 Stable 分支
    local stable_releases
    stable_releases=$(filter_by_branch "$releases_json" "stable")
    
    local tag
    tag=$(get_latest_matching "$stable_releases" "$DEB_ARCH")
    
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        log_error "未找到可用的 Stable 版本"
        return 1
    fi
    
    log_ok "找到最新 Stable: $tag"
    download_and_install "$releases_json" "$tag"
}

# 快速安装（最新 Mainline）
install_latest_mainline() {
    log_info "获取最新 Mainline 版本..."
    
    local releases_json
    if ! releases_json=$(fetch_and_parse); then
        return 1
    fi
    
    local mainline
    mainline=$(filter_by_branch "$releases_json" "mainline")
    
    local tag
    tag=$(get_latest_matching "$mainline" "$DEB_ARCH")
    
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        log_error "未找到可用的 Mainline 版本"
        return 1
    fi
    
    log_ok "找到最新 Mainline: $tag"
    download_and_install "$releases_json" "$tag"
}

# 按分支和编译器筛选安装
install_filtered() {
    local branch="$1"
    local compiler="$2"  # gcc/llvm/all
    
    log_info "筛选条件: 分支=${branch}, 编译器=${compiler}"
    
    local releases_json
    if ! releases_json=$(fetch_and_parse); then
        return 1
    fi
    
    # 依次筛选
    local filtered
    filtered=$(filter_by_branch "$releases_json" "$branch")
    filtered=$(filter_by_compiler "$filtered" "$compiler")
    
    # 交互选择
    if ! select_version_menu "$filtered"; then
        return 1
    fi
    
    download_and_install "$releases_json" "$SELECTED_TAG"
}

# =============================================================================
# 下载与安装执行
# =============================================================================

# 下载资源（支持元数据文件）
download_assets() {
    local json="$1"
    local tag="$2"
    local arch="$3"
    
    log_info "准备下载: $tag"
    log_debug "目标架构: $arch"
    
    # 清理并创建目录
    rm -rf "${TEMP_DIR:?}/"*
    mkdir -p "$TEMP_DIR"
    
    # 提取当前 Release 的资产列表
    local assets
    assets=$(echo "$json" | jq -r --arg tag "$tag" --arg arch "$arch" '
        .[] | select(.tag_name == $tag) | .assets[] |
        select(.name | contains($arch) or .name == "checksums.txt" or .name == "build-metadata.txt") |
        "\(.name)|\(.browser_download_url)"
    ')
    
    if [[ -z "$assets" ]]; then
        log_error "未找到 $tag 的下载资源"
        return 1
    fi
    
    # 分类下载
    local -a deb_urls=()
    local checksum_url=""
    local metadata_url=""
    
    while IFS='|' read -r name url; do
        log_debug "发现资源: $name"
        if [[ "$name" == *.deb ]]; then
            deb_urls+=("$url")
        elif [[ "$name" == "checksums.txt" ]]; then
            checksum_url="$url"
        elif [[ "$name" == "build-metadata.txt" ]]; then
            metadata_url="$url"
        fi
    done <<< "$assets"
    
    if [[ ${#deb_urls[@]} -eq 0 ]]; then
        log_error "未找到适用于 $arch 的 .deb 包"
        return 1
    fi
    
    # 下载元数据（优先，用于信息展示）
    if [[ -n "$metadata_url" ]]; then
        log_info "获取构建元数据..."
        if wget -q --show-progress "$metadata_url" -O "${TEMP_DIR}/build-metadata.txt"; then
            log_ok "元数据已下载"
            # 显示构建信息给用户
            if [[ -f "${TEMP_DIR}/build-metadata.txt" ]]; then
                echo -e "${C_GRAY}"
                grep -E "KERNEL_VERSION|COMPILER|BRANCH" "${TEMP_DIR}/build-metadata.txt" | sed 's/^/  /'
                echo -e "${C_RESET}"
            fi
        fi
    fi
    
    # 下载校验文件
    if [[ -n "$checksum_url" ]]; then
        log_info "下载校验文件..."
        wget -q --show-progress "$checksum_url" -O "${TEMP_DIR}/checksums.txt" || \
            log_warn "校验文件下载失败"
    fi
    
    # 并行下载 deb 包
    log_info "下载内核软件包 (${#deb_urls[@]} 个文件)..."
    local failed=0
    
    for url in "${deb_urls[@]}"; do
        local filename
        filename=$(basename "$url")
        if ! wget -q --show-progress "$url" -O "${TEMP_DIR}/${filename}"; then
            log_error "下载失败: $filename"
            ((failed++))
        fi
    done
    
    [[ $failed -gt 0 ]] && return 1
    log_ok "所有文件下载完成"
    return 0
}

# 校验文件完整性
verify_checksums() {
    cd "$TEMP_DIR" || return 1
    
    if [[ ! -f "checksums.txt" ]]; then
        log_warn "未找到 checksums.txt，跳过完整性校验"
        return 0
    fi
    
    log_info "校验文件完整性..."
    
    # 使用 --ignore-missing 因为我们只下载了特定架构的包
    if sha256sum -c checksums.txt --ignore-missing --quiet 2>/dev/null; then
        log_ok "SHA256 校验通过"
        return 0
    else
        log_error "文件校验失败！文件可能损坏或被篡改"
        return 1
    fi
}

# 执行安装
do_install() {
    cd "$TEMP_DIR" || return 1
    
    # 检查包
    local deb_count
    deb_count=$(ls -1 *.deb 2>/dev/null | wc -l)
    
    if [[ "$deb_count" -eq 0 ]]; then
        log_error "安装目录中没有 .deb 包"
        return 1
    fi
    
    log_info "发现 $deb_count 个软件包:"
    ls -lh *.deb | awk '{printf "  - %s (%s)\n", $9, $5}'
    
    # 安装前冲突检查
    log_info "检查包冲突..."
    if ! sudo dpkg --dry-run -i *.deb 2>&1 | grep -q "error"; then
        log_ok "依赖检查通过"
    fi
    
    # 执行安装
    echo ""
    log_info "正在安装内核（可能需要几分钟）..."
    
    if sudo apt install -y ./*.deb; then
        log_ok "内核安装成功"
        update_bootloader
        return 0
    else
        log_error "安装失败，尝试修复依赖..."
        sudo apt-get install -f -y || true
        return 1
    fi
}

# 更新引导
update_bootloader() {
    log_info "更新系统引导..."
    
    if command -v update-grub &>/dev/null; then
        sudo update-grub && log_ok "GRUB 已更新"
    elif command -v grub2-mkconfig &>/dev/null; then
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || \
        sudo grub2-mkconfig -o /boot/grub/grub.cfg 2>/dev/null && \
        log_ok "GRUB2 已更新"
    else
        log_warn "未找到 GRUB 工具，ARM 系统通常无需手动更新"
    fi
}

# 提示重启
prompt_reboot() {
    echo ""
    local current new_kernel
    current=$(get_current_kernel)
    
    # 从安装包名推断新内核版本（粗略）
    new_kernel=$(ls linux-image-*.deb 2>/dev/null | head -1 | sed -E 's/linux-image-//; s/-[0-9]+.deb//; s/_/ /')
    
    print_sep
    log_info "当前运行内核: ${C_YELLOW}$current${C_RESET}"
    [[ -n "$new_kernel" ]] && log_info "新安装内核: ${C_GREEN}$new_kernel${C_RESET}"
    print_sep
    
    echo -n -e "${C_YELLOW}是否立即重启以应用新内核？(y/N): ${C_RESET}"
    read -r confirm
    
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        log_info "系统将在 3 秒后重启..."
        sleep 3
        sudo reboot
    else
        log_warn "请稍后手动重启系统"
        log_info "重启后执行 'uname -r' 确认新内核"
    fi
}

# 下载安装总控
download_and_install() {
    local json="$1"
    local tag="$2"
    
    if download_assets "$json" "$tag" "$DEB_ARCH"; then
        verify_checksums || { log_error "文件校验失败，中止安装"; return 1; }
        if do_install; then
            prompt_reboot
        fi
    else
        log_error "下载失败，请检查网络或版本标签"
        return 1
    fi
}

# 辅助：获取并解析 Releases
fetch_and_parse() {
    local json
    if ! json=$(api_fetch_releases "$GITHUB_API_URL"); then
        return 1
    fi
    parse_releases "$json"
}

# =============================================================================
# 系统维护功能
# =============================================================================

# 清理旧内核（保留当前运行版本）
cleanup_old_kernels() {
    log_info "扫描已安装的内核..."
    
    local current
    current=$(get_current_kernel)
    
    # 获取所有内核相关包
    local -a all_pkgs=()
    while IFS= read -r pkg; do
        all_pkgs+=("$pkg")
    done < <(dpkg -l | awk '/^ii/ && ($2 ~ /^linux-(image|headers|modules)-/){print $2}')
    
    # 筛选旧内核
    local -a old_pkgs=()
    for pkg in "${all_pkgs[@]}"; do
        # 排除当前内核（精确匹配）
        if [[ ! "$pkg" =~ $current ]]; then
            old_pkgs+=("$pkg")
        fi
    done
    
    if [[ ${#old_pkgs[@]} -eq 0 ]]; then
        log_ok "未发现旧内核，系统已是最干净状态"
        return 0
    fi
    
    log_warn "发现 ${#old_pkgs[@]} 个旧内核包:"
    printf '  - %s\n' "${old_pkgs[@]}"
    echo ""
    
    echo -n -e "${C_RED}确定删除以上所有旧内核？(y/N): ${C_RESET}"
    read -r confirm
    
    [[ ! "$confirm" =~ ^[yY]$ ]] && { log_info "已取消删除"; return 0; }
    
    log_info "正在删除旧内核..."
    if sudo apt-get remove --purge -y "${old_pkgs[@]}"; then
        sudo apt-get autoremove -y || true
        update_bootloader
        log_ok "旧内核清理完成"
    else
        log_error "删除过程中出现错误"
        return 1
    fi
}

# =============================================================================
# 网络优化配置（保留功能，独立于内核类型）
# =============================================================================

# 清理旧的 sysctl 配置（保留文件但删除我们的配置行）
clean_net_config() {
    if [[ -f "$SYSCTL_CONF" ]]; then
        # 备份
        sudo cp "$SYSCTL_CONF" "${SYSCTL_CONF}.bak.$(date +%s)" 2>/dev/null || true
        # 删除我们的配置行
        sudo sed -i '/^net\.core\.default_qdisc/d' "$SYSCTL_CONF"
        sudo sed -i '/^net\.ipv4\.tcp_congestion_control/d' "$SYSCTL_CONF"
    fi
}

# 保存网络配置
save_net_config() {
    local qdisc="$1"
    local algo="$2"
    
    clean_net_config
    
    # 创建新配置
    {
        echo "# 内核网络优化配置（由 kernel-deploy 脚本生成）"
        echo "# 时间: $(date -R)"
        echo "net.core.default_qdisc=$qdisc"
        echo "net.ipv4.tcp_congestion_control=$algo"
    } | sudo tee "$SYSCTL_CONF" > /dev/null
    
    # 应用
    sudo sysctl --system &>/dev/null || sudo sysctl -p "$SYSCTL_CONF" &>/dev/null || true
    
    # 处理模块（非内置算法）
    if [[ "$qdisc" != "fq" && "$qdisc" != "fq_codel" && "$qdisc" != "pfifo_fast" ]]; then
        echo "sch_$qdisc" | sudo tee "$MODULES_CONF" > /dev/null
        sudo modprobe "sch_$qdisc" 2>/dev/null || true
    else
        sudo rm -f "$MODULES_CONF"
    fi
    
    log_ok "网络配置已保存: $qdisc + $algo"
}

# 测试配置是否可用
test_net_config() {
    local qdisc="$1"
    local algo="$2"
    local current_qdisc current_algo
    
    current_qdisc=$(sysctl -n net.core.default_qdisc)
    current_algo=$(sysctl -n net.ipv4.tcp_congestion_control)
    
    # 尝试应用
    sudo sysctl -w "net.core.default_qdisc=$qdisc" &>/dev/null || return 1
    sudo sysctl -w "net.ipv4.tcp_congestion_control=$algo" &>/dev/null || return 1
    
    sleep 0.5
    
    # 验证
    local new_qdisc new_algo
    new_qdisc=$(sysctl -n net.core.default_qdisc)
    new_algo=$(sysctl -n net.ipv4.tcp_congestion_control)
    
    if [[ "$new_qdisc" == "$qdisc" && "$new_algo" == "$algo" ]]; then
        # 恢复（因为只是测试）
        sudo sysctl -w "net.core.default_qdisc=$current_qdisc" &>/dev/null || true
        sudo sysctl -w "net.ipv4.tcp_congestion_control=$current_algo" &>/dev/null || true
        return 0
    fi
    
    return 1
}

# 交互式网络配置
configure_network() {
    print_header "TCP/IP 网络优化配置"
    
    local current
    current=$(get_net_config)
    local current_algo="${current%%|*}"
    local current_qdisc="${current##*|}"
    
    log_info "当前配置: $current_qdisc + $current_algo"
    
    # 选择 TCP 算法
    local avail_algo
    avail_algo=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "cubic reno")
    
    echo ""
    echo -e "${C_BLUE}可用 TCP 拥塞控制算法:${C_RESET}"
    read -ra algos <<< "$avail_algo"
    
    for i in "${!algos[@]}"; do
        local marker=" "
        [[ "${algos[$i]}" == "$current_algo" ]] && marker="*"
        [[ "${algos[$i]}" == "bbr" ]] && marker="⭑"
        printf "  %s %d. %s\n" "$marker" "$((i+1))" "${algos[$i]}"
    done
    
    echo ""
    echo -n -e "${C_BLUE}选择算法（输入编号或名称，直接回车保持当前）: ${C_RESET}"
    read -r algo_choice
    
    local target_algo="$current_algo"
    if [[ -n "$algo_choice" ]]; then
        if [[ "$algo_choice" =~ ^[0-9]+$ ]] && (( algo_choice >= 1 && algo_choice <= ${#algos[@]} )); then
            target_algo="${algos[$((algo_choice-1))]}"
        else
            target_algo="$algo_choice"
        fi
    fi
    
    # 选择队列算法
    echo ""
    echo -e "${C_BLUE}常见队列算法:${C_RESET}"
    echo -e "  1. fq        (Fair Queue)"
    echo -e "  2. fq_pie    (PIE AQM)"
    echo -e "  3. cake      (通用自适应队列)"
    echo -e "  4. fq_codel  (默认推荐)"
    echo -e "  5. 其他（手动输入）"
    echo ""
    echo -n -e "${C_BLUE}选择队列算法（1-5，直接回车保持 $current_qdisc）: ${C_RESET}"
    read -r qdisc_choice
    
    local target_qdisc="$current_qdisc"
    case "$qdisc_choice" in
        1) target_qdisc="fq" ;;
        2) target_qdisc="fq_pie" ;;
        3) target_qdisc="cake" ;;
        4) target_qdisc="fq_codel" ;;
        5) 
            echo -n -e "${C_BLUE}输入算法名称: ${C_RESET}"
            read -r target_qdisc
            ;;
    esac
    
    # 应用
    echo ""
    log_info "测试配置: $target_qdisc + $target_algo..."
    
    if test_net_config "$target_qdisc" "$target_algo"; then
        log_ok "配置测试成功"
        echo -n -e "${C_BLUE}是否永久保存到 $SYSCTL_CONF？(y/N): ${C_RESET}"
        read -r save
        
        if [[ "$save" =~ ^[yY]$ ]]; then
            save_net_config "$target_qdisc" "$target_algo"
        else
            log_info "配置未保存，重启后失效"
        fi
    else
        log_error "配置测试失败！内核可能不支持该组合"
    fi
}

# =============================================================================
# UI 界面
# =============================================================================

show_banner() {
    clear
    print_sep
    echo -e "${C_PURPLE}  Linux 内核自动化安装工具 v2.0${C_RESET}"
    echo -e "${C_GRAY}  适配工作流: ${GITHUB_REPO}${C_RESET}"
    print_sep
    echo ""
    
    local kernel
    local ktype
    local net
    kernel=$(get_current_kernel)
    ktype=$(get_kernel_type)
    net=$(get_net_config)
    
    echo -e "  ${C_BLUE}运行内核:${C_RESET} ${kernel} [$ktype]"
    echo -e "  ${C_BLUE}系统架构:${C_RESET} ${ARCH} (${DEB_ARCH})"
    echo -e "  ${C_BLUE}网络配置:${C_RESET} ${net##*|} + ${net%%|*}"
    echo ""
    print_sep
    echo ""
}

show_menu() {
    show_banner
    
    echo -e "  ${C_YELLOW}1.${C_RESET} 安装最新 ${C_GREEN}Stable${C_RESET} 内核 (推荐)"
    echo -e "  ${C_YELLOW}2.${C_RESET} 安装最新 ${C_CYAN}Mainline${C_RESET} 内核 (主线开发版)"
    echo -e "  ${C_YELLOW}3.${C_RESET} 安装最新 ${C_PURPLE}LTS${C_RESET} 内核 (长期支持)"
    echo -e "  ${C_YELLOW}4.${C_RESET} 高级筛选（分支 + 编译器）"
    echo -e "  ${C_YELLOW}5.${C_RESET} 列出所有可用版本并选择"
    echo ""
    echo -e "  ${C_GRAY}6.${C_RESET} 网络优化配置（TCP算法/队列）"
    echo -e "  ${C_GRAY}7.${C_RESET} 清理旧内核"
    echo -e "  ${C_GRAY}8.${C_RESET} 退出"
    echo ""
    print_sep
}

# 高级筛选菜单
advanced_install_menu() {
    print_header "高级筛选安装"
    
    echo ""
    echo -e "${C_BLUE}选择内核分支:${C_RESET}"
    echo -e "  1. stable        (稳定版)"
    echo -e "  2. mainline      (主线版)"
    echo -e "  3. longterm-6.12 (LTS 6.12)"
    echo -e "  4. longterm-6.6  (LTS 6.6)"
    echo -e "  5. longterm-6.1  (LTS 6.1)"
    echo -e "  6. 其他（输入）"
    echo ""
    echo -n -e "${C_BLUE}选择 (1-6): ${C_RESET}"
    read -r branch_choice
    
    local branch=""
    case "$branch_choice" in
        1) branch="stable" ;;
        2) branch="mainline" ;;
        3) branch="longterm-6.12" ;;
        4) branch="longterm-6.6" ;;
        5) branch="longterm-6.1" ;;
        6) 
            echo -n -e "${C_BLUE}输入分支名称: ${C_RESET}"
            read -r branch
            ;;
        *) 
            log_warn "无效选择，使用 stable"
            branch="stable"
            ;;
    esac
    
    echo ""
    echo -e "${C_BLUE}选择编译器类型:${C_RESET}"
    echo -e "  1. GCC-14  (稳定兼容)"
    echo -e "  2. LLVM    (最新优化)"
    echo -e "  3. 不限制"
    echo ""
    echo -n -e "${C_BLUE}选择 (1-3): ${C_RESET}"
    read -r comp_choice
    
    local compiler="all"
    case "$comp_choice" in
        1) compiler="gcc" ;;
        2) compiler="llvm" ;;
        3) compiler="all" ;;
    esac
    
    install_filtered "$branch" "$compiler"
}

# 主处理逻辑
main_loop() {
    while true; do
        show_menu
        
        echo -n -e "${C_BLUE}请选择操作 (1-8): ${C_RESET}"
        read -r choice
        
        case "$choice" in
            1)
                install_latest_stable
                ;;
            2)
                install_latest_mainline
                ;;
            3)
                install_filtered "longterm" "all"
                ;;
            4)
                advanced_install_menu
                ;;
            5)
                local json
                json=$(fetch_and_parse) && select_version_menu "$json" && \
                    download_and_install "$json" "$SELECTED_TAG"
                ;;
            6)
                configure_network
                ;;
            7)
                cleanup_old_kernels
                ;;
            8)
                log_info "退出"
                exit 0
                ;;
            *)
                log_warn "无效选项: $choice"
                ;;
        esac
        
        echo ""
        echo -n -e "${C_GRAY}按 Enter 键继续...${C_RESET}"
        read -r
    done
}

# =============================================================================
# 主入口
# =============================================================================

main() {
    initialize
    main_loop
}

main "$@"
