#!/bin/bash

# 更安全的 Bash 选项
set -Eeuo pipefail
IFS=$' \t\n'
export DEBIAN_FRONTEND=noninteractive

# 设置颜色变量
Green="\033[32m"
Yellow="\033[33m"
Red="\033[31m"
Font="\033[0m"

# 全局变量
isCN=false
OS=""
CODENAME=""
VERSION_ID=""

# 内置默认哈希（可通过环境变量覆盖）
STARSHIP_INSTALL_SHA256_DEFAULT="eb6f59c6d1fb193fa28d6fc33a546a0df59539bb90bc8a6e043bda1589549d26"
OHMYZSH_INSTALL_SHA256_DEFAULT="ce0b7c94aa04d8c7a8137e45fe5c4744e3947871f785fd58117c480c1bf49352"
STARSHIP_INSTALL_HASH_SOURCE_URL_DEFAULT="https://raw.githubusercontent.com/starship/starship/master/install/install.sh"
OHMYZSH_INSTALL_HASH_SOURCE_URL_DEFAULT="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"

STARSHIP_INSTALL_SHA256="${STARSHIP_INSTALL_SHA256:-$STARSHIP_INSTALL_SHA256_DEFAULT}"
OHMYZSH_INSTALL_SHA256_GITHUB="${OHMYZSH_INSTALL_SHA256_GITHUB:-${OHMYZSH_INSTALL_SHA256:-$OHMYZSH_INSTALL_SHA256_DEFAULT}}"
OHMYZSH_INSTALL_SHA256_GITEE="${OHMYZSH_INSTALL_SHA256_GITEE:-${OHMYZSH_INSTALL_SHA256:-$OHMYZSH_INSTALL_SHA256_DEFAULT}}"
STARSHIP_INSTALL_HASH_SOURCE_URL="${STARSHIP_INSTALL_HASH_SOURCE_URL:-$STARSHIP_INSTALL_HASH_SOURCE_URL_DEFAULT}"
OHMYZSH_INSTALL_HASH_SOURCE_URL="${OHMYZSH_INSTALL_HASH_SOURCE_URL:-$OHMYZSH_INSTALL_HASH_SOURCE_URL_DEFAULT}"

# 计算文件 SHA256
sha256_file() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        return 1
    fi
}

# 下载文件到本地
download_file() {
    url="$1"
    dst="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --retry-delay 1 "$url" -o "$dst"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dst" "$url"
    else
        return 1
    fi
}

# 从远程参考文件计算 SHA256
remote_sha256() {
    src_url="$1"
    tmp_ref=$(mktemp)

    if ! download_file "$src_url" "$tmp_ref"; then
        rm -f "$tmp_ref"
        return 1
    fi

    if ! ref_sha256=$(sha256_file "$tmp_ref"); then
        rm -f "$tmp_ref"
        return 1
    fi

    rm -f "$tmp_ref"
    printf '%s\n' "$ref_sha256"
}

# 下载目标脚本 + 获取远程参考哈希 + 校验 + 本地执行
run_verified_script() {
    script_url="$1"
    hash_source_url="$2"
    fallback_sha256="$3"
    sha_var_name="$4"
    interpreter="$5"
    shift 5

    tmp_script=$(mktemp)

    if ! download_file "$script_url" "$tmp_script"; then
        rm -f "$tmp_script"
        echo -e "${Yellow}下载脚本失败: ${script_url}${Font}"
        return 1
    fi

    if ! actual_sha256=$(sha256_file "$tmp_script"); then
        rm -f "$tmp_script"
        echo -e "${Red}无法计算 SHA256（缺少 sha256sum/shasum），拒绝执行: ${script_url}${Font}"
        return 1
    fi

    expected_sha256=""
    if [ -n "$hash_source_url" ]; then
        expected_sha256=$(remote_sha256 "$hash_source_url" || true)
    fi

    if [ -z "$expected_sha256" ] && [ -n "$fallback_sha256" ]; then
        expected_sha256="$fallback_sha256"
        echo -e "${Yellow}无法获取远程参考哈希，使用内置哈希校验（${sha_var_name}）.${Font}"
    fi

    if [ -z "$expected_sha256" ]; then
        rm -f "$tmp_script"
        echo -e "${Red}无法获取可用哈希（远程与本地回退均不可用），拒绝执行: ${script_url}${Font}"
        return 1
    fi

    if [ "$actual_sha256" != "$expected_sha256" ]; then
        rm -f "$tmp_script"
        echo -e "${Red}脚本 SHA256 校验失败: ${script_url}${Font}"
        echo -e "${Yellow}期望: ${expected_sha256}${Font}"
        echo -e "${Yellow}实际: ${actual_sha256}${Font}"
        return 1
    fi

    chmod 700 "$tmp_script"
    if "$interpreter" "$tmp_script" "$@"; then
        rm -f "$tmp_script"
        return 0
    fi

    rm -f "$tmp_script"
    return 1
}

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" != "0" ]; then
       echo -e "${Red}此脚本必须以 root 用户权限运行${Font}" 1>&2
       exit 1
    fi
}

# 检测服务器是否位于中国
fetch_geo_trace() {
    local url="$1"
    local ua="$2"
    local ip_mode="${GEO_CURL_IP_VERSION:-auto}"
    local response=""
    local -a modes

    case "$ip_mode" in
        4)
            modes=("-4")
            ;;
        6)
            modes=("-6")
            ;;
        auto|"")
            # 默认先走 curl 自动协商；失败后回退到 IPv6 / IPv4 强制模式
            modes=("" "-6" "-4")
            ;;
        *)
            # 非法配置按 auto 处理，避免脚本中断
            modes=("" "-6" "-4")
            ;;
    esac

    for mode in "${modes[@]}"; do
        if [ -n "$mode" ]; then
            if response=$(curl "$mode" -fSL -A "$ua" -m 8 -s "$url" 2>/dev/null); then
                printf '%s\n' "$response"
                return 0
            fi
        else
            if response=$(curl -fSL -A "$ua" -m 8 -s "$url" 2>/dev/null); then
                printf '%s\n' "$response"
                return 0
            fi
        fi
    done

    return 1
}

geo_check() {
    echo "检测服务器地理位置..."
    api_list=(
        "https://www.cloudflare.com/cdn-cgi/trace"
        "https://dash.cloudflare.com/cdn-cgi/trace"
        "https://cf-ns.com/cdn-cgi/trace"
    )
    ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36"
    success=0

    for url in "${api_list[@]}"; do
        if ! response=$(fetch_geo_trace "$url" "$ua"); then
            echo -e "${Yellow}无法访问 ${url}，尝试下一个 API...${Font}"
            continue
        fi

        loc=$(printf '%s\n' "$response" | awk -F= '/^loc=/{print $2; exit}' | tr -d '\r')
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
        OS=${ID:-}
        CODENAME=${VERSION_CODENAME:-}
        VERSION_ID=${VERSION_ID:-}

        # 对于某些系统没有 VERSION_CODENAME 的情况进行兜底
        if [ -z "$CODENAME" ]; then
            # Ubuntu 常见兜底
            if [ "${OS}" = "ubuntu" ] && [ -n "${UBUNTU_CODENAME:-}" ]; then
                CODENAME=${UBUNTU_CODENAME}
            elif command -v lsb_release >/dev/null 2>&1; then
                CODENAME=$(lsb_release -cs || true)
            fi
        fi

        # 最后再基于 VERSION_ID 做一次简单映射兜底
        if [ -z "$CODENAME" ] && [ -n "$VERSION_ID" ]; then
            case "$OS" in
                debian)
                    case "$VERSION_ID" in
                        12*) CODENAME="bookworm" ;;
                        11*) CODENAME="bullseye" ;;
                        10*) CODENAME="buster" ;;
                    esac
                    ;;
                ubuntu)
                    case "$VERSION_ID" in
                        24.04*) CODENAME="noble" ;;
                        22.04*) CODENAME="jammy" ;;
                        20.04*) CODENAME="focal" ;;
                        18.04*) CODENAME="bionic" ;;
                    esac
                    ;;
            esac
        fi

        if [ -n "$OS" ] && [ -n "$CODENAME" ]; then
            echo -e "${Green}检测到的操作系统：${OS}, 代号：${CODENAME}${Font}"
        else
            echo -e "${Red}无法确定操作系统或代号，脚本将退出.${Font}"
            exit 1
        fi
    else
        echo -e "${Red}无法检测操作系统类型，脚本将退出.${Font}"
        exit 1
    fi
}

# 检查 Debian 版本是否受支持（仅支持 Debian 11+）
check_supported_debian_version() {
    if [ "$OS" != "debian" ]; then
        return 0
    fi

    major=""
    if [ -n "${VERSION_ID:-}" ]; then
        major=${VERSION_ID%%.*}
    fi

    if [ -n "$major" ] && [ "$major" -ge 11 ] 2>/dev/null; then
        return 0
    fi

    if [ -z "$major" ]; then
        case "$CODENAME" in
            bullseye|bookworm|trixie)
                return 0
                ;;
        esac
    fi

    echo -e "${Red}不支持的 Debian 版本: ${VERSION_ID:-unknown}（代号: ${CODENAME:-unknown}）。仅支持 Debian 11 及以上版本（11/12/13+）。${Font}"
    exit 1
}

# 使用 Deb822 写入 Debian 软件源配置
write_debian_sources_deb822() {
    mirror_base="$1"
    security_base="$2"
    sources_file="/etc/apt/sources.list.d/debian.sources"

    # 备份旧配置（仅一次）
    if [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.bak ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        echo -e "${Green}备份原有 sources.list 至 /etc/apt/sources.list.bak${Font}"
    fi

    if [ -f "$sources_file" ] && [ ! -f "${sources_file}.bak" ]; then
        cp "$sources_file" "${sources_file}.bak"
        echo -e "${Green}备份原有 debian.sources 至 ${sources_file}.bak${Font}"
    fi

    major=${VERSION_ID%%.*}
    if [ -n "$major" ] && [ "$major" -ge 12 ] 2>/dev/null; then
        comps="main contrib non-free non-free-firmware"
    elif [ "$CODENAME" = "bullseye" ]; then
        comps="main contrib non-free"
    else
        # VERSION_ID 缺失时，默认按新版本启用 non-free-firmware
        comps="main contrib non-free non-free-firmware"
    fi

    cat > "$sources_file" <<EOF
Types: deb
URIs: ${mirror_base}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: ${comps}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${security_base}
Suites: ${CODENAME}-security
Components: ${comps}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    # 避免与 Deb822 重复配置
    cat > /etc/apt/sources.list <<'EOF'
# This file is managed by linux-alo.sh.
# Debian sources are configured in /etc/apt/sources.list.d/debian.sources.
EOF
}

# 使用 Deb822 写入 Ubuntu 软件源配置
write_ubuntu_sources_deb822() {
    mirror_base="$1"
    security_base="$2"
    sources_file="/etc/apt/sources.list.d/ubuntu.sources"

    # 备份旧配置（仅一次）
    if [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.bak ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        echo -e "${Green}备份原有 sources.list 至 /etc/apt/sources.list.bak${Font}"
    fi

    if [ -f "$sources_file" ] && [ ! -f "${sources_file}.bak" ]; then
        cp "$sources_file" "${sources_file}.bak"
        echo -e "${Green}备份原有 ubuntu.sources 至 ${sources_file}.bak${Font}"
    fi

    cat > "$sources_file" <<EOF
Types: deb
URIs: ${mirror_base}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${security_base}
Suites: ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

    # 避免与 Deb822 重复配置
    cat > /etc/apt/sources.list <<'EOF'
# This file is managed by linux-alo.sh.
# Ubuntu sources are configured in /etc/apt/sources.list.d/ubuntu.sources.
EOF
}

# 设置国内 APT 镜像源
set_cn_mirror() {
    echo "正在切换到中国科技大学 (USTC) 的镜像源..."

    # 根据不同的操作系统写入相应的镜像源（覆盖写入，避免文件无限增大）
    if [ "$OS" = "debian" ]; then
        # 安全源固定使用 Debian 官方，主仓使用 USTC
        write_debian_sources_deb822 "https://mirrors.ustc.edu.cn/debian" "https://security.debian.org/debian-security"
        echo -e "${Green}Debian 已切换为 Deb822 源配置（主仓 USTC，安全仓官方）。${Font}"
    elif [ "$OS" = "ubuntu" ]; then
        # 检测是否使用 Deb822 格式（Ubuntu 24.04+）
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            # 使用 Deb822 格式
            write_ubuntu_sources_deb822 "https://mirrors.ustc.edu.cn/ubuntu" "https://mirrors.ustc.edu.cn/ubuntu"
            echo -e "${Green}Ubuntu 已切换为 Deb822 源配置（USTC 镜像）。${Font}"
        else
            # 传统格式（旧版本 Ubuntu）
            if [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.bak ]; then
                cp /etc/apt/sources.list /etc/apt/sources.list.bak
                echo -e "${Green}备份原有 sources.list 至 /etc/apt/sources.list.bak${Font}"
            fi

            cat > /etc/apt/sources.list <<EOF
# USTC Ubuntu 镜像
deb https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb https://mirrors.ustc.edu.cn/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF
        fi
    else
        echo -e "${Red}不支持的操作系统: $OS${Font}"
        exit 1
    fi

    echo -e "${Green}已切换到 USTC 镜像源（覆盖写入）${Font}"
}

# 设置国际 APT 镜像源
set_international_mirror() {
    if [ "$OS" = "debian" ]; then
        echo "正在切换到 Debian 官方 Deb822 源配置..."
        write_debian_sources_deb822 "https://deb.debian.org/debian" "https://security.debian.org/debian-security"
        echo -e "${Green}Debian 已切换为官方 Deb822 源配置。${Font}"
    elif [ "$OS" = "ubuntu" ]; then
        # 检测是否使用 Deb822 格式（Ubuntu 24.04+）
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            echo "正在切换到 Ubuntu 官方 Deb822 源配置..."
            write_ubuntu_sources_deb822 "http://archive.ubuntu.com/ubuntu" "http://security.ubuntu.com/ubuntu"
            echo -e "${Green}Ubuntu 已切换为官方 Deb822 源配置。${Font}"
        else
            echo "保留默认的国际 Ubuntu 镜像源..."
        fi
    else
        echo "保留默认的国际镜像源..."
    fi
}

# 安装 Starship
install_starship() {
    echo "安装 Starship..."
    # 优先尝试 APT 包（部分新版本 Debian/Ubuntu 提供）
    if apt-get install -y -qq starship >/dev/null 2>&1; then
        echo -e "${Green}Starship 通过 APT 安装成功。版本：$(starship --version)${Font}"
        return 0
    fi

    # 回退到官方安装脚本（非交互）
    if run_verified_script "https://starship.rs/install.sh" "$STARSHIP_INSTALL_HASH_SOURCE_URL" "$STARSHIP_INSTALL_SHA256" "STARSHIP_INSTALL_SHA256" sh -y; then
        if command -v starship >/dev/null 2>&1; then
            echo -e "${Green}Starship 安装成功。版本：$(starship --version)${Font}"
        else
            echo -e "${Yellow}Starship 安装后未检测到可执行文件，但继续执行下一步。${Font}"
        fi
    else
        echo -e "${Yellow}Starship 安装失败，跳过此步骤，继续执行下一步。${Font}"
    fi
}

# 配置 Starship
configure_starship() {
    echo "配置 Starship..."
    zshrc_file="${ZDOTDIR:-$HOME}/.zshrc"
    starship_config='eval "$(starship init zsh)"'

    touch "$zshrc_file"
    # 关闭 oh-my-zsh 主题，避免与 starship 提示符冲突
    if grep -q '^ZSH_THEME=' "$zshrc_file"; then
        sed -i 's/^ZSH_THEME=.*/ZSH_THEME=""/' "$zshrc_file"
    else
        echo 'ZSH_THEME=""' >> "$zshrc_file"
    fi

    if grep -qF "$starship_config" "$zshrc_file"; then
        echo -e "${Yellow}Starship 配置已存在于 .zshrc 中，跳过添加步骤。${Font}"
    else
        echo "$starship_config" >> "$zshrc_file"
        echo -e "${Green}已将 Starship 配置添加到 .zshrc。${Font}"
    fi
}

# 安装 oh-my-zsh
install_oh_my_zsh() {
    echo "安装 oh-my-zsh..."
    export RUNZSH=no
    export CHSH=no

    ohmyzsh_github_url="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
    ohmyzsh_gitee_url="https://gitee.com/mirrors/oh-my-zsh/raw/master/tools/install.sh"

    # 已安装则跳过
    if [ -d "$HOME/.oh-my-zsh" ]; then
        echo -e "${Yellow}检测到 ~/.oh-my-zsh 已存在，跳过安装。${Font}"
        return 0
    fi

    # 按地理位置选择优先源：在中国优先 Gitee，否则优先 GitHub
    if $isCN; then
        if ! run_verified_script "$ohmyzsh_gitee_url" "$OHMYZSH_INSTALL_HASH_SOURCE_URL" "$OHMYZSH_INSTALL_SHA256_GITEE" "OHMYZSH_INSTALL_SHA256_GITEE" sh --unattended; then
            echo -e "${Yellow}通过 Gitee 安装 oh-my-zsh 失败，尝试 GitHub 源...${Font}"
            run_verified_script "$ohmyzsh_github_url" "$OHMYZSH_INSTALL_HASH_SOURCE_URL" "$OHMYZSH_INSTALL_SHA256_GITHUB" "OHMYZSH_INSTALL_SHA256_GITHUB" sh --unattended || true
        fi
    else
        if ! run_verified_script "$ohmyzsh_github_url" "$OHMYZSH_INSTALL_HASH_SOURCE_URL" "$OHMYZSH_INSTALL_SHA256_GITHUB" "OHMYZSH_INSTALL_SHA256_GITHUB" sh --unattended; then
            echo -e "${Yellow}通过 GitHub 安装 oh-my-zsh 失败，尝试 Gitee 源...${Font}"
            run_verified_script "$ohmyzsh_gitee_url" "$OHMYZSH_INSTALL_HASH_SOURCE_URL" "$OHMYZSH_INSTALL_SHA256_GITEE" "OHMYZSH_INSTALL_SHA256_GITEE" sh --unattended || true
        fi
    fi
}

# 安装并启用常用 zsh 插件
install_zsh_plugins() {
    echo "安装 zsh 插件..."

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        echo -e "${Yellow}未检测到 oh-my-zsh，跳过插件安装。${Font}"
        return 0
    fi

    zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    plugins_dir="$zsh_custom/plugins"
    zshrc_file="${ZDOTDIR:-$HOME}/.zshrc"

    mkdir -p "$plugins_dir"

    # zsh-autosuggestions
    if [ -d "$plugins_dir/zsh-autosuggestions/.git" ]; then
        echo -e "${Yellow}zsh-autosuggestions 已存在，跳过克隆。${Font}"
    else
        if $isCN; then
            if ! git clone -q https://gitee.com/mirrors/zsh-autosuggestions.git "$plugins_dir/zsh-autosuggestions"; then
                echo -e "${Yellow}通过 Gitee 安装 zsh-autosuggestions 失败，尝试 GitHub 源...${Font}"
                git clone -q https://github.com/zsh-users/zsh-autosuggestions.git "$plugins_dir/zsh-autosuggestions" || true
            fi
        else
            if ! git clone -q https://github.com/zsh-users/zsh-autosuggestions.git "$plugins_dir/zsh-autosuggestions"; then
                echo -e "${Yellow}通过 GitHub 安装 zsh-autosuggestions 失败，尝试 Gitee 源...${Font}"
                git clone -q https://gitee.com/mirrors/zsh-autosuggestions.git "$plugins_dir/zsh-autosuggestions" || true
            fi
        fi
    fi

    # zsh-syntax-highlighting
    if [ -d "$plugins_dir/zsh-syntax-highlighting/.git" ]; then
        echo -e "${Yellow}zsh-syntax-highlighting 已存在，跳过克隆。${Font}"
    else
        if $isCN; then
            if ! git clone -q https://gitee.com/mirrors/zsh-syntax-highlighting.git "$plugins_dir/zsh-syntax-highlighting"; then
                echo -e "${Yellow}通过 Gitee 安装 zsh-syntax-highlighting 失败，尝试 GitHub 源...${Font}"
                git clone -q https://github.com/zsh-users/zsh-syntax-highlighting.git "$plugins_dir/zsh-syntax-highlighting" || true
            fi
        else
            if ! git clone -q https://github.com/zsh-users/zsh-syntax-highlighting.git "$plugins_dir/zsh-syntax-highlighting"; then
                echo -e "${Yellow}通过 GitHub 安装 zsh-syntax-highlighting 失败，尝试 Gitee 源...${Font}"
                git clone -q https://gitee.com/mirrors/zsh-syntax-highlighting.git "$plugins_dir/zsh-syntax-highlighting" || true
            fi
        fi
    fi

    touch "$zshrc_file"

    # 确保 plugins=() 包含这两个插件，并保持幂等与格式稳定
    if grep -qE '^[[:space:]]*plugins[[:space:]]*=[[:space:]]*\(' "$zshrc_file"; then
        plugins_line=$(grep -m1 -E '^[[:space:]]*plugins[[:space:]]*=[[:space:]]*\(' "$zshrc_file")
        plugins_raw=$(printf '%s\n' "$plugins_line" | sed -E 's/^[[:space:]]*plugins[[:space:]]*=[[:space:]]*\(([^)]*)\).*/\1/')

        plugins_list=()
        if [ -n "$plugins_raw" ]; then
            IFS=' ' read -r -a plugins_tokens <<< "$plugins_raw"
            for plugin in "${plugins_tokens[@]}"; do
                [ -z "$plugin" ] && continue
                case " ${plugins_list[*]} " in
                    *" $plugin "*) ;;
                    *) plugins_list+=("$plugin") ;;
                esac
            done
        fi

        for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
            case " ${plugins_list[*]} " in
                *" $plugin "*) ;;
                *) plugins_list+=("$plugin") ;;
            esac
        done

        plugins_joined=$(printf '%s ' "${plugins_list[@]}")
        plugins_joined=${plugins_joined% }
        plugins_line_new="plugins=(${plugins_joined})"
        tmp_zshrc=$(mktemp)
        if awk -v new_line="$plugins_line_new" '
            BEGIN { replaced=0 }
            /^[[:space:]]*#/ { print; next }
            !replaced && /^[[:space:]]*plugins[[:space:]]*=[[:space:]]*\(/ {
                print new_line
                replaced=1
                next
            }
            { print }
        ' "$zshrc_file" > "$tmp_zshrc"; then
            mv "$tmp_zshrc" "$zshrc_file"
        else
            rm -f "$tmp_zshrc"
            echo -e "${Yellow}更新 .zshrc 插件配置失败，保留原文件。${Font}"
        fi
    else
        echo 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)' >> "$zshrc_file"
    fi

    echo -e "${Green}zsh 插件安装并配置完成。${Font}"
}

# 修改 SSH 配置
configure_ssh() {
    echo "配置 SSH 密钥登录..."

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # 如果没有密钥则生成（优先 ed25519，不支持再退回 rsa）
    if [ ! -f ~/.ssh/id_ed25519 ] && [ ! -f ~/.ssh/id_rsa ]; then
        if ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 2>/dev/null; then
            key_pub=~/.ssh/id_ed25519.pub
        else
            ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
            key_pub=~/.ssh/id_rsa.pub
        fi
    else
        # 选择已有的公钥
        if [ -f ~/.ssh/id_ed25519.pub ]; then
            key_pub=~/.ssh/id_ed25519.pub
        else
            key_pub=~/.ssh/id_rsa.pub
        fi
    fi

    # 确保 authorized_keys 存在并权限正确
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    # 备份现有 authorized_keys（一次）
    [ ! -f ~/.ssh/authorized_keys.bak ] && cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak || true

    # 检查是否已经存在该公钥，避免重复添加
    if [ -f "$key_pub" ] && ! grep -q -F "$(cat "$key_pub")" ~/.ssh/authorized_keys; then
        cat "$key_pub" >> ~/.ssh/authorized_keys
        echo "新的 SSH 公钥已添加到 authorized_keys。"
    else
        echo "SSH 公钥已存在于 authorized_keys 中，跳过添加。"
    fi

    echo "修改 SSH 配置..."

    set_sshd_option() {
        local file_path="$1"
        local key="$2"
        local value="$3"

        if [ ! -f "$file_path" ]; then
            touch "$file_path"
        fi

        if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file_path"; then
            sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$file_path"
        else
            printf '%s %s\n' "$key" "$value" >> "$file_path"
        fi
    }

    set_sshd_option /etc/ssh/sshd_config PermitRootLogin yes

    if [ -d /etc/ssh/sshd_config.d ]; then
        set_sshd_option /etc/ssh/sshd_config.d/99-linux-alo.conf PermitRootLogin yes
    fi

    # 如需仅允许密钥登录，可同时设置为：PasswordAuthentication no
    # if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
    #     sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    # else
    #     echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    # fi

    echo "验证 SSH 配置..."
    if ! sshd -t; then
        echo -e "${Red}SSH 配置语法验证失败，请检查 /etc/ssh/sshd_config 与 /etc/ssh/sshd_config.d/*.conf.${Font}" >&2
        exit 1
    fi

    local SSH_SERVICE=""
    if systemctl is-active --quiet sshd; then
        SSH_SERVICE="sshd"
    elif systemctl is-active --quiet ssh; then
        SSH_SERVICE="ssh"
    elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
        SSH_SERVICE="sshd"
    elif systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
        SSH_SERVICE="ssh"
    else
        echo -e "${Red}未检测到 SSH 服务（sshd 或 ssh），无法重启。${Font}" >&2
        exit 1
    fi

    echo "检测到 SSH 服务名：${SSH_SERVICE}"
    if ! systemctl restart "${SSH_SERVICE}"; then
        echo -e "${Red}SSH 服务重启失败：${SSH_SERVICE}${Font}" >&2
        exit 1
    fi

    echo "SSH 配置已更新并重启 SSH 服务。"
}

# 修改 Swap 分区
setup_swap() {
    echo "检查是否存在 Swap 分区..."

    # 已有 swap 激活
    if swapon --show | grep -q "^/"; then
        echo -e "${Green}Swap 分区已存在，跳过 Swap 设置步骤.${Font}"
        return
    fi

    # 如果存在 /swap 文件但未激活，尝试直接启用并确保写入 fstab
    if [ -f /swap ]; then
        chmod 600 /swap || { echo -e "${Red}权限设置失败${Font}"; return 1; }
        
        if ! file /swap | grep -q "swap file"; then
            mkswap /swap || { echo -e "${Red}mkswap 失败${Font}"; return 1; }
        fi
        
        swapon /swap || { echo -e "${Red}swapon 失败${Font}"; return 1; }
        
        if ! grep -q '^/swap ' /etc/fstab; then
            echo '/swap none swap defaults 0 0' >> /etc/fstab
        fi
        
        echo -e "${Green}/swap 已启用。${Font}"
        swapon --show
        free -h
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

    if ! fallocate -l ${swap_size}M /swap 2>/dev/null; then
        echo -e "${Yellow}fallocate 创建 Swap 文件失败，尝试使用 dd 命令...${Font}"
        if ! dd if=/dev/zero of=/swap bs=1M count=${swap_size} 2>/dev/null; then
            echo -e "${Red}dd 创建 Swap 文件失败${Font}"
            rm -f /swap
            return 1
        fi
    fi

    chmod 600 /swap || { echo -e "${Red}权限设置失败${Font}"; rm -f /swap; return 1; }
    mkswap /swap || { echo -e "${Red}mkswap 失败${Font}"; rm -f /swap; return 1; }
    swapon /swap || { echo -e "${Red}swapon 失败${Font}"; rm -f /swap; return 1; }
    
    if ! grep -q '^/swap ' /etc/fstab; then
        echo '/swap none swap defaults 0 0' >> /etc/fstab
    fi

    echo -e "${Green}Swap 分区创建成功，并查看信息：${Font}"
    swapon --show
    free -h
}

# 开启 BBR
enable_bbr() {
    echo "开启 BBR..."

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

    sysctl -p >/dev/null || true

    # 检查 BBR 是否成功开启
    if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q '^bbr$'; then
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
    check_supported_debian_version

    # 根据地理位置设置镜像源
    if $isCN; then
        set_cn_mirror
    else
        set_international_mirror
    fi

    # 更新软件包列表
    echo "更新软件包列表..."
    apt-get update -o Acquire::Retries=3

    # 安装必备软件
    echo "安装必备软件..."
    apt-get install -y git wget vim nano zsh curl tar zip unzip sudo ca-certificates

    # 设置 Zsh 为默认终端
    echo "设置 Zsh 为默认终端..."
    chsh -s "$(command -v zsh)" || echo -e "${Yellow}更改默认 shell 失败，请手动执行 chsh 命令.${Font}"

    # 安装 oh-my-zsh
    install_oh_my_zsh

    # 安装并启用 zsh 插件
    install_zsh_plugins

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

    # 提示用户下载实际存在的私钥
    if [ -f "$HOME/.ssh/id_ed25519" ]; then
        echo "请将 ~/.ssh/id_ed25519 私钥下载到客户端以使用密钥登录。"
    elif [ -f "$HOME/.ssh/id_rsa" ]; then
        echo "请将 ~/.ssh/id_rsa 私钥下载到客户端以使用密钥登录。"
    else
        echo -e "${Yellow}未找到可下载的 SSH 私钥（~/.ssh/id_ed25519 或 ~/.ssh/id_rsa），请手动检查。${Font}"
    fi
}

main
