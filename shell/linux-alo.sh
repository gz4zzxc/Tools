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
    # 可传入替代文件进行检测测试；正常执行时使用系统 os-release。
    local os_release_file="${1:-/etc/os-release}"

    if [ -e "$os_release_file" ]; then
        . "$os_release_file"
        OS=${ID:-}
        CODENAME=${VERSION_CODENAME:-}
        VERSION_ID=${VERSION_ID:-}

        if [ "$OS" != "debian" ]; then
            echo -e "${Red}不支持的操作系统: ${OS:-unknown}。仅支持 Debian 11 及以上版本（11/12/13+）。${Font}" >&2
            exit 1
        fi

        # 对于某些系统没有 VERSION_CODENAME 的情况进行兜底
        if [ -z "$CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
            CODENAME=$(lsb_release -cs || true)
        fi

        # 最后再基于 VERSION_ID 做一次简单映射兜底
        if [ -z "$CODENAME" ] && [ -n "$VERSION_ID" ]; then
            case "$VERSION_ID" in
                13*) CODENAME="trixie" ;;
                12*) CODENAME="bookworm" ;;
                11*) CODENAME="bullseye" ;;
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
        echo -e "${Red}不支持的操作系统: ${OS:-unknown}。仅支持 Debian 11 及以上版本（11/12/13+）。${Font}" >&2
        exit 1
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

# 设置国内 APT 镜像源
set_cn_mirror() {
    echo "正在切换到中国科技大学 (USTC) 的镜像源..."

    # 安全源固定使用 Debian 官方，主仓使用 USTC
    write_debian_sources_deb822 "https://mirrors.ustc.edu.cn/debian" "https://security.debian.org/debian-security"
    echo -e "${Green}Debian 已切换为 Deb822 源配置（主仓 USTC，安全仓官方）。${Font}"

    echo -e "${Green}已切换到 USTC 镜像源（覆盖写入）${Font}"
}

# 设置国际 APT 镜像源
set_international_mirror() {
    echo "正在切换到 Debian 官方 Deb822 源配置..."
    write_debian_sources_deb822 "https://deb.debian.org/debian" "https://security.debian.org/debian-security"
    echo -e "${Green}Debian 已切换为官方 Deb822 源配置。${Font}"
}

# 安装 Starship
install_starship() {
    echo "安装 Starship..."
    # 优先尝试 APT 包（部分新版本 Debian 提供）
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
        if run_verified_script "$ohmyzsh_gitee_url" "$OHMYZSH_INSTALL_HASH_SOURCE_URL" "$OHMYZSH_INSTALL_SHA256_GITEE" "OHMYZSH_INSTALL_SHA256_GITEE" sh --unattended; then
            return 0
        fi
        echo -e "${Yellow}通过 Gitee 安装 oh-my-zsh 失败，尝试 GitHub 源...${Font}"
        if run_verified_script "$ohmyzsh_github_url" "$OHMYZSH_INSTALL_HASH_SOURCE_URL" "$OHMYZSH_INSTALL_SHA256_GITHUB" "OHMYZSH_INSTALL_SHA256_GITHUB" sh --unattended; then
            return 0
        fi
        echo -e "${Red}oh-my-zsh 安装失败（双源均不可用）${Font}"
        return 1
    else
        if run_verified_script "$ohmyzsh_github_url" "$OHMYZSH_INSTALL_HASH_SOURCE_URL" "$OHMYZSH_INSTALL_SHA256_GITHUB" "OHMYZSH_INSTALL_SHA256_GITHUB" sh --unattended; then
            return 0
        fi
        echo -e "${Yellow}通过 GitHub 安装 oh-my-zsh 失败，尝试 Gitee 源...${Font}"
        if run_verified_script "$ohmyzsh_gitee_url" "$OHMYZSH_INSTALL_HASH_SOURCE_URL" "$OHMYZSH_INSTALL_SHA256_GITEE" "OHMYZSH_INSTALL_SHA256_GITEE" sh --unattended; then
            return 0
        fi
        echo -e "${Red}oh-my-zsh 安装失败（双源均不可用）${Font}"
        return 1
    fi
}

# 安装并启用常用 zsh 插件
install_zsh_plugins() {
    echo "配置 zsh 插件..."

    zshrc_file="${ZDOTDIR:-$HOME}/.zshrc"
    autosuggestions_file="/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
    syntax_highlighting_file="/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
    source_block_start="# >>> linux-alo.sh managed zsh plugin sources >>>"
    source_block_end="# <<< linux-alo.sh managed zsh plugin sources <<<"

    touch "$zshrc_file"

    # 这两个系统包不是 Oh My Zsh 插件，直接加载系统安装的脚本。
    missing_package_file=0
    if [ ! -f "$autosuggestions_file" ]; then
        echo -e "${Red}未找到 zsh-autosuggestions 的系统包文件：${autosuggestions_file}${Font}"
        missing_package_file=1
    fi
    if [ ! -f "$syntax_highlighting_file" ]; then
        echo -e "${Red}未找到 zsh-syntax-highlighting 的系统包文件：${syntax_highlighting_file}${Font}"
        missing_package_file=1
    fi
    if [ "$missing_package_file" -eq 1 ]; then
        return 1
    fi

    # 删除本脚本之前写入的 source 块，保证重复执行不会累积配置。
    if grep -qF "$source_block_start" "$zshrc_file"; then
        tmp_zshrc=$(mktemp)
        if awk -v start="$source_block_start" -v end="$source_block_end" '
            $0 == start { skipping=1; next }
            $0 == end { skipping=0; next }
            !skipping { print }
        ' "$zshrc_file" > "$tmp_zshrc"; then
            mv "$tmp_zshrc" "$zshrc_file"
        else
            rm -f "$tmp_zshrc"
            echo -e "${Yellow}清理 .zshrc 插件配置失败，保留原文件。${Font}"
        fi
    fi

    # 在任何追加操作前，修复非空 .zshrc 缺少 EOF newline 的情况。
    if [ -s "$zshrc_file" ] && [ "$(tail -c 1 "$zshrc_file" | wc -l)" -eq 0 ]; then
        printf '\n' >> "$zshrc_file"
    fi

    # 系统包不应再作为 Oh My Zsh 插件名加载，避免重复加载或找不到 .plugin.zsh。
    if [ -d "$HOME/.oh-my-zsh" ]; then
        plugins_line_new="plugins=(git)"

        if grep -qE '^[[:space:]]*plugins[[:space:]]*=[[:space:]]*\(' "$zshrc_file"; then
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
            echo "$plugins_line_new" >> "$zshrc_file"
        fi
    fi

    # autosuggestions 先加载；syntax-highlighting 必须放在最后。
    if [ -f "$autosuggestions_file" ] || [ -f "$syntax_highlighting_file" ]; then
        {
            printf '%s\n' "$source_block_start"
            if [ -f "$autosuggestions_file" ]; then
                printf 'source "%s"\n' "$autosuggestions_file"
            fi
            if [ -f "$syntax_highlighting_file" ]; then
                printf 'source "%s"\n' "$syntax_highlighting_file"
            fi
            printf '%s\n' "$source_block_end"
        } >> "$zshrc_file"
    fi

    echo -e "${Green}zsh 插件配置完成。${Font}"
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

        local tmp_file
        tmp_file=$(mktemp)
        
        local replaced=0
        local in_match=0
        
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^[[:space:]]*(Match|Match[[:space:]]) ]]; then
                in_match=1
                printf '%s\n' "$line"
                continue
            fi
            
            if [ "$in_match" -eq 0 ] && [ "$replaced" -eq 0 ]; then
                if [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+ ]]; then
                    printf '%s %s\n' "$key" "$value"
                    replaced=1
                    continue
                fi
            fi
            
            printf '%s\n' "$line"
        done < "$file_path" > "$tmp_file"
        
        mv "$tmp_file" "$file_path"
        
        if [ "$replaced" -eq 0 ]; then
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

    # 确保文件存在（避免 grep 报 No such file or directory）
    touch /etc/sysctl.conf

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

# 配置 fail2ban
configure_fail2ban() {
    echo "配置 fail2ban 防护..."

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${Red}fail2ban 未成功安装，跳过配置步骤。${Font}"
        return 0
    fi

    # 创建自定义 jail.local 配置，避免直接修改 jail.conf
    local jail_local="/etc/fail2ban/jail.local"
    if [ ! -f "$jail_local" ]; then
        echo "创建 fail2ban 本地配置文件 $jail_local..."
        cat > "$jail_local" <<'EOF'
[DEFAULT]
# 忽略的 IP 列表（防止误封本机）
ignoreip = 127.0.0.1/8 ::1
# 封禁时间：1小时
bantime = 1h
# 寻找时间窗口：10分钟
findtime = 10m
# 最大尝试次数：5次
maxretry = 5

[sshd]
enabled = true
port = ssh
EOF
        echo -e "${Green}已生成默认 jail.local 配置。${Font}"
    else
        echo -e "${Yellow}$jail_local 已存在，跳过覆盖以保留用户既有配置。${Font}"
    fi

    # 启动并使服务开机自启
    if [ -d /run/systemd/system ]; then
        echo "正在通过 systemctl 启用并启动 fail2ban 服务..."
        systemctl enable fail2ban >/dev/null 2>&1 || true
        if systemctl restart fail2ban; then
            echo -e "${Green}fail2ban 服务已成功启动并启用。${Font}"
        else
            echo -e "${Red}fail2ban 服务启动失败，请检查系统日志。${Font}"
        fi
    else
        # 针对不支持 systemd 的特殊环境（如 Docker 容器或 WSL1）
        echo -e "${Yellow}系统不支持 systemd，尝试使用 service 命令...${Font}"
        if service fail2ban restart >/dev/null 2>&1 || /etc/init.d/fail2ban restart >/dev/null 2>&1; then
            echo -e "${Green}fail2ban 服务已尝试启动。${Font}"
        else
            echo -e "${Yellow}无法通过传统 init/service 启动 fail2ban，请手动检查服务状态。${Font}"
        fi
    fi
}

# 辅助函数：检测是否以 systemd 启动（支持通过 SYSTEMD_MODE_OVERRIDE 环境变量进行沙箱测试）
is_systemd_booted() {
    case "${SYSTEMD_MODE_OVERRIDE:-auto}" in
        1) return 0 ;;
        0) return 1 ;;
        *) [ -d /run/systemd/system ] ;;
    esac
}

# 辅助函数：启动并验证 NTP 服务状态
start_and_verify_ntp_service() {
    local service_name="$1"
    local process_name="${2:-$service_name}"
    local init_d_dir="${INIT_D_DIR:-/etc/init.d}"

    if is_systemd_booted; then
        systemctl enable --now "$service_name" >/dev/null 2>&1 || systemctl start "$service_name" >/dev/null 2>&1 || true
        if command -v timedatectl >/dev/null 2>&1; then
            timedatectl set-ntp true >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            return 0
        fi
    else
        service "$service_name" restart >/dev/null 2>&1 || "$init_d_dir/$service_name" restart >/dev/null 2>&1 || true
        if service "$service_name" status >/dev/null 2>&1 || pgrep -x "$process_name" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# 配置 NTP 时间同步服务
setup_ntp() {
    echo "检查 NTP 时间同步状态..."

    local found_service=""
    local proc_name=""
    local ntp_services=("chrony" "chronyd" "systemd-timesyncd" "openntpd" "ntpsec" "ntp")
    local is_systemd=0
    if is_systemd_booted; then
        is_systemd=1
    fi

    # 1. 检查是否有正在运行的 NTP 服务（优先级：chrony -> timesyncd -> openntpd -> ntpsec -> ntp）
    if [ "$is_systemd" -eq 1 ]; then
        for s in "${ntp_services[@]}"; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                found_service="$s"
                echo -e "${Green}检测到 NTP 服务正在运行 (${found_service})，跳过安装。${Font}"
                return 0
            fi
        done
    fi

    # 2. 检查守护进程是否在运行（覆盖非 systemd 容器或环境）
    if pgrep -x chronyd >/dev/null 2>&1; then
        echo -e "${Green}检测到 chronyd 进程正在运行，跳过安装。${Font}"
        return 0
    elif pgrep -x systemd-timesyn >/dev/null 2>&1; then
        echo -e "${Green}检测到 systemd-timesyncd 进程正在运行，跳过安装。${Font}"
        return 0
    elif pgrep -x openntpd >/dev/null 2>&1; then
        echo -e "${Green}检测到 openntpd 进程正在运行，跳过安装。${Font}"
        return 0
    elif pgrep -x ntpd >/dev/null 2>&1; then
        echo -e "${Green}检测到 ntpd 进程正在运行，跳过安装。${Font}"
        return 0
    fi

    # 3. 检查系统中是否已安装相关 NTP 软件包/服务单元（未处于运行态）
    if [ "$is_systemd" -eq 1 ]; then
        # systemd 环境：依据 unit 文件及特异性 binary 判型
        if systemctl list-unit-files chrony.service --no-legend 2>/dev/null | grep -q '^chrony\.service' || command -v chronyd >/dev/null 2>&1; then
            found_service="chrony"
            proc_name="chronyd"
        elif systemctl list-unit-files systemd-timesyncd.service --no-legend 2>/dev/null | grep -q '^systemd-timesyncd\.service' || [ -x /lib/systemd/systemd-timesyncd ] || [ -x /usr/lib/systemd/systemd-timesyncd ]; then
            found_service="systemd-timesyncd"
            proc_name="systemd-timesyncd"
        elif systemctl list-unit-files openntpd.service --no-legend 2>/dev/null | grep -q '^openntpd\.service' || command -v openntpd >/dev/null 2>&1; then
            found_service="openntpd"
            proc_name="openntpd"
        elif systemctl list-unit-files ntpsec.service --no-legend 2>/dev/null | grep -q '^ntpsec\.service'; then
            found_service="ntpsec"
            proc_name="ntpd"
        elif systemctl list-unit-files ntp.service --no-legend 2>/dev/null | grep -q '^ntp\.service'; then
            found_service="ntp"
            proc_name="ntpd"
        fi
    else
        # 非 systemd 环境：依据 SysV init 脚本及特异性 binary 判型，绝不以裸 ntpd 混淆 ntpsec 与 ntp
        local init_d_dir="${INIT_D_DIR:-/etc/init.d}"
        if [ -x "$init_d_dir/chrony" ] || command -v chronyd >/dev/null 2>&1; then
            found_service="chrony"
            proc_name="chronyd"
        elif [ -x "$init_d_dir/openntpd" ] || command -v openntpd >/dev/null 2>&1; then
            found_service="openntpd"
            proc_name="openntpd"
        elif [ -x "$init_d_dir/ntpsec" ]; then
            found_service="ntpsec"
            proc_name="ntpd"
        elif [ -x "$init_d_dir/ntp" ]; then
            found_service="ntp"
            proc_name="ntpd"
        fi
    fi

    if [ -n "$found_service" ]; then
        echo -e "${Yellow}检测到已安装 NTP 组件 (${found_service})，正在启用并启动服务...${Font}"
        if start_and_verify_ntp_service "$found_service" "$proc_name"; then
            echo -e "${Green}${found_service} 已成功启动，跳过重复安装。${Font}"
            return 0
        else
            echo -e "${Red}${found_service} 已安装，但启动或状态核验失败。${Font}"
            return 1
        fi
    fi

    # 4. 检查 timedatectl 机器可读属性（NTPSynchronized=yes）
    if command -v timedatectl >/dev/null 2>&1; then
        local sync_status
        sync_status=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
        if [ "$sync_status" = "yes" ]; then
            echo -e "${Green}检测到系统时钟已通过 NTP 同步 (NTPSynchronized=yes)，跳过安装。${Font}"
            return 0
        fi
    fi

    # 5. 系统未检测到任何 NTP 服务，执行安装与核验
    echo "未检测到可用的 NTP 服务，正在安装 chrony..."
    if apt-get install -y chrony; then
        if start_and_verify_ntp_service "chrony" "chronyd"; then
            echo -e "${Green}chrony 安装并启动成功，已启用网络时间同步。${Font}"
            return 0
        else
            echo -e "${Yellow}chrony 软件包已安装，但启动核验失败。${Font}"
        fi
    else
        echo -e "${Yellow}chrony 安装失败。${Font}"
    fi

    # 仅在 systemd 环境下尝试回退安装 systemd-timesyncd（timesyncd 强依赖 systemd）
    if [ "$is_systemd" -eq 1 ]; then
        echo "正在回退安装 systemd-timesyncd..."
        if apt-get install -y systemd-timesyncd; then
            if start_and_verify_ntp_service "systemd-timesyncd" "systemd-timesyncd"; then
                echo -e "${Green}systemd-timesyncd 安装并启动成功。${Font}"
                return 0
            else
                echo -e "${Red}systemd-timesyncd 软件包已安装，但启动核验失败。${Font}"
                return 1
            fi
        else
            echo -e "${Red}systemd-timesyncd 安装失败，所有 NTP 服务均不可用。${Font}"
            return 1
        fi
    else
        echo -e "${Red}非 systemd 环境不支持回退到 systemd-timesyncd，NTP 服务配置失败。${Font}"
        return 1
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
    apt-get install -y git wget vim nano zsh zsh-autosuggestions zsh-syntax-highlighting curl tar zip unzip sudo ca-certificates fail2ban

    # 配置 NTP 时间同步
    setup_ntp

    # 设置 Zsh 为默认终端
    echo "设置 Zsh 为默认终端..."
    chsh -s "$(command -v zsh)" || echo -e "${Yellow}更改默认 shell 失败，请手动执行 chsh 命令.${Font}"

    # 安装 oh-my-zsh
    install_oh_my_zsh

    # 安装 Starship
    install_starship

    # 配置 Starship
    configure_starship

    # 安装并启用 zsh 插件
    install_zsh_plugins

    # 修改 SSH 配置
    configure_ssh

    # 配置 fail2ban 防护
    configure_fail2ban

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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main
fi
