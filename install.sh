#!/bin/bash

# Linux 内核与 BBRv3 管理脚本
# 适配 build.yml 工作流架构：支持 amd64/arm64 双架构自动识别
# 功能：完整性校验、自动依赖处理、内核安装管理、旧内核清理

# GitHub 仓库配置（格式：用户名/仓库名）
GITHUB_REPO="EsquireProud547/kernel-actions"

# 终端颜色输出定义
RED='\033[31m'
GREEN='\033[1;32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PURPLE='\033[1;35m'
RESET='\033[0m'

# 系统兼容性检查：仅支持 Debian/Ubuntu 系发行版
if ! command -v apt-get &> /dev/null; then
    echo -e "${RED}此脚本仅支持基于 Debian/Ubuntu 的系统！${RESET}"
    exit 1
fi

# 依赖项自动安装检测
REQUIRED_CMDS=("curl" "wget" "dpkg" "awk" "sed" "sysctl" "jq" "grep" "sha256sum")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${YELLOW}缺少依赖：$cmd，正在安装...${RESET}"
        sudo apt-get update && sudo apt-get install -y $cmd > /dev/null 2>&1
    fi
done

# 系统架构检测与 Debian 架构映射
# 将 uname 输出的架构转换为 Debian 包管理器使用的架构标识
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  DEB_ARCH="amd64" ;;
    aarch64) DEB_ARCH="arm64" ;;
    *)
        echo -e "${RED}仅支持 AMD64 (x86_64) 和 ARM64 (aarch64) 架构，当前架构：$ARCH${RESET}"
        exit 1
        ;;
esac

# 系统配置文件路径定义
SYSCTL_CONF="/etc/sysctl.d/99-custom-kernel.conf"
MODULES_CONF="/etc/modules-load.d/custom-qdisc.conf"

# ============================================================
# 功能函数定义区
# ============================================================

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
# 用于防止配置重复追加或冲突
clean_sysctl_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

# 尝试加载指定的队列算法内核模块
# 参数1：目标队列算法名称
# 参数2：当前队列算法名称（用于测试后恢复）
load_qdisc_module() {
    local target_qdisc="$1"
    local current_qdisc="$2"
    local module_name="sch_$target_qdisc"

    # 首先尝试直接设置目标算法（内置算法无需模块加载）
    if sudo sysctl -w net.core.default_qdisc="$target_qdisc" > /dev/null 2>&1; then
        sudo sysctl -w net.core.default_qdisc="$current_qdisc" > /dev/null 2>&1
        return 0
    fi

    # 直接设置失败，尝试加载对应内核模块
    if sudo modprobe "$module_name" 2>/dev/null; then
        sudo sysctl -w net.core.default_qdisc="$current_qdisc" > /dev/null 2>&1
        return 0
    else
        return 1
    fi
}

# 交互式保存网络优化配置
# 临时应用配置并验证，询问用户是否永久保存
ask_to_save() {
    local target_algo="$ALGO"
    local target_qdisc="$QDISC"
    local current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    echo -e "${BLUE}正在临时应用配置...${RESET}"

    # 尝试加载模块并应用新配置
    load_qdisc_module "$target_qdisc" "$current_qdisc"
    sudo sysctl -w net.core.default_qdisc="$target_qdisc" > /dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$target_algo" > /dev/null 2>&1

    # 验证配置是否成功生效
    local new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local new_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [[ "$new_qdisc" == "$target_qdisc" && "$new_algo" == "$target_algo" ]]; then
        echo -e "${GREEN}✔ 配置已临时生效！${RESET}"
        echo -e "   队列算法：${GREEN}$new_qdisc${RESET}"
        echo -e "   拥塞控制：${GREEN}$new_algo${RESET}"

        echo -n -e "${BLUE}是否永久保存？(y/n): ${RESET}"
        read -r SAVE
        if [[ "$SAVE" =~ ^[yY]$ ]]; then
            clean_sysctl_conf
            echo "net.core.default_qdisc=$target_qdisc" | sudo tee -a "$SYSCTL_CONF" > /dev/null
            echo "net.ipv4.tcp_congestion_control=$target_algo" | sudo tee -a "$SYSCTL_CONF" > /dev/null
            sudo sysctl --system > /dev/null 2>&1

            # 非内置算法需要配置开机自动加载模块
            if [[ "$target_qdisc" != "fq" && "$target_qdisc" != "fq_codel" ]]; then
                echo "sch_$target_qdisc" | sudo tee "$MODULES_CONF" > /dev/null
                echo -e "${GREEN}✔ 模块 sch_$target_qdisc 已设置为开机自启${RESET}"
            else
                sudo rm -f "$MODULES_CONF"
            fi
            echo -e "${GREEN}✔ 配置已永久保存${RESET}"
        else
            echo -e "${YELLOW}已取消永久保存，重启后配置将失效${RESET}"
        fi
    else
        echo -e "${RED}✘ 应用失败！内核可能不支持该组合。${RESET}"
        echo -e "   期望值：$target_qdisc + $target_algo"
        echo -e "   实际值：$new_qdisc + $new_algo"
    fi
}

# 更新系统引导加载程序
# x86_64 系统通常使用 GRUB，ARM64 系统通常自动处理
update_bootloader() {
    echo -e "${BLUE}正在更新引导加载程序...${RESET}"
    if command -v update-grub &> /dev/null; then
        sudo update-grub
    else
        echo -e "${YELLOW}未找到 update-grub，跳过引导更新（ARM 系统通常自动处理）${RESET}"
    fi
}

# 安装下载的 Debian 软件包
# 执行完整性校验、依赖解析和安装流程
install_packages() {
    local tmp_dir="/tmp/kernel-install-$$"
    mkdir -p "$tmp_dir"
    mv /tmp/linux-*.deb "$tmp_dir/" 2>/dev/null || true
    mv /tmp/checksums.txt "$tmp_dir/" 2>/dev/null || true

    if ! ls "$tmp_dir"/*.deb &> /dev/null; then
        echo -e "${RED}❌ 未找到 .deb 包${RESET}"
        rm -rf "$tmp_dir"
        return 1
    fi

    cd "$tmp_dir"

    # SHA256 完整性校验流程
    if [[ -f checksums.txt ]]; then
        echo -e "${BLUE}正在校验下载文件的完整性...${RESET}"
        if sha256sum -c checksums.txt --quiet; then
            echo -e "${GREEN}✔ 所有文件校验通过${RESET}"
        else
            echo -e "${RED}❌ 文件校验失败，可能已损坏，请重新尝试下载。${RESET}"
            rm -rf "$tmp_dir"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠️  未找到 checksums.txt，无法校验文件完整性，请谨慎安装。${RESET}"
    fi

    echo -e "${BLUE}正在安装新内核...（可能需要几分钟）${RESET}"
    if sudo apt install -y ./*.deb; then
        update_bootloader
        echo -e "${GREEN}✔ 安装成功！${RESET}"
        echo -n -e "${YELLOW}立即重启以应用新内核？(y/n): ${RESET}"
        read -r REBOOT
        if [[ "$REBOOT" =~ ^[yY]$ ]]; then
            sudo reboot
        else
            echo -e "${YELLOW}请稍后手动执行 'sudo reboot'${RESET}"
        fi
    else
        echo -e "${RED}❌ 安装失败，请检查错误信息${RESET}"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}

# 从 GitHub Releases 获取并安装内核
# 参数：mode - 可选值 latest_bbrv3 / latest_vanilla / list_all
fetch_and_install() {
    local mode="$1"
    echo -e "${BLUE}正在从 GitHub ($GITHUB_REPO) 获取版本信息...${RESET}"

    local api_url="https://api.github.com/repos/$GITHUB_REPO/releases"
    local response=$(curl -sL "$api_url")

    # API 响应有效性检查
    if [[ -z "$response" ]]; then
        echo -e "${RED}无法从 GitHub API 获取响应${RESET}"
        return 1
    fi

    if echo "$response" | jq -e '.message' > /dev/null 2>&1; then
        local error_msg=$(echo "$response" | jq -r '.message')
        echo -e "${RED}GitHub API 错误：$error_msg${RESET}"
        return 1
    fi

    if ! echo "$response" | jq -e 'type == "array"' > /dev/null 2>&1; then
        echo -e "${RED}GitHub API 返回了意外的格式${RESET}"
        return 1
    fi

    local target_tag=""
    local target_name=""

    if [[ "$mode" == "list_all" ]]; then
        # 交互式版本选择模式
        echo -e "${BLUE}📋 可用版本列表：${RESET}"

        local releases=$(echo "$response" | jq -r --arg arch "$DEB_ARCH" '
            .[] | 
            select(.assets[] | .name | endswith(".deb") and contains($arch)) | 
            "\(.tag_name)|\(.name)"' | head -n 15)

        if [[ -z "$releases" ]]; then
            echo -e "${RED}未找到包含 .deb 包的 Release（请检查架构匹配：$DEB_ARCH）${RESET}"
            return 1
        fi

        IFS='\n' read -rd '' -a release_array <<<"$releases"

        for i in "${!release_array[@]}"; do
            local line="${release_array[$i]}"
            local tag="${line%%|*}"
            local name="${line#*|}"
            echo -e "${YELLOW} $((i+1)). ${RESET} $name ${BLUE}($tag)${RESET}"
        done

        echo -n -e "${BLUE}请输入编号 (1-${#release_array[@]}): ${RESET}"
        read -r choice

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#release_array[@]} )); then
            echo -e "${RED}无效选择${RESET}"
            return 1
        fi

        local selected="${release_array[$((choice-1))]}"
        target_tag="${selected%%|*}"
        target_name="${selected#*|}"

    else
        # 自动选择模式：根据 BBRv3/Vanilla 标识和架构筛选
        local filter_key=""
        if [[ "$mode" == "latest_bbrv3" ]]; then
            filter_key="With BBRv3"
        else
            filter_key="Vanilla"
        fi

        local match=$(echo "$response" | jq -r --arg key "$filter_key" --arg arch "$DEB_ARCH" '
            .[] | 
            select(.name | contains($key)) | 
            select(.assets[] | .name | endswith(".deb") and contains($arch)) | 
            .tag_name' | head -n 1)

        if [[ -z "$match" ]]; then
            echo -e "${RED}未找到符合条件 '$filter_key' 且包含架构 $DEB_ARCH 的 Release${RESET}"
            return 1
        fi
        target_tag="$match"
        echo -e "${GREEN}🔍 找到最新版本：$target_tag ($filter_key)${RESET}"
    fi

    # 获取选中 Release 的资源文件列表
    echo -e "${BLUE}正在获取下载链接...${RESET}"
    local assets=$(echo "$response" | jq -r --arg tag "$target_tag" '
        .[] | 
        select(.tag_name == $tag) | 
        .assets[] | 
        "\(.name)|\(.browser_download_url)"')

    if [[ -z "$assets" ]]; then
        echo -e "${RED}未找到 tag $target_tag 下的任何附件${RESET}"
        return 1
    fi

    # 分类收集下载链接：.deb 包和校验文件
    local deb_urls=()
    local checksum_url=""
    while IFS= read -r line; do
        name="${line%%|*}"
        url="${line#*|}"
        if [[ "$name" == *.deb ]] && [[ "$name" == *"$DEB_ARCH"* ]]; then
            deb_urls+=("$url")
        elif [[ "$name" == "checksums.txt" ]]; then
            checksum_url="$url"
        fi
    done <<< "$assets"

    if [[ ${#deb_urls[@]} -eq 0 ]]; then
        echo -e "${RED}未找到与架构 $DEB_ARCH 匹配的 .deb 文件${RESET}"
        return 1
    fi

    # 清理历史下载文件防止冲突
    rm -f /tmp/linux-*.deb /tmp/checksums.txt

    # 优先下载校验文件
    if [[ -n "$checksum_url" ]]; then
        echo -e "${YELLOW}正在下载校验文件...${RESET}"
        if ! wget -q --show-progress "$checksum_url" -O /tmp/checksums.txt; then
            echo -e "${RED}下载 checksums.txt 失败，将跳过校验。${RESET}"
            rm -f /tmp/checksums.txt
        fi
    else
        echo -e "${YELLOW}⚠️  该 Release 未提供 checksums.txt，将跳过完整性校验。${RESET}"
    fi

    # 批量下载内核 deb 包
    echo -e "${YELLOW}正在下载软件包...${RESET}"
    for url in "${deb_urls[@]}"; do
        if ! wget -q --show-progress "$url" -P /tmp/; then
            echo -e "${RED}下载失败：$url${RESET}"
            rm -f /tmp/linux-*.deb /tmp/checksums.txt
            return 1
        fi
    done

    install_packages
}

# 清理旧内核镜像、头文件和模块包
# 自动识别并保留当前运行内核，删除其余所有内核相关包
remove_all_old_kernels() {
    echo -e "${BLUE}正在扫描所有已安装的内核相关包...${RESET}"
    local current_kernel=$(uname -r)

    # 获取所有已安装的内核相关软件包
    mapfile -t all_kernel_pkgs < <(dpkg -l | awk '/^ii/ && ($2 ~ /^linux-(image|headers|modules)-/){print $2}')

    if [[ ${#all_kernel_pkgs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未发现任何内核相关包。${RESET}"
        return
    fi

    # 筛选出不属于当前运行内核的包
    local to_remove=()
    for pkg in "${all_kernel_pkgs[@]}"; do
        if [[ "$pkg" != *"$current_kernel"* ]]; then
            to_remove+=("$pkg")
        fi
    done

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        echo -e "${GREEN}没有可删除的旧内核（所有内核相关包均属于当前运行版本）。${RESET}"
        return
    fi

    echo -e "${RED}⚠️  即将删除以下旧内核相关包（当前运行内核：$current_kernel 已排除）：${RESET}"
    printf '  - %s\n' "${to_remove[@]}"
    echo -e "${YELLOW}此操作将永久删除这些包及其配置文件，并自动清理无用的依赖。${RESET}"
    echo -n -e "${BLUE}确定要继续吗？(y/N): ${RESET}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}已取消。${RESET}"
        return
    fi

    echo -e "${BLUE}正在删除旧内核相关包...${RESET}"
    sudo apt-get remove --purge -y "${to_remove[@]}"

    echo -e "${BLUE}正在清理不再需要的依赖包...${RESET}"
    sudo apt-get autoremove -y

    update_bootloader
    echo -e "${GREEN}✔ 旧内核清理完成！${RESET}"
}

# 交互式网络算法选择
# 自动检测系统支持的 TCP 拥塞控制算法和队列算法
custom_select_algorithm() {
    echo -e "${BLUE}正在检测系统支持的 TCP 拥塞控制算法和队列算法...${RESET}"

    # 读取内核暴露的可用算法列表
    local tcp_avail
    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        tcp_avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)
    else
        tcp_avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    fi

    if [[ -z "$tcp_avail" ]]; then
        echo -e "${YELLOW}无法获取可用 TCP 算法列表，请手动输入。${RESET}"
        echo -n -e "${BLUE}请输入 TCP 拥塞控制算法名称: ${RESET}"
        read -r ALGO
    else
        read -ra tcp_array <<< "$tcp_avail"
        echo -e "${GREEN}可用的 TCP 拥塞控制算法：${RESET}"
        for i in "${!tcp_array[@]}"; do
            echo -e "  $((i+1)). ${tcp_array[$i]}"
        done
        echo -n -e "${BLUE}请选择编号（或直接输入算法名称）: ${RESET}"
        read -r tcp_choice
        if [[ "$tcp_choice" =~ ^[0-9]+$ ]] && (( tcp_choice >= 1 && tcp_choice <= ${#tcp_array[@]} )); then
            ALGO="${tcp_array[$((tcp_choice-1))]}"
        else
            ALGO="$tcp_choice"
        fi
    fi

    # 队列算法检测与选择
    local qdisc_avail
    if [[ -f /proc/sys/net/core/available_qdisc ]]; then
        qdisc_avail=$(cat /proc/sys/net/core/available_qdisc)
    else
        qdisc_avail=$(sysctl -n net.core.available_qdisc 2>/dev/null)
    fi

    if [[ -z "$qdisc_avail" ]]; then
        echo -e "${YELLOW}无法获取可用队列算法列表，请手动输入。${RESET}"
        echo -n -e "${BLUE}请输入默认队列算法名称: ${RESET}"
        read -r QDISC
    else
        read -ra qdisc_array <<< "$qdisc_avail"
        echo -e "${GREEN}可用的队列算法：${RESET}"
        for i in "${!qdisc_array[@]}"; do
            echo -e "  $((i+1)). ${qdisc_array[$i]}"
        done
        echo -n -e "${BLUE}请选择编号（或直接输入算法名称）: ${RESET}"
        read -r qdisc_choice
        if [[ "$qdisc_choice" =~ ^[0-9]+$ ]] && (( qdisc_choice >= 1 && qdisc_choice <= ${#qdisc_array[@]} )); then
            QDISC="${qdisc_array[$((qdisc_choice-1))]}"
        else
            QDISC="$qdisc_choice"
        fi
    fi

    ask_to_save
}

# ============================================================
# 主程序入口
# ============================================================

clear
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${PURPLE}        Linux 内核与 BBRv3 管理脚本${RESET}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

CURRENT_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
KERNEL_TYPE=$(check_current_kernel_type)

echo -e "当前内核：${GREEN}$(uname -r)${RESET} [$KERNEL_TYPE]"
echo -e "系统架构：${GREEN}$ARCH${RESET} (Debian: ${GREEN}$DEB_ARCH${RESET})"
echo -e "TCP 算法：${GREEN}$CURRENT_ALGO${RESET}"
echo -e "队列算法：${GREEN}$CURRENT_QDISC${RESET}"
echo -e "仓库来源：${YELLOW}$GITHUB_REPO${RESET}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

echo -e "${YELLOW} 1. 🚀 安装最新 BBRv3 内核${RESET}"
echo -e "${YELLOW} 2. 🐧 安装最新原版内核${RESET}"
echo -e "${YELLOW} 3. 📚 选择指定版本安装${RESET}"
echo -e "${YELLOW} 4. ⚡ 启用 BBR + FQ${RESET}（推荐组合）"
echo -e "${YELLOW} 5. ⚡ 启用 BBR + FQ_PIE${RESET}"
echo -e "${YELLOW} 6. ⚡ 启用 BBR + CAKE${RESET}"
echo -e "${YELLOW} 7. 🛠️  自定义设置 TCP 算法 + 队列算法${RESET}（自动检测可用选项）"
echo -e "${YELLOW} 8. 🗑️  一键删除所有旧内核${RESET}（自动跳过当前运行内核）"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -n -e "${BLUE}请选择 (1-8): ${RESET}"
read -r ACTION

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
        echo -e "${RED}无效选项${RESET}"
        ;;
esac
