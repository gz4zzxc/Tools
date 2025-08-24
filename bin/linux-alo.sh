#!/bin/bash

# 设置颜色变量
Green="\033[32m"
Yellow="\033[33m"
Red="\033[31m"
Font="\033[0m"

# 全局变量
isCN=false
OS=""
CODENAME=""

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" != "0" ]; then
       echo -e "${Red}此脚本必须以 root 用户权限运行${Font}" 1>&2
       exit 1
    fi
}

# 检测服务器是否位于中国
geo_check() {
    echo "检测服务器地理位置..."
    api_list=("https://www.cloudflare.com/cdn-cgi/trace" "https://dash.cloudflare.com/cdn-cgi/trace" "https://cf-ns.com/cdn-cgi/trace")
    ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36"
    success=0

    for url in "${api_list[@]}"; do
        response=$(curl -A "$ua" -m 10 -s "$url")
        if [ $? -ne 0 ] || [ -z "$response" ]; then
            echo -e "${Yellow}无法访问 ${url}，尝试下一个 API...${Font}"
            continue
        fi

        loc=$(echo "$response" | grep -oP 'loc=\K\w+')
        if [ "$loc" = "CN" ]; then
            isCN=true
            echo -e "${Green}服务器位中国.${Font}"
            return
        elif [ -n "$loc" ]; then
            echo -e "${Yellow}服务器位于 ${loc}，继续检测其他 API...${Font}"
            success=1
        fi
    done

    if [ "$success" -eq 1 ]; then
        echo -e "${Yellow}服务器不位于中国.${Font}"
    else
        echo -e "${Red}无法检测服务器地理位置，所有 API 均不可用.${Font}"
        echo -e "${Yellow}默认设置为非中国服务器.${Font}"
    fi
}

# 检测操作系统类型
detect_os() {
    if [ -e /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        CODENAME=$VERSION_CODENAME

        if [ -z "$CODENAME" ]; then
            # 对于某些 Debian 或 Ubuntu 版本没有 VERSION_CODENAME 的情况
            CODENAME=$(lsb_release -cs)
        fi

        echo -e "${Green}检测到的操作系统：${OS}, 代号：${CODENAME}${Font}"
    else
        echo -e "${Red}无法检测操作系统类型，脚本将退出.${Font}"
        exit 1
    fi
}

# 设置国内 APT 镜像源
set_cn_mirror() {
    echo "正在切换到中国科技大学 (USTC) 的镜像源..."

    # 备份原有 sources.list
    if [ ! -f /etc/apt/sources.list.bak ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        echo -e "${Green}备份原有 sources.list 至 /etc/apt/sources.list.bak${Font}"
    else
        echo -e "${Yellow}备份文件 /etc/apt/sources.list.bak 已存在，跳过备份步骤${Font}"
    fi

    # 注释掉原有的源
    sed -i.bak '/^deb /s/^/#/' /etc/apt/sources.list

    # 根据不同的操作系统添加相应的镜像源
    if [ "$OS" = "debian" ]; then
        cat <<EOF >> /etc/apt/sources.list

# 使用中国科技大学 (USTC) 的 Debian 镜像源
deb https://mirrors.ustc.edu.cn/debian/ $CODENAME main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian/ $CODENAME-updates main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian/ $CODENAME-backports main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security $CODENAME-security main contrib non-free non-free-firmware
EOF
    elif [ "$OS" = "ubuntu" ]; then
        cat <<EOF >> /etc/apt/sources.list

# 使用中国科技大学 (USTC) 的 Ubuntu 镜像源
deb https://mirrors.ustc.edu.cn/ubuntu/ $CODENAME main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ $CODENAME-backports main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ $CODENAME-security main restricted universe multiverse
EOF
    else
        echo -e "${Red}不支持的操作系统: $OS${Font}"
        exit 1
    fi

    echo -e "${Green}成功添加中国科技大学 (USTC) 的镜像源，并保留了原有源的注释备份${Font}"
}

# 设置国际 APT 镜像源
set_international_mirror() {
    echo "保留默认的国际 Debian 镜像源..."
}

# 安装 Starship
install_starship() {
    echo "通过 curl 安装 Starship..."
    sh -c "$(curl -sS https://starship.rs/install.sh)" || {
        echo -e "${Yellow}Starship 安装失败，跳过此步骤，继续执行下一步。${Font}"
        return 0  # 返回 0 以继续执行后续步骤
    }

    # 验证安装
    if command -v starship >/dev/null 2>&1; then
        echo -e "${Green}Starship 安装成功。版本：$(starship --version)${Font}"
    else
        echo -e "${Yellow}Starship 安装失败，但继续执行下一步。${Font}"
        return 0  # 即使验证失败，也继续执行后续步骤
    fi
}

# 配置 Starship
configure_starship() {
    echo "配置 Starship..."
    zshrc_file="/root/.zshrc"
    starship_config='eval "$(starship init zsh)"'

    if grep -qF "$starship_config" "$zshrc_file"; then
        echo -e "${Yellow}Starship 配置已存在于 .zshrc 中，跳过添加步骤。${Font}"
    else
        echo "$starship_config" >> "$zshrc_file"
        echo -e "${Green}已将 Starship 配置添加到 .zshrc。${Font}"
    fi
}

# 安装 oh-my-zsh
install_oh_my_zsh() {
    echo "安装 oh my zsh..."
    if $isCN; then
        # 使用 Gitee 的 oh-my-zsh 镜像
        sh -c "$(wget https://gitee.com/mirrors/oh-my-zsh/raw/master/tools/install.sh -O -)" "" --unattended
    else
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi
}

# 修改 SSH 配置
configure_ssh() {
    echo "生成 SSH 密钥..."
    ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

    echo "配置 SSH 密钥登录..."

    # 确保 authorized_keys 存在
    touch ~/.ssh/authorized_keys

    # 备份现有 authorized_keys
    cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak

    # 检查是否已经存在该公钥，避免重复添加
    if ! grep -q -F "$(cat ~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys; then
        cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
        echo "新的 SSH 公钥已添加到 authorized_keys。"
    else
        echo "SSH 公钥已存在于 authorized_keys 中，跳过添加。"
    fi

    echo "修改 SSH 配置..."
    if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    else
        echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    fi

    systemctl restart ssh

    echo "SSH 配置已更新并重启 SSH 服务。"
}

# 修改 Swap 分区
setup_swap() {
    echo "检查是否存在 Swap 分区..."

    # 检查是否存在 Swap 分区
    if swapon --show | grep -q "^/"; then
        echo -e "${Green}Swap 分区已存在，跳过 Swap 设置步骤.${Font}"
        return
    fi

    echo -e "${Green}正在为系统创建 Swap 分区...${Font}"

    # 获取系统内存大小（单位 MB）
    mem_total=$(free -m | awk '/^Mem:/ {print $2}')
    swap_size=$((mem_total * 2))

    # 限制 Swap 大小不超过 8192MB (8G)
    if [ "$swap_size" -gt 8192 ]; then
        swap_size=8192
    fi

    echo "系统内存: ${mem_total}MB, 需要创建的 Swap 大小: ${swap_size}MB"

    fallocate -l ${swap_size}M /swap
    if [ $? -ne 0 ]; then
        echo -e "${Red}fallocate 创建 Swap 文件失败，尝试使用 dd 命令...${Font}"
        dd if=/dev/zero of=/swap bs=1M count=${swap_size}
        if [ $? -ne 0 ]; then
            echo -e "${Red}使用 dd 创建 Swap 文件失败，请检查磁盘空间或权限设置.${Font}"
            exit 1
        fi
    fi

    chmod 600 /swap
    mkswap /swap
    swapon /swap
    echo '/swap none swap defaults 0 0' >> /etc/fstab

    echo -e "${Green}Swap 分区创建成功，并查看信息：${Font}"
    swapon --show
    free -h
}

# 开启 BBR
enable_bbr() {
    echo "开启 BBR..."
    uname -r
    
    # 检查并添加 net.core.default_qdisc 配置
    if ! grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "已添加 net.core.default_qdisc=fq 配置"
    else
        echo "net.core.default_qdisc=fq 配置已存在，无需添加"
    fi

    # 检查并添加 net.ipv4.tcp_congestion_control 配置
    if ! grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        echo "已添加 net.ipv4.tcp_congestion_control=bbr 配置"
    else
        echo "net.ipv4.tcp_congestion_control=bbr 配置已存在，无需添加"
    fi

    sysctl -p

    # 检查 BBR 是否成功开启
    if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
        echo -e "${Green}BBR 已成功开启！${Font}"
    else
        echo -e "${Red}BBR 开启失败，请检查您的系统是否支持 BBR。${Font}"
    fi
}

# 主函数
main() {
    check_root
    geo_check
    detect_os

    # 根据地理位置设置镜像源
    if $isCN; then
        set_cn_mirror
    else
        set_international_mirror
    fi

    # 更新软件包列表
    echo "更新软件包列表..."
    apt update

    # 安装必备软件
    echo "安装必备软件..."
    apt install -y git wget vim nano zsh curl tar zip unzip sudo

    # 设置 Zsh 为默认终端
    echo "设置 Zsh 为默认终端..."
    chsh -s "$(which zsh)" || echo -e "${Yellow}更改默认 shell 失败，请手动执行 chsh 命令.${Font}"

    # 安装 oh-my-zsh
    install_oh_my_zsh

    # 安装 Starship
    install_starship

    # 配置 Starship
    configure_starship

    # 修改 SSH 配置
    configure_ssh

    # 修改 Swap 分区
    setup_swap

    # 开启 BBR
    enable_bbr

    # 其他配置步骤...

    echo "所有操作完成，请检查配置是否正确。"   

    # 提示用户下载私钥
    echo "请将 ~/.ssh/id_rsa 私钥下载到客户端以使用密钥登录。"
}

main