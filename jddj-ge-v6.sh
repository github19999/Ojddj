#!/bin/bash
# ================================================================
#   服务器一键管理脚本 (jddj)
#   版本号：jddj-ge-v6
#   集成：SSH安全加固 / SSL证书 / sing-box 安装配置 / 节点生成
# ================================================================
# 【本次优化内容 (jddj-ge-v6)】
#   1. 【优化1】sing-box 稳定版安装方式菜单，将默认选项由 (默认 1) 改为 (默认 0)。
#   2. 【优化2】重排主菜单 UI 界面，采用精美的双线边框并严格对其，版本号更新为 jddj-ge-v6。
#   3. 【修复快捷命令】采用 vpsbox 工业级安装逻辑，将快捷命令安装到 /usr/bin/jddj，
#      彻底解决 -bash: jddj: command not found (系统不识别 /usr/local/bin) 的问题。
#   4. 【加入强退保护】加入了 Ctrl+C (SIGINT) 的捕获，强退也能优雅返回并提示快捷命令。
# ================================================================

# 捕获 Ctrl+C 信号，优雅退出终端
trap 'echo -e "\n${RED}已取消操作，退出脚本。${NC}\n提示：随时可以输入快捷命令 ${BOLD}${GREEN}jddj${NC} 重新进入主菜单。"; exit 0' INT

# 遇到严重错误立即退出
set -e  

# ────────────────────────────────────────────────────────────────
#  颜色 & 日志
# ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_VERSION="jddj-ge-v6"
STOPPED_SERVICES=()
DOMAINS=()
MAIN_DOMAIN=""
CERT_DIR=""
OS=""
INSTALL_CMD=""
UPDATE_CMD=""
AUTO_DEFAULT=false # 用于控制是否开启静默默认模式

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }

press_enter() { echo ""; read -rp "$(echo -e "${CYAN}按 Enter 返回...${NC}")"; }

# ────────────────────────────────────────────────────────────────
#  Root 检查
# ────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行，请使用 sudo 或切换到 root 用户"
        exit 1
    fi
}

# ────────────────────────────────────────────────────────────────
#  安装 jddj 快捷命令 (vpsbox 级双重保险机制)
# ────────────────────────────────────────────────────────────────
JDDJ_REMOTE_URL="https://raw.githubusercontent.com/github19999/Ojddj/main/jddj.sh"

install_shortcut() {
    local target="/usr/bin/jddj"
    
    # 避免在目标路径下运行时陷入死循环
    if [[ "$(realpath "$0" 2>/dev/null || echo "$0")" == "$target" ]]; then
        chmod +x "$target" 2>/dev/null || true
        return
    fi

    # 临时关闭 set -e，确保即使网络波动报错也能继续往下走
    set +e 

    mkdir -p /usr/bin

    # 核心判断：是本地文件执行，还是 curl 管道执行？
    if [[ -f "$0" && "$0" != *"bash"* && "$0" != *"/dev/fd/"* ]]; then
        # 本地实体文件运行，直接原封不动复制到 /usr/bin
        cp -f "$0" "$target" 2>/dev/null || true
    else
        # 管道流运行，通过 URL 拉取 (请确保 GitHub 上是最新的)
        if command -v curl >/dev/null 2>&1; then
            curl -sL "$JDDJ_REMOTE_URL" -o "$target" 2>/dev/null || true
        else
            wget -qO "$target" "$JDDJ_REMOTE_URL" 2>/dev/null || true
        fi
    fi

    # 赋予最高执行权限
    if [[ -f "$target" ]]; then
        chmod +x "$target" 2>/dev/null || true
        chmod 755 "$target" 2>/dev/null || true
    fi

    # 写入系统变量，彻底解决个别精简系统路径缺失问题
    if ! grep -q "alias jddj=" ~/.bashrc 2>/dev/null; then
        echo "alias jddj='$target'" >> ~/.bashrc 2>/dev/null || true
    fi

    # 刷新当前 shell 哈希缓存，使其立刻生效
    hash -r 2>/dev/null || true
    
    set -e # 恢复严格模式
}

# ────────────────────────────────────────────────────────────────
#  发行版检测
# ────────────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID%%.*}"
        PRETTY_NAME_CACHED="${PRETTY_NAME:-$DISTRO_ID}"
    else
        log_error "无法识别操作系统"
        exit 1
    fi

    case "$DISTRO_ID" in
        ubuntu|debian|raspbian) PKG_MANAGER="apt" ;;
        centos|rhel|almalinux|rocky|fedora)
            PKG_MANAGER="yum"
            command -v dnf &>/dev/null && PKG_MANAGER="dnf"
            ;;
        *) log_warn "未经测试的发行版: $DISTRO_ID，尝试使用 apt"; PKG_MANAGER="apt" ;;
    esac
}

# ────────────────────────────────────────────────────────────────
#  随机生成工具函数
# ────────────────────────────────────────────────────────────────
gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

gen_password() {
    local length="${1:-24}"
    tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c "$length" 2>/dev/null || \
    python3 -c "import secrets,string; print(secrets.token_urlsafe($length))"
}

gen_ss2022_key_256() { openssl rand -base64 32; }
gen_ss2022_key_128() { openssl rand -base64 16; }

gen_reality_keypair() {
    if command -v sing-box &>/dev/null; then
        sing-box generate reality-keypair 2>/dev/null
    else
        local privkey pubkey
        privkey=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
        pubkey=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
        echo "PrivateKey: ${privkey}"
        echo "PublicKey:  ${pubkey}"
    fi
}

gen_short_id() { openssl rand -hex 4; }

gen_naive_username() {
    tr -dc 'a-z0-9' </dev/urandom | head -c 12 2>/dev/null || echo "naiveuser$(shuf -i 1000-9999 -n1)"
}

# ────────────────────────────────────────────────────────────────
#  通用输入函数
# ────────────────────────────────────────────────────────────────
ask_val() {
    local varname="$1"
    local label="$2"
    local default="$3"
    local input result

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        result="$default"
        echo -e "  ${GREEN}✓ [自动] ${label} = ${result}${NC}"
        printf -v "$varname" '%s' "$result"
        return
    fi

    echo -e "  ${CYAN}◆ ${label}${NC}  (默认: ${YELLOW}${default}${NC}，回车确认)"
    read -rp "  > " input
    result="${input:-$default}"
    echo -e "  ${GREEN}✓ ${label} = ${result}${NC}"
    echo ""
    printf -v "$varname" '%s' "$result"
}

ask_random() {
    local varname="$1"
    local label="$2"
    local randval="$3"
    local input result

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        result="$randval"
        echo -e "  ${GREEN}✓ [自动] ${label} = ${result}${NC}"
        printf -v "$varname" '%s' "$result"
        return
    fi

    echo -e "  ${CYAN}◆ ${label}${NC}"
    echo -e "    随机生成值: ${YELLOW}${randval}${NC}"
    echo -e "    (回车使用随机值，或输入自定义值覆盖)"
    read -rp "  > " input
    result="${input:-$randval}"
    echo -e "  ${GREEN}✓ ${label} = ${result}${NC}"
    echo ""
    printf -v "$varname" '%s' "$result"
}

ask() {
    local prompt="$1" default="$2"
    ask_val REPLY_VAL "$prompt" "$default"
}

# ────────────────────────────────────────────────────────────────
#  读取已安装证书域名
# ────────────────────────────────────────────────────────────────
get_cert_domains() {
    local domains=()

    if [[ -d /root/.acme.sh ]]; then
        while IFS= read -r dir; do
            local d
            d=$(basename "$dir")
            [[ -z "$d" || "$d" == "__INTERACT__" || "$d" == "ca" || "$d" == "account.conf" ]] && continue
            [[ "$d" == *_ecc ]] && continue
            [[ ! -d "$dir" ]] && continue

            domains+=("$d")

            local conf_file="$dir/${d}.conf"
            if [[ -f "$conf_file" ]]; then
                local le_alt
                le_alt=$(grep -oP "(?<=Le_Alt=')[^']+" "$conf_file" 2>/dev/null || true)
                if [[ -n "$le_alt" ]]; then
                    while IFS=, read -ra alt_list; do
                        for alt in "${alt_list[@]}"; do
                            alt="${alt// /}"
                            [[ -n "$alt" && "$alt" == *.* ]] && domains+=("$alt")
                        done
                    done <<< "$le_alt"
                fi
            fi

            local cert_file="$dir/fullchain.cer"
            [[ ! -f "$cert_file" ]] && cert_file="$dir/${d}.cer"
            if [[ -f "$cert_file" ]]; then
                while IFS= read -r san; do
                    san="${san#DNS:}"
                    san="${san// /}"
                    [[ -n "$san" && "$san" == *.* && "$san" != *\** ]] && domains+=("$san")
                done < <(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -oP "DNS:[^,\s]+" | tr ',' '\n')
            fi

        done < <(find /root/.acme.sh -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    while IFS= read -r crt; do
        [[ -z "$crt" ]] && continue
        local cn
        cn=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | grep -oP '(?<=CN\s=\s)[^,/]+' | head -1)
        [[ -n "$cn" && "$cn" == *.* ]] && domains+=("$cn")
        while IFS= read -r san; do
            san="${san#DNS:}"
            san="${san// /}"
            [[ -n "$san" && "$san" == *.* && "$san" != *\** ]] && domains+=("$san")
        done < <(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oP "DNS:[^,\s]+" | tr ',' '\n')
    done < <(find /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl 2>/dev/null \
        \( -name "*.crt" -o -name "fullchain.cer" -o -name "*.pem" \) | head -30)

    printf '%s\n' "${domains[@]}" | sort -u | grep -v '^\*' | grep '\.' | grep -v ' ' || true
}

# ────────────────────────────────────────────────────────────────
#  选择 server_name
# ────────────────────────────────────────────────────────────────
select_server_name() {
    local default_sn="${1:-example.com}"
    echo ""
    echo -e "  ${CYAN}◆ server_name（域名/伪装域名）${NC}"

    local domains=()
    mapfile -t domains < <(get_cert_domains 2>/dev/null)

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        if [[ ${#domains[@]} -gt 0 ]]; then
            SELECTED_SN="${domains[0]}"
        else
            SELECTED_SN="${default_sn}"
        fi
        echo -e "  ${GREEN}✓ [自动] server_name = ${SELECTED_SN}${NC}"
        echo ""
        return
    fi

    if [[ ${#domains[@]} -gt 0 ]]; then
        echo -e "    检测到已安装证书，请选择："
        for i in "${!domains[@]}"; do
            echo -e "    ${YELLOW}$((i+1)))${NC} ${domains[$i]}"
        done
        local manual_idx=$(( ${#domains[@]} + 1 ))
        echo -e "    ${YELLOW}${manual_idx})${NC} 手动输入"
        echo ""
        local sn_choice
        read -rp "  > (编号，默认 1): " sn_choice
        sn_choice="${sn_choice:-1}"

        if [[ "$sn_choice" =~ ^[0-9]+$ ]] && \
           [[ "$sn_choice" -ge 1 ]] && \
           [[ "$sn_choice" -le "${#domains[@]}" ]]; then
            SELECTED_SN="${domains[$((sn_choice-1))]}"
        else
            read -rp "  > 手动输入 server_name (默认 ${default_sn}): " SELECTED_SN
            SELECTED_SN="${SELECTED_SN:-$default_sn}"
        fi
    else
        echo -e "    （未检测到已安装证书，请手动输入）"
        read -rp "  > server_name (默认 ${default_sn}): " SELECTED_SN
        SELECTED_SN="${SELECTED_SN:-$default_sn}"
    fi

    echo -e "  ${GREEN}✓ server_name = ${SELECTED_SN}${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────────
#  自动定位证书路径
# ────────────────────────────────────────────────────────────────
ask_cert_paths() {
    local sn="$1"
    local auto_cert="" auto_key=""

    for d in /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/${sn}.crt"           ]] && auto_cert="$d/${sn}.crt"           && break
        [[ -f "$d/fullchain.cer"       ]] && auto_cert="$d/fullchain.cer"       && break
        [[ -f "$d/${sn}/fullchain.cer" ]] && auto_cert="$d/${sn}/fullchain.cer" && break
    done
    for d in /etc/ssl/private /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/${sn}.key"   ]] && auto_key="$d/${sn}.key"   && break
        [[ -f "$d/private.key" ]] && auto_key="$d/private.key" && break
    done
    [[ -z "$auto_cert" && -f "/root/.acme.sh/${sn}/fullchain.cer" ]] && auto_cert="/root/.acme.sh/${sn}/fullchain.cer"
    [[ -z "$auto_key"  && -f "/root/.acme.sh/${sn}/${sn}.key"     ]] && auto_key="/root/.acme.sh/${sn}/${sn}.key"

    local default_cert="${auto_cert:-/etc/ssl/private/fullchain.cer}"
    local default_key="${auto_key:-/etc/ssl/private/private.key}"

    ask_val CERT_PATH "cert_path（证书文件）" "$default_cert"
    ask_val KEY_PATH  "key_path（私钥文件）"  "$default_key"
}

# ────────────────────────────────────────────────────────────────
#  一、基础安全设置
# ────────────────────────────────────────────────────────────────
bootstrap_packages() {
    log_step "预装基础组件"
    if command -v apt &>/dev/null; then
        apt update -y && apt install -y curl sudo wget git unzip nano vim openssl
    elif command -v dnf &>/dev/null; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y curl sudo wget git unzip nano vim openssl
    elif command -v yum &>/dev/null; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl sudo wget git unzip nano vim openssl
    fi
    log_success "基础组件已就绪"
}

setup_ssh_key() {
    echo ""
    log_step "配置 SSH 密钥登录"
    echo "请输入你的 SSH 公钥（以 ssh-rsa / ssh-ed25519 / ecdsa-sha2 开头）:"
    read -r PUBLIC_KEY

    if [[ -z "$PUBLIC_KEY" ]]; then
        log_error "公钥不能为空"; return 1
    fi
    if [[ ! "$PUBLIC_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519) ]]; then
        log_warn "公钥格式可能不正确，但继续执行..."
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    chown root:root /root/.ssh

    if ! grep -qF "$PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
        log_success "公钥已添加"
    else
        log_info "公钥已存在，跳过"
    fi

    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys

    command -v restorecon &>/dev/null && restorecon -Rv /root/.ssh/ >/dev/null 2>&1 && log_info "SELinux 上下文已修复"
    log_success "SSH 密钥登录配置完成"
}

disable_password_login() {
    log_step "禁用 SSH 密码登录"
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

    sshd_set() {
        local key="$1" val="$2"
        if grep -qE "^#?\s*${key}\s" "$SSHD_CONFIG"; then
            sed -i "s|^#\?\s*${key}\s.*|${key} ${val}|" "$SSHD_CONFIG"
        else
            echo "${key} ${val}" >> "$SSHD_CONFIG"
        fi
    }

    sshd_set "PasswordAuthentication" "no"
    sshd_set "ChallengeResponseAuthentication" "no"
    sshd_set "KbdInteractiveAuthentication" "no"
    sshd_set "PubkeyAuthentication" "yes"
    sshd_set "AuthorizedKeysFile" ".ssh/authorized_keys"
    sshd_set "PermitRootLogin" "prohibit-password"

    if sshd -t 2>&1; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        log_success "SSH 密码登录已禁用"
    else
        log_error "SSH 配置语法错误，请检查配置文件"
    fi
}

change_ssh_port() {
    log_step "修改 SSH 端口"
    local current_port
    current_port=$(grep -E "^Port\s" /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    current_port="${current_port:-22}"
    echo "当前 SSH 端口: $current_port"
    echo -n "请输入新端口（1024-65535，默认 43916）: "
    read -r SSH_PORT
    [[ -z "$SSH_PORT" ]] && SSH_PORT=43916

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ $SSH_PORT -lt 1024 || $SSH_PORT -gt 65535 ]]; then
        log_error "端口范围应在 1024-65535"; return 1
    fi

    local SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    sed -i 's/^Port\s/#Port /' "$SSHD_CONFIG"
    grep -q "^Port $SSH_PORT" "$SSHD_CONFIG" || echo "Port $SSH_PORT" >> "$SSHD_CONFIG"

    if sshd -t 2>&1; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        log_success "SSH 端口已修改为: $SSH_PORT"
        log_warn "⚠  请确保防火墙已放行端口 $SSH_PORT"
    else
        log_error "SSH 配置语法错误，已还原备份"
    fi
}

enable_bbr() {
    log_step "启用 BBR 拥塞控制"
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        log_success "BBR 已启用，跳过"; return
    fi

    local kv
    kv=$(uname -r | cut -d. -f1-2 | tr -d '.')
    if [[ "$kv" -lt 49 ]] 2>/dev/null; then
        log_warn "内核版本低于 4.9，BBR 不受支持"; return
    fi

    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    log_success "BBR 启用成功"
}

configure_ip_protocol() {
    echo ""
    echo -e "${CYAN}── IP 协议优先级 ──${NC}"
    echo "1) IPv4 优先 [默认]"
    echo "2) IPv6 优先"
    echo "3) 保持不变"
    read -rp "请选择 (1-3): " c; c=${c:-1}
    case $c in
        1)
            if [[ -f /etc/gai.conf ]]; then
                cp /etc/gai.conf "/etc/gai.conf.backup.$(date +%Y%m%d_%H%M%S)"
                if grep -q "^#\s*precedence ::ffff:0:0/96" /etc/gai.conf; then
                    sed -i 's/^#\s*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
                elif ! grep -q "^precedence ::ffff:0:0/96" /etc/gai.conf; then
                    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
                fi
                log_success "IPv4 优先已设置"
            fi ;;
        2)
            [[ -f /etc/gai.conf ]] && sed -i 's/^precedence ::ffff:0:0\/96/#precedence ::ffff:0:0\/96/' /etc/gai.conf
            log_success "IPv6 优先已设置" ;;
        3) log_info "IP 协议优先级保持不变" ;;
    esac

    echo ""
    echo -e "${CYAN}── IP 协议禁用 ──${NC}"
    echo "1) 禁用 IPv6"
    echo "2) 禁用 IPv4（危险操作）"
    echo "3) 保持不变 [默认]"
    read -rp "请选择 (1-3): " d; d=${d:-3}
    local SYSCTL_D="/etc/sysctl.d"; mkdir -p "$SYSCTL_D"
    case $d in
        1)
            local f="$SYSCTL_D/99-disable-ipv6.conf"
            [[ ! -f "$f" ]] && cat > "$f" << 'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
            sysctl -p "$f" >/dev/null 2>&1
            log_success "IPv6 已禁用" ;;
        2)
            log_warn "警告：禁用 IPv4 可能导致服务器断联！"
            read -rp "确认禁用 IPv4？(y/N): " confirm
            if [[ "${confirm,,}" == "y" ]]; then
                cat > "$SYSCTL_D/99-disable-ipv4.conf" << 'EOF'
net.ipv4.conf.all.disable_ipv4=1
net.ipv4.conf.default.disable_ipv4=1
EOF
                log_warn "IPv4 禁用配置已写入，重启后生效"
            else
                log_info "已取消"
            fi ;;
        3) log_info "IP 协议状态保持不变" ;;
    esac
}

setup_fail2ban() {
    log_step "安装并配置 fail2ban"
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt install -y fail2ban || { log_warn "fail2ban 安装失败"; return; }
    else
        $PKG_MANAGER install -y fail2ban || { log_warn "fail2ban 安装失败"; return; }
    fi

    local SSH_PORT_CURRENT
    SSH_PORT_CURRENT=$(grep -E "^Port\s" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    SSH_PORT_CURRENT="${SSH_PORT_CURRENT:-22}"

    local BACKEND LOGPATH=""
    if systemctl is-active --quiet systemd-journald 2>/dev/null; then
        BACKEND="systemd"
    else
        BACKEND="auto"
        for lp in /var/log/auth.log /var/log/secure; do
            [[ -f "$lp" ]] && LOGPATH="logpath = $lp" && break
        done
        [[ -z "$LOGPATH" ]] && LOGPATH="logpath = /var/log/auth.log"
    fi

    systemctl stop fail2ban 2>/dev/null || true
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = -1
findtime = 300
maxretry = 1

[sshd]
enabled  = true
port     = $SSH_PORT_CURRENT
backend  = $BACKEND
${LOGPATH}
maxretry = 1
findtime = 300
bantime  = -1
EOF
    sleep 1
    systemctl enable fail2ban && systemctl start fail2ban
    systemctl is-active --quiet fail2ban && log_success "fail2ban 启动成功" || log_warn "fail2ban 启动失败，请检查日志"
}

menu_basic() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 一、基础安全设置 ══${NC}"
        echo ""
        echo "  1) SSH 密钥登录"
        echo "  2) 禁用密码登录"
        echo "  3) 修改 SSH 端口"
        echo "  4) 启用 BBR 拥塞控制"
        echo "  5) IP 协议优先级 & 禁用"
        echo "  6) 安装配置 fail2ban"
        echo "  7) 全部执行 (1→6)"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择: " opt
        case $opt in
            1) setup_ssh_key; press_enter ;;
            2) disable_password_login; press_enter ;;
            3) change_ssh_port; press_enter ;;
            4) enable_bbr; press_enter ;;
            5) configure_ip_protocol; press_enter ;;
            6) setup_fail2ban; press_enter ;;
            7)
                bootstrap_packages
                setup_ssh_key
                disable_password_login
                change_ssh_port
                enable_bbr
                configure_ip_protocol
                setup_fail2ban
                press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  二、SSL 证书
# ────────────────────────────────────────────────────────────────
STOPPED_SERVICES_SSL=()

manage_web_services_ssl() {
    local action="$1"
    if [[ "$action" == "stop" ]]; then
        local port_info=""
        command -v ss &>/dev/null && port_info=$(ss -tlnp | grep ":80 " 2>/dev/null) || true
        command -v netstat &>/dev/null && [[ -z "$port_info" ]] && port_info=$(netstat -tlnp | grep ":80 " 2>/dev/null) || true
        if [[ -n "$port_info" ]]; then
            for svc in nginx apache2 httpd lighttpd caddy; do
                systemctl is-active --quiet "$svc" 2>/dev/null && {
                    systemctl stop "$svc" && STOPPED_SERVICES_SSL+=("$svc") && log_info "已停止: $svc"
                }
            done
        fi
    elif [[ "$action" == "start" ]]; then
        for svc in "${STOPPED_SERVICES_SSL[@]:-}"; do
            [[ -n "$svc" ]] && systemctl start "$svc" 2>/dev/null && log_info "已启动: $svc"
        done
        STOPPED_SERVICES_SSL=()
    fi
}

open_firewall_ports() {
    log_step "检查并自动放行本地防火墙端口 (80/443)..."
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log_info "检测到 UFW 防火墙处于开启状态，正在放行端口..."
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1
        log_success "UFW 防火墙放行成功"
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        log_info "检测到 Firewalld 防火墙处于开启状态，正在放行端口..."
        firewall-cmd --zone=public --add-port=80/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port=443/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1
        log_success "Firewalld 防火墙放行成功"
    fi
}

deploy_ssl() {
    log_step "SSL 证书申请与安装"

    log_info "安装必要依赖..."
    local packages=""
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        packages="curl wget socat cron openssl ca-certificates git dnsutils"
    else
        packages="curl wget socat cronie openssl ca-certificates git bind-utils"
    fi
    $PKG_MANAGER install -y $packages >/dev/null 2>&1 || true

    local cron_svc="cron"
    [[ "$PKG_MANAGER" != "apt" ]] && cron_svc="crond"
    systemctl enable "$cron_svc" >/dev/null 2>&1 || true
    systemctl start  "$cron_svc" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$cron_svc" 2>/dev/null; then
        log_success "cron 服务已运行"
    else
        log_warn "cron 服务未能启动，自动续期 crontab 将在证书安装后手动补充"
    fi

    echo ""
    echo -e "${CYAN}请配置要申请SSL证书的域名:${NC}"
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  • 支持单个或多个域名"
    echo "  • 多个域名请用空格分隔"
    echo "  • 确保域名已正确解析到本服务器"
    echo "  • 示例: example.com www.example.com"
    echo ""

    local DOMAINS=()
    local MAIN_DOMAIN=""
    
    while true; do
        read -rp "请输入域名: " DOMAINS_INPUT
        if [[ -z "$DOMAINS_INPUT" ]]; then
            log_error "域名不能为空，请重新输入"
            continue
        fi

        read -ra DOMAINS <<< "$DOMAINS_INPUT"

        for domain in "${DOMAINS[@]}"; do
            if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
                log_warn "域名格式可能不正确: $domain"
            fi
            echo -n "检查域名解析: $domain ... "
            if nslookup "$domain" >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${YELLOW}!${NC} (解析失败，但将继续)"
            fi
        done

        MAIN_DOMAIN=${DOMAINS[0]}

        echo ""
        echo -e "${GREEN}域名配置:${NC}"
        echo "  主域名: $MAIN_DOMAIN"
        echo "  所有域名: ${DOMAINS[*]}"
        echo "  域名数量: ${#DOMAINS[@]}"
        echo ""

        echo -e "确认域名配置正确? :"
        echo "  1) Y/y [默认]"
        echo "  2) N/n"
        read -rp "请选择 (1-2) [默认 1]: " confirm_choice
        confirm_choice=${confirm_choice:-1}
        if [[ "$confirm_choice" == "1" || "${confirm_choice,,}" == "y" ]]; then
            break
        fi
        echo ""
    done

    echo ""
    echo -e "${CYAN}请选择证书安装位置:${NC}"
    echo "  1) 标准路径 (/etc/ssl/private/) [默认]"
    echo "  2) Nginx专用 (/etc/nginx/ssl/)"
    echo "  3) Apache专用 (/etc/apache2/ssl/)"
    echo "  4) 用户目录 (/home/ssl/)"
    echo "  5) 自定义路径"
    echo ""
    
    local CERT_DIR=""
    while true; do
        read -rp "请选择 (1-5) [默认 1]: " path_choice
        path_choice=${path_choice:-1}
        case $path_choice in
            1) CERT_DIR="/etc/ssl/private"; break ;;
            2) CERT_DIR="/etc/nginx/ssl"; break ;;
            3) CERT_DIR="/etc/apache2/ssl"; break ;;
            4) CERT_DIR="/home/ssl"; break ;;
            5)
                while true; do
                    read -rp "请输入自定义路径: " custom_path
                    if [[ -n "$custom_path" ]]; then
                        CERT_DIR="$custom_path"
                        break
                    else
                        log_warn "路径不能为空，请重新输入"
                    fi
                done
                break
                ;;
            *) log_warn "无效选择，请输入 1-5"; continue ;;
        esac
    done
    mkdir -p "$CERT_DIR" && chmod 755 "$CERT_DIR"

    if [[ ! -f /root/.acme.sh/acme.sh ]]; then
        log_step "安装 acme.sh..."
        rm -rf /tmp/acme_sh_install
        if git clone https://github.com/acmesh-official/acme.sh.git /tmp/acme_sh_install >/dev/null 2>&1; then
            cd /tmp/acme_sh_install || return 1
            ./acme.sh --install --force >/dev/null 2>&1
            cd - >/dev/null || true
            rm -rf /tmp/acme_sh_install
        else
            local _acme_tar="/tmp/acme.tar.gz"
            if curl -fsSL https://github.com/acmesh-official/acme.sh/archive/master.tar.gz -o "$_acme_tar" 2>/dev/null || \
               wget -qO "$_acme_tar" https://github.com/acmesh-official/acme.sh/archive/master.tar.gz 2>/dev/null; then
                tar -xzf "$_acme_tar" -C /tmp/
                cd /tmp/acme.sh-master || return 1
                ./acme.sh --install --force >/dev/null 2>&1
                cd - >/dev/null || true
                rm -rf /tmp/acme.sh-master "$_acme_tar"
            else
                log_error "acme.sh 源码下载失败，请检查网络"
                return 1
            fi
        fi

        if [[ ! -f /root/.acme.sh/acme.sh ]]; then
            log_error "acme.sh 安装失败，未找到 /root/.acme.sh/acme.sh"
            return 1
        fi
    else
        log_info "acme.sh 已存在，检查更新..."
        /root/.acme.sh/acme.sh --upgrade >/dev/null 2>&1 || true
    fi

    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null || true
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    log_success "acme.sh 已就绪"

    manage_web_services_ssl "stop"
    open_firewall_ports

    log_step "申请证书（Standalone 模式）..."
    local domain_args=""
    for d in "${DOMAINS[@]}"; do domain_args="$domain_args -d $d"; done

    echo "正在申请证书，请耐心等待..."
    if /root/.acme.sh/acme.sh --issue $domain_args --standalone --force; then
        log_success "SSL 证书申请成功"
    else
        log_error "SSL 证书申请失败"
        echo -e "${YELLOW}可能的原因:${NC}"
        echo "  • 防火墙/云服务商安全组阻止了外网对 80 端口的访问 (Timeout)"
        echo "  • 域名未正确解析到本服务器的公网 IP"
        echo "  • Let's Encrypt 服务暂时不可用"
        echo -e "${PURPLE}【重要提示】如果您的 VPS (如 YXVM、Oracle 等) 存在外部控制台安全组，请务必登录控制台手动放行 80/443 端口！${NC}"
        manage_web_services_ssl "start"
        return 1
    fi

    log_step "安装SSL证书到指定目录..."
    local KEY_FILE="$CERT_DIR/private.key"
    local CERT_FILE="$CERT_DIR/fullchain.cer"
    local CA_FILE="$CERT_DIR/ca.cer"

    local DETECTED_SVC="" PRE_HOOK="" POST_HOOK=""
    local RELOAD_CMD="echo 'Certificate installed'"

    for svc in nginx apache2 httpd lighttpd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            DETECTED_SVC="$svc"
            PRE_HOOK="systemctl stop $svc"
            POST_HOOK="systemctl start $svc"
            RELOAD_CMD="systemctl reload $svc"
            log_info "检测到 Web 服务: $svc，将配置自动续期 Hook"
            break
        fi
    done

    if /root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --key-file  "$KEY_FILE"  \
        --fullchain-file "$CERT_FILE" \
        --ca-file   "$CA_FILE"   \
        --reloadcmd "$RELOAD_CMD"; then
        
        chmod 600 "$KEY_FILE"  2>/dev/null || true
        chmod 644 "$CERT_FILE" "$CA_FILE" 2>/dev/null || true
        chown root:root "$KEY_FILE" "$CERT_FILE" "$CA_FILE" 2>/dev/null || true
        log_success "证书已成功安装至: $CERT_DIR"
    else
        log_error "证书安装失败"
        manage_web_services_ssl "start"
        return 1
    fi

    if [[ -n "$PRE_HOOK" ]]; then
        local CONF_FILE="/root/.acme.sh/${MAIN_DOMAIN}/${MAIN_DOMAIN}.conf"
        if [[ -f "$CONF_FILE" ]]; then
            if ! grep -q "Le_PreHook" "$CONF_FILE"; then
                echo "Le_PreHook='$PRE_HOOK'"   >> "$CONF_FILE"
                echo "Le_PostHook='$POST_HOOK'" >> "$CONF_FILE"
                log_success "续期 Hook 已配置（续期时将自动停启 $DETECTED_SVC）"
            fi
        fi
    else
        log_info "未检测到运行中的 Web 服务，续期将直接使用 Standalone 模式"
    fi

    log_step "设置证书自动续期..."
    local LOG_FILE="/var/log/acme-renew.log"
    local CRON_JOB="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> $LOG_FILE 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab - 2>/dev/null
        log_success "自动续期任务已设置（每天 02:00，日志: $LOG_FILE）"
    else
        log_info "自动续期任务已存在，跳过"
    fi

    manage_web_services_ssl "start"

    echo ""
    echo -e "${CYAN}=============================================="
    echo "           SSL证书部署完成！"
    echo "=============================================="
    echo -e "${NC}"
    echo -e "${GREEN}证书信息:${NC}"
    echo "  主域名: $MAIN_DOMAIN"
    echo "  所有域名: ${DOMAINS[*]}"
    echo "  证书目录: $CERT_DIR"
    echo "  私钥文件: $KEY_FILE"
    echo "  证书文件: $CERT_FILE"
    if [[ -f "$CERT_FILE" ]]; then
        local expire_date=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -n "$expire_date" ]]; then
            echo "  有效期至: $expire_date"
        fi
    fi
    echo ""
}

menu_ssl() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 二、SSL 证书 ══${NC}"
        echo ""
        echo "  1) 申请并安装 SSL 证书"
        echo "  2) 查看已安装证书"
        echo "  3) 手动续期证书"
        echo "  4) 查看续期日志"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) deploy_ssl; press_enter ;;
            2) /root/.acme.sh/acme.sh --list 2>/dev/null || log_warn "acme.sh 未安装"; press_enter ;;
            3)
                echo "输入要续期的域名:"
                read -r rd
                /root/.acme.sh/acme.sh --renew -d "$rd" --force 2>/dev/null || log_warn "续期失败"
                press_enter ;;
            4) tail -f /var/log/acme-renew.log 2>/dev/null || log_warn "日志文件不存在"; press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  三、安装服务（sing-box / Nginx）(优化 1：默认选项改为 0)
# ────────────────────────────────────────────────────────────────
setup_singbox_service() {
    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box

    if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
        cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    if command -v sing-box &>/dev/null; then
        local ver
        ver=$(sing-box version 2>/dev/null | head -1)
        log_success "sing-box 当前状态验证通过: $ver"
        return 0
    else
        log_error "sing-box 安装校验失败"
        return 1
    fi
}

install_singbox_repo() {
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl gnupg2 ca-certificates lsb-release >/dev/null 2>&1 || true
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc 2>/dev/null || true
        chmod a+r /etc/apt/keyrings/sagernet.asc 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" | tee /etc/apt/sources.list.d/sagernet.list > /dev/null
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y sing-box >/dev/null 2>&1 || true
    elif [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
        $PKG_MANAGER install -y curl yum-utils epel-release >/dev/null 2>&1 || true
        if command -v yum-config-manager &>/dev/null; then
            yum-config-manager --add-repo https://sing-box.app/sing-box.repo >/dev/null 2>&1 || true
        elif command -v dnf &>/dev/null; then
            dnf config-manager --add-repo https://sing-box.app/sing-box.repo >/dev/null 2>&1 || true
        fi
        $PKG_MANAGER install -y sing-box >/dev/null 2>&1 || true
    fi
}

install_singbox_github() {
    local is_beta="$1"
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_STR="amd64" ;;
        aarch64) ARCH_STR="arm64" ;;
        armv7l) ARCH_STR="armv7" ;;
        *) ARCH_STR="amd64" ;;
    esac
    local TARGET_VER=""
    if [[ "$is_beta" == "true" ]]; then
        TARGET_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"v([^"]+)".*/\1/')
    else
        TARGET_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    fi
    
    if [[ -n "$TARGET_VER" ]]; then
        log_info "获取到 GitHub 版本: v$TARGET_VER"
        local URL="https://github.com/SagerNet/sing-box/releases/download/v${TARGET_VER}/sing-box-${TARGET_VER}-linux-${ARCH_STR}.tar.gz"
        if curl -fsSL "$URL" -o /tmp/sing-box.tar.gz 2>/dev/null || wget -qO /tmp/sing-box.tar.gz "$URL" 2>/dev/null; then
            tar -xzf /tmp/sing-box.tar.gz -C /tmp/
            install -m 755 "/tmp/sing-box-${TARGET_VER}-linux-${ARCH_STR}/sing-box" /usr/local/bin/sing-box
            rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${TARGET_VER}-linux-${ARCH_STR}"
        fi
    fi
}

install_singbox_interactive() {
    local is_beta="$1"
    while true; do
        clear
        if [[ "$is_beta" == "true" ]]; then
            echo -e "${BOLD}${CYAN}══ sing-box Beta/预发布版 安装方式选择 ══${NC}"
        else
            echo -e "${BOLD}${CYAN}══ sing-box 稳定版 安装方式选择 ══${NC}"
        fi
        echo ""
        echo "  1) 官方旧版安装脚本 (deb/rpm) [默认/原方案]"
        echo "  2) 官方新版安装脚本 (install.sh)"
        echo "  3) 官方仓库源安装 (APT/DNF) [最稳定推荐]"
        echo "  4) GitHub Releases 二进制下载 (兜底方案)"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        
        # 优化 1：更改默认选项为 0
        read -rp "请选择 (默认 0): " m_opt
        m_opt=${m_opt:-0}

        case $m_opt in
            0) return 1 ;;
            1)
                log_step "正在执行: 官方旧版安装脚本..."
                if [[ "$is_beta" == "true" ]]; then
                    bash <(curl -fsSL https://sing-box.app/deb-install.sh) beta >/dev/null 2>&1 || bash <(curl -fsSL https://sing-box.app/rpm-install.sh) beta >/dev/null 2>&1 || true
                else
                    bash <(curl -fsSL https://sing-box.app/deb-install.sh) >/dev/null 2>&1 || bash <(curl -fsSL https://sing-box.app/rpm-install.sh) >/dev/null 2>&1 || true
                fi
                break
                ;;
            2)
                log_step "正在执行: 官方新版 install.sh..."
                if [[ "$is_beta" == "true" ]]; then
                    curl -fsSL https://sing-box.app/install.sh | bash -s -- --beta >/dev/null 2>&1 || true
                else
                    curl -fsSL https://sing-box.app/install.sh | bash >/dev/null 2>&1 || true
                fi
                break
                ;;
            3)
                log_step "正在执行: 官方 APT/DNF 仓库安装..."
                install_singbox_repo "$is_beta"
                break
                ;;
            4)
                log_step "正在执行: GitHub Releases 二进制下载..."
                install_singbox_github "$is_beta"
                break
                ;;
            *) log_warn "无效选择"; sleep 1 ;;
        esac
    done

    if setup_singbox_service; then
        return 0
    else
        log_error "当前选择的安装方式失败，请按 Enter 后尝试其他安装选项！"
        return 1
    fi
}

menu_install_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 三、安装服务 ══${NC}"
        echo ""
        echo -e "  ${CYAN}── sing-box ──${NC}"
        echo "  1) Latest 稳定版"
        echo "  2) 指定版本号"
        echo "  3) Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Nginx ──${NC}"
        echo "  4) 安装 Nginx"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (0-4, 默认 0): " vc
        vc=${vc:-0}

        case $vc in
            0) return ;;
            4) install_nginx ;;
            1)
                install_singbox_interactive "false" || true
                press_enter
                ;;
            2)
                echo -n "请输入版本号（例如 1.9.0）: "
                read -r SB_VER
                [[ -z "$SB_VER" ]] && { log_error "版本号不能为空"; press_enter; continue; }
                log_step "安装 sing-box v${SB_VER}..."
                local ARCH
                ARCH=$(uname -m)
                case "$ARCH" in
                    x86_64) ARCH_STR="amd64" ;;
                    aarch64) ARCH_STR="arm64" ;;
                    armv7l) ARCH_STR="armv7" ;;
                    *) ARCH_STR="amd64" ;;
                esac
                local URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH_STR}.tar.gz"
                if curl -fsSL "$URL" -o /tmp/sing-box.tar.gz 2>/dev/null || wget -qO /tmp/sing-box.tar.gz "$URL" 2>/dev/null; then
                    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
                    install -m 755 "/tmp/sing-box-${SB_VER}-linux-${ARCH_STR}/sing-box" /usr/local/bin/sing-box
                    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SB_VER}-linux-${ARCH_STR}"
                    log_success "指定版本安装成功"
                else
                    log_error "下载失败"; press_enter; continue;
                fi
                setup_singbox_service
                press_enter
                ;;
            3)
                install_singbox_interactive "true" || true
                press_enter
                ;;
            *) log_warn "无效选择"; sleep 1 ;;
        esac
    done
}

install_nginx() {
    log_step "安装 Nginx..."
    if command -v nginx &>/dev/null; then
        local ver
        ver=$(nginx -v 2>&1 | head -1)
        log_info "Nginx 已安装: $ver"
        read -rp "是否重新安装？(y/N): " yn
        if [[ "${yn,,}" != "y" ]]; then
            press_enter
            return
        fi
    fi
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt update -y && apt install -y nginx
    else
        $PKG_MANAGER install -y nginx
    fi
    mkdir -p /var/www/html
    if [[ ! -f /var/www/html/index.html ]]; then
        cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTML
    fi
    systemctl enable nginx && systemctl start nginx
    systemctl is-active --quiet nginx && log_success "Nginx 安装并启动成功" || log_warn "Nginx 启动失败"
    press_enter
}

# ────────────────────────────────────────────────────────────────
#  四、配置 sing-box — 各协议 build_* 函数
# ────────────────────────────────────────────────────────────────

build_vless_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — TCP / XTLS-Vision ───${NC}"
    echo ""

    local tag port uuid uname flow_choice flow

    ask_val   tag   "tag（inbound 标识）"  "vless-tcp-in"
    ask_val   port  "listen_port（监听端口）" "47790"
    ask_random uuid "uuid（用户 UUID）" "$(gen_uuid)"
    ask_val   uname "name（用户名）" "user-vless-tcp"

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        flow_choice="1"
        flow="xtls-rprx-vision"
        echo -e "  ${GREEN}✓ [自动] flow = xtls-rprx-vision${NC}"
    else
        echo -e "  ${CYAN}◆ flow（流控模式）${NC}"
        echo -e "    ${YELLOW}1)${NC} xtls-rprx-vision  [推荐，XTLS Vision 模式]"
        echo -e "    ${YELLOW}2)${NC} 无（普通 TLS，不启用流控）"
        ask_val flow_choice "请输入编号" "1"
        if [[ "$flow_choice" == "2" ]]; then
            flow=""
            echo -e "  ${GREEN}✓ flow = （空，普通 TLS）${NC}"
        else
            flow="xtls-rprx-vision"
            echo -e "  ${GREEN}✓ flow = xtls-rprx-vision${NC}"
        fi
    fi
    echo ""

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    local flow_json
    [[ -n "$flow" ]] && flow_json='"flow": "'"$flow"'"' || flow_json='"flow": ""'

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "$uname", "uuid": "$uuid", $flow_json}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      },
      "multiplex": {"enabled": false}
    }
EOF
}

build_vless_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — WebSocket ───${NC}"
    echo ""

    local tag port uuid wspath

    ask_val   tag    "tag（inbound 标识）"    "vless-ws-in"
    ask_val   port   "listen_port（监听端口）" "47791"
    ask_random uuid  "uuid（用户 UUID）"       "$(gen_uuid)"
    ask_val   wspath "ws path（WebSocket 路径）" "/vless-ws"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vless-ws", "uuid": "$uuid", "flow": ""}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"},
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
EOF
}

build_vless_grpc() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — gRPC ───${NC}"
    echo ""

    local tag port uuid svcname

    ask_val   tag     "tag（inbound 标识）"     "vless-grpc-in"
    ask_val   port    "listen_port（监听端口）"  "47792"
    ask_random uuid   "uuid（用户 UUID）"        "$(gen_uuid)"
    ask_val   svcname "service_name（gRPC 服务名）" "vless-grpc-service"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vless-grpc", "uuid": "$uuid", "flow": ""}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2"]
      },
      "transport": {
        "type": "grpc",
        "service_name": "$svcname",
        "idle_timeout": "15s",
        "ping_timeout": "15s"
      }
    }
EOF
}

build_vless_reality() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — REALITY ───${NC}"
    echo ""

    local port uuid pk si sn hs_server hs_port

    ask_val port "listen_port（监听端口，建议 443）" "443"
    ask_random uuid "uuid（用户 UUID）" "$(gen_uuid)"

    echo -e "  ${YELLOW}正在生成 REALITY 密钥对...${NC}"
    local keypair_out privkey pubkey
    keypair_out=$(gen_reality_keypair)
    privkey=$(echo "$keypair_out" | grep -i private | awk '{print $NF}')
    pubkey=$(echo  "$keypair_out" | grep -i public  | awk '{print $NF}')
    local sid_rand
    sid_rand=$(gen_short_id)
    echo ""

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        pk="$privkey"
        echo -e "  ${GREEN}✓ [自动] private_key = ${pk}${NC}"
        echo -e "  ${GREEN}✓ [自动] public_key  = ${pubkey}${NC}"
    else
        echo -e "  ${CYAN}◆ REALITY 密钥对（自动生成，回车直接使用）${NC}"
        echo -e "    ${YELLOW}Private Key:${NC} ${privkey}"
        echo -e "    ${GREEN}Public  Key:${NC} ${pubkey}  ← 客户端填此值"
        echo -e "    (若需自定义，请同时替换 Private Key 和对应的 Public Key)"
        echo ""
        echo -e "  ${CYAN}◆ private_key（REALITY 私钥，服务端用）${NC}"
        echo -e "    随机生成值: ${YELLOW}${privkey}${NC}"
        echo -e "    (回车使用随机值，或输入自定义 private_key)"
        read -rp "  > " _pk_input
        pk="${_pk_input:-$privkey}"
        if [[ -n "$_pk_input" && "$_pk_input" != "$privkey" ]]; then
            echo -e "  ${YELLOW}⚠ 已自定义 private_key，请同时输入对应的 public_key:${NC}"
            read -rp "  > public_key: " pubkey
        fi
        echo -e "  ${GREEN}✓ private_key = ${pk}${NC}"
        echo -e "  ${GREEN}✓ public_key  = ${pubkey}${NC}"
    fi
    echo ""

    ask_random si "short_id（REALITY Short ID）" "$sid_rand"

    echo ""
    echo -e "  ${BOLD}${GREEN}★ 客户端需要的 public_key（请复制保存）:${NC}"
    echo -e "  ${BOLD}${CYAN}    ${pubkey}${NC}"
    echo ""

    local _cert_domains=()
    mapfile -t _cert_domains < <(get_cert_domains 2>/dev/null)
    local _default_sn="www.microsoft.com"
    if [[ ${#_cert_domains[@]} -ge 1 ]]; then
        _default_sn="${_cert_domains[0]}"
    fi

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        sn="$_default_sn"
        echo -e "  ${GREEN}✓ [自动] server_name = ${sn}${NC}"
    else
        echo -e "  ${CYAN}◆ server_name（REALITY 伪装域名）${NC}"
        echo -e "    可以填已申请的证书域名（推荐），也可填任意公网 TLS 网站"
        if [[ ${#_cert_domains[@]} -gt 0 ]]; then
            echo -e "    检测到已安装证书，请选择或手动输入："
            for i in "${!_cert_domains[@]}"; do
                echo -e "    ${YELLOW}$((i+1)))${NC} ${_cert_domains[$i]}"
            done
            local _manual_idx=$(( ${#_cert_domains[@]} + 1 ))
            echo -e "    ${YELLOW}${_manual_idx})${NC} 手动输入其他域名"
            echo -e "    (默认选 1，即 ${_default_sn})"
            echo ""
            local _sn_choice
            read -rp "  > (编号，默认 1): " _sn_choice
            _sn_choice="${_sn_choice:-1}"
            if [[ "$_sn_choice" =~ ^[0-9]+$ ]] && [[ "$_sn_choice" -ge 1 ]] && [[ "$_sn_choice" -le "${#_cert_domains[@]}" ]]; then
                sn="${_cert_domains[$((_sn_choice-1))]}"
            else
                read -rp "  > 手动输入 server_name (默认 ${_default_sn}): " sn
                sn="${sn:-$_default_sn}"
            fi
        else
            echo -e "    未检测到已安装证书，请手动输入（或直接回车使用默认）"
            ask_val sn "server_name" "$_default_sn"
        fi
        echo -e "  ${GREEN}✓ server_name = ${sn}${NC}"
    fi
    echo ""

    ask_val hs_server "handshake server（IP 或域名）" "127.0.0.1"
    ask_val hs_port   "handshake port" "8001"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": $port,
      "users": [{"uuid": "$uuid", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$hs_server",
            "server_port": $hs_port
          },
          "private_key": "$pk",
          "short_id": ["$si"]
        }
      }
    }
EOF
    local _reality_meta="/etc/sing-box/reality_meta.conf"
    grep -v "^${port}:" "$_reality_meta" 2>/dev/null > "${_reality_meta}.tmp" || true
    echo "${port}:${pubkey}" >> "${_reality_meta}.tmp"
    mv "${_reality_meta}.tmp" "$_reality_meta"
    log_success "public_key 已保存至 $_reality_meta（供生成链接时使用）"

    setup_nginx_reality "$sn"
}

setup_nginx_reality() {
    local domain="$1"
    log_step "配置 Nginx REALITY 回落（域名: ${domain}）..."

    if ! command -v nginx &>/dev/null; then
        log_warn "Nginx 未安装，跳过自动配置（可在「三、安装服务」中安装 Nginx 后重新配置）"
        return
    fi

    mkdir -p /var/www/html
    if [[ ! -f /var/www/html/index.html ]]; then
        cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTML
    fi
    chmod 644 /var/www/html/index.html
    chmod 755 /var/www/html
    log_success "已设置 /var/www/html 权限"

    local cert_path="" key_path=""
    for d in /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/fullchain.cer" ]] && cert_path="$d/fullchain.cer" && break
    done
    for d in /etc/ssl/private /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/private.key" ]] && key_path="$d/private.key" && break
    done
    [[ -z "$cert_path" && -f "/root/.acme.sh/${domain}/fullchain.cer" ]] && cert_path="/root/.acme.sh/${domain}/fullchain.cer"
    [[ -z "$key_path"  && -f "/root/.acme.sh/${domain}/${domain}.key" ]] && key_path="/root/.acme.sh/${domain}/${domain}.key"
    cert_path="${cert_path:-/etc/ssl/private/fullchain.cer}"
    key_path="${key_path:-/etc/ssl/private/private.key}"

    cat > /tmp/nginx.conf.template << 'EOF'
user root;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format main '[$time_local] $proxy_protocol_addr "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ""      close;
    }

    map $proxy_protocol_addr $proxy_forwarded_elem {
        ~^[0-9.]+$        "for=$proxy_protocol_addr";
        ~^[0-9A-Fa-f:.]+$ "for=\"[$proxy_protocol_addr]\"";
        default           "for=unknown";
    }

    map $http_forwarded $proxy_add_forwarded {
        "~^(,[ \t]*)*([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([\t \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\\\[\t \x21-\x7E\x80-\xFF])*\"))?(;([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([\t \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\\\[\t \x21-\x7E\x80-\xFF])*\"))?)*([ \t]*,([ \t]*([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([\t \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\\\[\t \x21-\x7E\x80-\xFF])*\"))?(;([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([\t \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\\\[\t \x21-\x7E\x80-\xFF])*\"))?)*)?)*$" "$http_forwarded, $proxy_forwarded_elem";
        default "$proxy_forwarded_elem";
    }

    server {
        listen 80;
        listen [::]:80;
        return 301 https://$host$request_uri;
    }

    server {
        listen                     127.0.0.1:8001 ssl http2;

        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;

        server_name                __DOMAIN__;

        ssl_certificate            __CERT_PATH__;
        ssl_certificate_key        __KEY_PATH__;

        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers  on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        root  /var/www/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        location ~* \.(php|asp|aspx|jsp|cgi)$ {
            return 404;
        }
    }
}
EOF

    sed -i "s|__DOMAIN__|${domain}|g" /tmp/nginx.conf.template
    sed -i "s|__CERT_PATH__|${cert_path}|g" /tmp/nginx.conf.template
    sed -i "s|__KEY_PATH__|${key_path}|g" /tmp/nginx.conf.template

    mv /tmp/nginx.conf.template /etc/nginx/nginx.conf
    log_info "nginx.conf 写入完成"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        log_success "Nginx REALITY 回落配置已写入并重载"
        log_info "  证书: ${cert_path}"
        log_info "  私钥: ${key_path}"
        log_info "  域名: ${domain}"
        log_info "  回落端口: 127.0.0.1:8001"
    else
        log_warn "Nginx 配置语法有误，详细原因："
        nginx -t
    fi
}

build_vmess_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VMess — TCP (TLS) ───${NC}"
    echo ""

    local tag port uuid

    ask_val   tag  "tag（inbound 标识）"    "vmess-tcp-in"
    ask_val   port "listen_port（监听端口）" "45790"
    ask_random uuid "uuid（用户 UUID）"     "$(gen_uuid)"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vmess",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vmess-tcp", "uuid": "$uuid", "alterId": 0}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      }
    }
EOF
}

build_vmess_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VMess — WebSocket (TLS) ───${NC}"
    echo ""

    local tag port uuid wspath

    ask_val   tag    "tag（inbound 标识）"       "vmess-ws-in"
    ask_val   port   "listen_port（监听端口）"    "45791"
    ask_random uuid  "uuid（用户 UUID）"          "$(gen_uuid)"
    ask_val   wspath "ws path（WebSocket 路径）"  "/vmess-ws"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vmess",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vmess-ws", "uuid": "$uuid", "alterId": 0}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"}
      }
    }
EOF
}

build_trojan_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Trojan — TCP (TLS) ───${NC}"
    echo ""

    local tag port pwd uname

    ask_val   tag   "tag（inbound 标识）"    "trojan-tcp-in"
    ask_val   port  "listen_port（监听端口）" "44790"
    ask_random pwd  "password（Trojan 密码）" "$(gen_password 20)"
    ask_val   uname "name（用户名）"          "user-trojan-tcp"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "$uname", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      },
      "fallback": {"server": "127.0.0.1", "server_port": 80}
    }
EOF
}

build_trojan_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Trojan — WebSocket (TLS) ───${NC}"
    echo ""

    local tag port pwd wspath

    ask_val   tag    "tag（inbound 标识）"       "trojan-ws-in"
    ask_val   port   "listen_port（监听端口）"    "44791"
    ask_random pwd   "password（Trojan 密码）"    "$(gen_password 20)"
    ask_val   wspath "ws path（WebSocket 路径）"  "/trojan-ws"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-trojan-ws", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"}
      }
    }
EOF
}

build_ss_classic() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks — 经典加密 ───${NC}"
    echo ""

    local tag port mc method pwd

    ask_val tag  "tag（inbound 标识）"    "ss-aes-in"
    ask_val port "listen_port（监听端口）" "46792"

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        method="aes-256-gcm"
        echo -e "  ${GREEN}✓ [自动] 加密方式 = ${method}${NC}"
    else
        echo -e "  ${CYAN}◆ 加密方式${NC}"
        echo -e "    ${YELLOW}1)${NC} aes-256-gcm          [默认，推荐]"
        echo -e "    ${YELLOW}2)${NC} aes-128-gcm"
        echo -e "    ${YELLOW}3)${NC} chacha20-ietf-poly1305"
        ask_val mc "请输入编号" "1"
        case $mc in
            2) method="aes-128-gcm" ;;
            3) method="chacha20-ietf-poly1305" ;;
            *) method="aes-256-gcm" ;;
        esac
        echo -e "  ${GREEN}✓ 加密方式 = ${method}${NC}"
    fi
    echo ""

    ask_random pwd "password（连接密码）" "$(gen_password 20)"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "$method",
      "password": "$pwd",
      "multiplex": {"enabled": true, "padding": false}
    }
EOF
}

build_ss2022_256() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks 2022 — aes-256-gcm ───${NC}"
    echo ""

    local tag port spwd upwd uname

    ask_val   tag   "tag（inbound 标识）"    "ss-2022-256-in"
    ask_val   port  "listen_port（监听端口）" "46791"
    ask_random spwd "server password（服务端密钥，base64-32B）" "$(gen_ss2022_key_256)"
    ask_random upwd "user password（用户密钥，base64-32B）"     "$(gen_ss2022_key_256)"
    ask_val   uname "name（用户名）" "user-ss-2022-256"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "2022-blake3-aes-256-gcm",
      "password": "$spwd",
      "users": [{"name": "$uname", "password": "$upwd"}],
      "multiplex": {"enabled": true, "padding": true}
    }
EOF
}

build_ss2022_128() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks 2022 — aes-128-gcm ───${NC}"
    echo ""

    local tag port spwd upwd

    ask_val   tag  "tag（inbound 标识）"    "ss-2022-128-in"
    ask_val   port "listen_port（监听端口）" "46790"
    ask_random spwd "server password（服务端密钥，base64-16B）" "$(gen_ss2022_key_128)"
    ask_random upwd "user password（用户密钥，base64-16B）"     "$(gen_ss2022_key_128)"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$spwd",
      "users": [{"name": "user-ss-2022-128", "password": "$upwd"}],
      "multiplex": {"enabled": true, "padding": true}
    }
EOF
}

build_hysteria2() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Hysteria2 ───${NC}"
    echo ""

    local tag port pwd obfspwd up dn

    ask_val   tag      "tag（inbound 标识）"    "hysteria2-in"
    ask_val   port     "listen_port（监听端口）" "43790"
    ask_random pwd     "password（连接密码）"    "$(gen_uuid)"
    ask_random obfspwd "obfs password（混淆密码）" "$(gen_password 16)"
    ask_val   up       "up_mbps（上行限速 Mbps）"  "200"
    ask_val   dn       "down_mbps（下行限速 Mbps）" "100"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "hysteria2",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-hysteria2", "password": "$pwd"}],
      "up_mbps": $up,
      "down_mbps": $dn,
      "obfs": {"type": "salamander", "password": "$obfspwd"},
      "masquerade": "https://www.bing.com",
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "alpn": ["h3"],
        "certificate_path": "$cp",
        "key_path": "$kp"
      }
    }
EOF
}

build_tuic() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── TUIC v5 ───${NC}"
    echo ""

    local tag port uuid pwd

    ask_val   tag  "tag（inbound 标识）"    "tuic-in"
    ask_val   port "listen_port（监听端口）" "42790"
    ask_random uuid "uuid（用户 UUID）"     "$(gen_uuid)"
    ask_random pwd  "password（用户密码）"  "$(gen_password 20)"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "tuic",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-tuic", "uuid": "$uuid", "password": "$pwd"}],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "alpn": ["h3"],
        "certificate_path": "$cp",
        "key_path": "$kp"
      }
    }
EOF
}

build_anytls() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── AnyTLS ───${NC}"
    echo ""

    local tag port pwd

    ask_val   tag  "tag（inbound 标识）"    "anytls-in"
    ask_val   port "listen_port（监听端口）" "48790"
    ask_random pwd "password（连接密码）"   "$(gen_uuid)"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "anytls",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-anytls", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      }
    }
EOF
}

build_naive() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── NaïveProxy ───${NC}"
    echo ""

    local tag port uname pwd

    ask_val   tag   "tag（inbound 标识）"    "naive-in"
    ask_val   port  "listen_port（监听端口）" "41790"
    ask_random uname "username（用户名）"    "$(gen_naive_username)"
    ask_random pwd   "password（用户密码）"  "$(gen_password 20)"

    select_server_name "example.com"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "naive",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"username": "$uname", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2"]
      }
    }
EOF
}

configure_singbox() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 四、配置 sing-box ══${NC}"
        echo ""
        echo "请选择要配置的协议（多个选择用空格分隔，例如：1 3 5）:"
        echo ""
        echo "   1)  VLESS — TCP / XTLS-Vision"
        echo "   2)  VLESS — WebSocket"
        echo "   3)  VLESS — gRPC"
        echo "   4)  VLESS — REALITY (TCP + XTLS-Vision) [默认端口: 443]"
        echo "   5)  VMess — TCP (TLS)"
        echo "   6)  VMess — WebSocket (TLS)"
        echo "   7)  Trojan — TCP (TLS)"
        echo "   8)  Trojan — WebSocket (TLS)"
        echo "   9)  Shadowsocks — 经典加密 (aes-256-gcm)"
        echo "  10)  Shadowsocks 2022 — aes-256-gcm"
        echo "  11)  Shadowsocks 2022 — aes-128-gcm"
        echo "  12)  Hysteria2"
        echo "  13)  TUIC v5"
        echo "  14)  AnyTLS"
        echo "  15)  NaïveProxy"
        echo ""
        echo -e "${GREEN}  16)  全部配置（逐一交互确认）${NC}"
        echo -e "${GREEN}  17)  全部自动配置（按默认设置静默配置）${NC}"
        echo -e "${YELLOW}   0)  返回主菜单${NC}"
        echo ""
        
        read -rp "请输入选项（例如 1 4 12，默认 0）: " -a PROTO_CHOICES

        if [[ ${#PROTO_CHOICES[@]} -eq 0 ]]; then
            PROTO_CHOICES=("0")
        fi

        if [[ "${PROTO_CHOICES[0]}" == "0" ]]; then
            return
        fi

        AUTO_DEFAULT=false
        local has_17=false
        local has_16=false
        
        for choice in "${PROTO_CHOICES[@]}"; do
            if [[ "$choice" == "17" ]]; then has_17=true; fi
            if [[ "$choice" == "16" ]]; then has_16=true; fi
        done

        if [[ "$has_17" == "true" ]]; then
            PROTO_CHOICES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
            AUTO_DEFAULT=true
            log_info "已选择全部自动配置，将使用默认参数静默生成所有节点..."
            sleep 1
        elif [[ "$has_16" == "true" ]]; then
            PROTO_CHOICES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
            log_info "已选择全部配置，即将逐一进行交互确认..."
            sleep 1
        else
            log_info "已选择 ${#PROTO_CHOICES[@]} 个协议，开始逐一配置..."
        fi

        local TMP_JSON
        TMP_JSON=$(mktemp /tmp/jddj_inbound_XXXXXX)
        local INBOUNDS_JSON=""
        local first=true

        for choice in "${PROTO_CHOICES[@]}"; do
            > "$TMP_JSON"
            case $choice in
                1)  build_vless_tcp     "$TMP_JSON" ;;
                2)  build_vless_ws      "$TMP_JSON" ;;
                3)  build_vless_grpc    "$TMP_JSON" ;;
                4)  build_vless_reality "$TMP_JSON" ;;
                5)  build_vmess_tcp     "$TMP_JSON" ;;
                6)  build_vmess_ws      "$TMP_JSON" ;;
                7)  build_trojan_tcp    "$TMP_JSON" ;;
                8)  build_trojan_ws     "$TMP_JSON" ;;
                9)  build_ss_classic    "$TMP_JSON" ;;
                10) build_ss2022_256    "$TMP_JSON" ;;
                11) build_ss2022_128    "$TMP_JSON" ;;
                12) build_hysteria2     "$TMP_JSON" ;;
                13) build_tuic          "$TMP_JSON" ;;
                14) build_anytls        "$TMP_JSON" ;;
                15) build_naive         "$TMP_JSON" ;;
                *)  log_warn "未知选项: $choice，跳过"; continue ;;
            esac
            local inbound_json
            inbound_json=$(cat "$TMP_JSON")
            [[ -z "$inbound_json" ]] && continue
            if $first; then
                INBOUNDS_JSON="$inbound_json"
                first=false
            else
                INBOUNDS_JSON="${INBOUNDS_JSON},${inbound_json}"
            fi
        done
        rm -f "$TMP_JSON"

        mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box
        cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/var/log/sing-box/sing-box.log"
  },

  "inbounds": [
$INBOUNDS_JSON
  ],

  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]
}
EOF

        log_success "配置文件已写入: /etc/sing-box/config.json"
        echo ""

        if command -v sing-box &>/dev/null; then
            local _check_out
            _check_out=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true sing-box check -c /etc/sing-box/config.json 2>&1)
            local _check_rc=$?
            if [[ $_check_rc -eq 0 ]]; then
                log_success "配置语法验证通过"
                if echo "$_check_out" | grep -q "legacy DNS"; then
                    log_warn "检测到 sing-box 版本要求新 DNS 格式，已自动写入 udp:// 前缀格式"
                    log_info "如遇问题请升级 sing-box：bash <(curl -fsSL https://sing-box.app/deb-install.sh)"
                fi
            else
                local _real_errors
                _real_errors=$(echo "$_check_out" | grep -v "legacy DNS\|ENABLE_DEPRECATED" || true)
                if [[ -z "$_real_errors" ]]; then
                    log_success "配置语法验证通过（DNS 格式兼容性警告已忽略）"
                else
                    log_warn "配置语法验证失败，详细原因："
                    echo "$_real_errors"
                fi
            fi
        fi

        press_enter
        break
    done
}

# ────────────────────────────────────────────────────────────────
#  五、服务管理（sing-box / Nginx）
# ────────────────────────────────────────────────────────────────
menu_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 五、服务管理 ══${NC}"
        echo ""
        local status_str
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            status_str="${GREEN}● 运行中${NC}"
        else
            status_str="${RED}○ 已停止${NC}"
        fi
        echo -e "  当前状态: $status_str"
        echo ""
        echo -e "  ${CYAN}── sing-box ──${NC}"
        echo "  1) 启动 sing-box"
        echo "  2) 停止 sing-box"
        echo "  3) 重启 sing-box 并查看状态"
        echo "  4) 查看完整状态 (systemctl status)"
        echo "  5) 设为开机自启"
        echo "  6) 取消开机自启"
        echo "  7) 查看是否开机自启"
        echo "  8) 实时查看日志"
        echo "  9) 验证配置文件"
        echo " 10) 一键修复配置（移除旧 dns/route 段）"
        echo ""
        echo -e "  ${CYAN}── Nginx ──${NC}"
        echo " 11) 验证 Nginx 配置 (nginx -t)"
        echo " 12) 重启 Nginx 并查看状态"
        echo " 13) 启动 Nginx"
        echo " 14) 停止 Nginx"
        echo " 15) 设为开机自启"
        echo " 16) 实时查看 Nginx 错误日志"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) systemctl start sing-box && log_success "sing-box 已启动"; press_enter ;;
            2) systemctl stop sing-box && log_success "sing-box 已停止"; press_enter ;;
            3)
                systemctl restart sing-box
                echo ""
                systemctl status sing-box --no-pager
                press_enter ;;
            4) systemctl status sing-box; press_enter ;;
            5) systemctl enable sing-box && log_success "已设为开机自启"; press_enter ;;
            6) systemctl disable sing-box && log_success "已取消开机自启"; press_enter ;;
            7)
                if systemctl is-enabled --quiet sing-box 2>/dev/null; then
                    log_success "sing-box 已设为开机自启"
                else
                    log_warn "sing-box 未设为开机自启"
                fi
                press_enter ;;
            8) journalctl -u sing-box -f --no-pager ;;
            9)
                if command -v sing-box &>/dev/null; then
                    local _sc_out
                    _sc_out=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true sing-box check -c /etc/sing-box/config.json 2>&1)
                    local _sc_rc=$?
                    if [[ $_sc_rc -eq 0 ]]; then
                        log_success "配置验证通过"
                    else
                        local _sc_real
                        _sc_real=$(echo "$_sc_out" | grep -v "legacy DNS\|ENABLE_DEPRECATED" || true)
                        if [[ -z "$_sc_real" ]]; then
                            log_success "配置验证通过（DNS 兼容性警告已忽略）"
                        else
                            log_error "配置验证失败，详细原因："
                            echo "$_sc_real"
                        fi
                    fi
                else
                    log_error "sing-box 未安装"
                fi
                press_enter ;;
            10) fix_dns_format; press_enter ;;
            11)
                if command -v nginx &>/dev/null; then
                    nginx -t && log_success "Nginx 配置验证通过" || log_error "Nginx 配置有误"
                else
                    log_error "Nginx 未安装"
                fi
                press_enter ;;
            12)
                if command -v nginx &>/dev/null; then
                    systemctl restart nginx
                    echo ""
                    systemctl status nginx --no-pager
                else
                    log_error "Nginx 未安装"
                fi
                press_enter ;;
            13) systemctl start  nginx && log_success "Nginx 已启动"; press_enter ;;
            14) systemctl stop   nginx && log_success "Nginx 已停止"; press_enter ;;
            15) systemctl enable nginx && log_success "Nginx 已设为开机自启"; press_enter ;;
            16) tail -f /var/log/nginx/error.log ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

fix_dns_format() {
    local cfg="/etc/sing-box/config.json"
    [[ ! -f "$cfg" ]] && { log_error "配置文件不存在: $cfg"; return 1; }

    log_step "修复旧版 config.json（移除 geoip/dns/route，兼容 sing-box 1.12+）..."
    cp "$cfg" "${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
    log_info "已备份原文件"

    python3 << 'INNEREOF'
import json, re, sys

cfg_path = "/etc/sing-box/config.json"
with open(cfg_path) as f:
    raw = f.read()

clean = re.sub(r'(?<![:/])//[^\n]*', '', raw)
try:
    obj = json.loads(clean)
except Exception as e:
    print(f"[ERROR] 解析配置失败: {e}")
    sys.exit(1)

changed = []

if "dns" in obj:
    del obj["dns"]
    changed.append("移除 dns 段")

if "route" in obj:
    del obj["route"]
    changed.append("移除 route 段（含 geoip 规则）")

if "outbounds" not in obj:
    obj["outbounds"] = [
        {"type": "direct", "tag": "direct"},
        {"type": "block",  "tag": "block"}
    ]
    changed.append("补充 outbounds")

if changed:
    with open(cfg_path, "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    print("[✓] 修复内容: " + " / ".join(changed))
else:
    print("[INFO] 配置已是最新格式，无需修复")
INNEREOF

    echo ""
    log_step "修复后验证..."
    if command -v sing-box &>/dev/null; then
        local _out _rc
        _out=$(sing-box check -c "$cfg" 2>&1)
        _rc=$?
        if [[ $_rc -eq 0 ]]; then
            log_success "配置验证通过"
        else
            log_warn "验证结果："
            echo "$_out"
        fi
    fi
    log_info "修复完成，请选择「3) 重启 sing-box」使配置生效"
}

# ────────────────────────────────────────────────────────────────
#  六、生成节点链接
# ────────────────────────────────────────────────────────────────
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || \
    printf '%s' "$1" | od -An -tx1 | tr ' ' '%' | tr -d '\n'
}

get_server_ip() {
    local ip=""
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://ipinfo.io/ip"; do
        ip=$(curl -s --max-time 4 "$svc" 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && break
    done
    echo "${ip:-127.0.0.1}"
}

generate_links() {
    local CONFIG="/etc/sing-box/config.json"
    if [[ ! -f "$CONFIG" ]]; then
        log_error "配置文件不存在: $CONFIG"
        return 1
    fi

    if ! command -v python3 &>/dev/null; then
        log_error "需要 python3，请先安装"; return 1
    fi

    local SERVER_IP
    log_info "获取服务器 IP..."
    SERVER_IP=$(get_server_ip)
    log_info "服务器 IP: $SERVER_IP"
    echo ""

    python3 << PYEOF
import json, base64, sys, re, urllib.parse

CONFIG_FILE = "/etc/sing-box/config.json"
SERVER_IP   = "$SERVER_IP"
OUTPUT_FILE = "/etc/sing-box/subscription.txt"
B64_FILE    = "/etc/sing-box/subscription.b64"
CLASH_FILE  = "/etc/sing-box/clash.yaml"

def urlencode(s):
    return urllib.parse.quote(str(s), safe='')

def b64(s):
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip('=')

def get_sni(tls, addr):
    if isinstance(tls, dict):
        return tls.get('server_name') or addr
    return addr

def strip_comments(text):
    return re.sub(r'(?<![:/])//[^\n]*', '', text)

with open(CONFIG_FILE) as f:
    raw = f.read()

try:
    config = json.loads(raw)
except:
    try:
        config = json.loads(strip_comments(raw))
    except Exception as e:
        print(f"[ERROR] 解析配置失败: {e}")
        sys.exit(1)

links = []
clash_proxies = []
clash_proxy_names = []

inbounds = config.get('inbounds', [])
for ib in inbounds:
    t    = ib.get('type', '')
    tag  = ib.get('tag', t)
    port = ib.get('listen_port')
    if not port:
        continue

    listen = ib.get('listen', '::')
    addr = SERVER_IP if listen in ('::', '0.0.0.0') else listen

    tls = ib.get('tls', {})
    tls_on = tls.get('enabled', False)
    sni = get_sni(tls, addr)

    def is_ip(s):
        import re
        return bool(re.match(r'^[\d.]+$', s) or re.match(r'^[0-9a-fA-F:]+$', s))
    if tls_on and sni and not is_ip(sni):
        addr = sni

    tag_enc = urlencode(tag)
    users = ib.get('users', [])
    transport = ib.get('transport', {})
    net = transport.get('type', 'tcp')
    ws_path = transport.get('path', '/')

    if t == 'vless':
        if not users: continue
        u = users[0]
        uuid  = u.get('uuid', '')
        flow  = u.get('flow', '')

        reality = tls.get('reality', {})
        reality_on = reality.get('enabled', False)

        if reality_on:
            pbk = ''
            try:
                with open('/etc/sing-box/reality_meta.conf') as _mf:
                    for _line in _mf:
                        _line = _line.strip()
                        if _line.startswith(f"{port}:"):
                            pbk = _line.split(':', 1)[1]
                            break
            except Exception:
                pass
            sid_val = reality.get('short_id', [''])
            sid = sid_val[0] if isinstance(sid_val, list) else sid_val
            params = f"encryption=none&flow={flow}&security=reality&sni={sni}&fp=chrome&pbk={urlencode(pbk)}&sid={sid}&type=tcp&headerType=none"
        else:
            sec = 'tls' if tls_on else 'none'
            params = f"encryption=none"
            if flow: params += f"&flow={flow}"
            params += f"&security={sec}&sni={sni}&fp=chrome&type={net}&headerType=none"
            if net in ('ws', 'http'):
                params += f"&path={urlencode(ws_path)}"
            if net == 'grpc':
                svc = ib.get('transport', {}).get('service_name', '')
                if svc:
                    params += f"&serviceName={urlencode(svc)}"

        link = f"vless://{uuid}@{addr}:{port}?{params}#{tag_enc}"
        links.append(link)

        cp = {
            'name': tag, 'type': 'vless', 'server': addr, 'port': port,
            'uuid': uuid, 'tls': tls_on, 'servername': sni,
            'network': net, 'udp': True
        }
        if flow: cp['flow'] = flow
        if reality_on:
            cp['reality-opts'] = {'public-key': pbk, 'short-id': sid}
            cp['tls'] = True
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'vmess':
        if not users: continue
        u = users[0]
        uuid = u.get('uuid', '')
        aid  = u.get('alterId', 0)
        tls_s = 'tls' if tls_on else 'none'

        obj = {
            'v':'2','ps':tag,'add':addr,'port':str(port),
            'id':uuid,'aid':str(aid),'scy':'auto',
            'net':net,'type':'none','host':sni,
            'path':ws_path,'tls':tls_s,'sni':sni,'fp':'chrome'
        }
        enc = base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip('=')
        links.append(f"vmess://{enc}")

        cp = {
            'name': tag, 'type': 'vmess', 'server': addr, 'port': port,
            'uuid': uuid, 'alterId': aid, 'cipher': 'auto',
            'tls': tls_on, 'servername': sni, 'network': net, 'udp': True
        }
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'trojan':
        if not users: continue
        pwd = users[0].get('password', '')
        params = f"security=tls&sni={sni}&type={net}"
        if net == 'ws':
            params += f"&path={urlencode(ws_path)}"
        links.append(f"trojan://{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'trojan', 'server': addr, 'port': port,
            'password': pwd, 'sni': sni, 'udp': True, 'network': net
        }
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'shadowsocks':
        method = ib.get('method', '')
        server_pwd = ib.get('password', '')
        if not method or not server_pwd: continue

        if method.startswith('2022-'):
            user_pwd = ''
            if users:
                user_pwd = users[0].get('password', '')
            if user_pwd:
                raw = f"{method}:{server_pwd}:{user_pwd}"
            else:
                raw = f"{method}:{server_pwd}"
            info = base64.urlsafe_b64encode(raw.encode()).decode().rstrip('=')
            clash_pwd = f"{server_pwd}:{user_pwd}" if user_pwd else server_pwd
        else:
            info = base64.urlsafe_b64encode(f"{method}:{server_pwd}".encode()).decode().rstrip('=')
            clash_pwd = server_pwd

        links.append(f"ss://{info}@{addr}:{port}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'ss', 'server': addr, 'port': port,
            'cipher': method, 'password': clash_pwd, 'udp': True
        }
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'hysteria2':
        if not users: continue
        pwd    = users[0].get('password', '')
        up_m   = ib.get('up_mbps', 200)
        dn_m   = ib.get('down_mbps', 100)
        obfs_conf = ib.get('obfs', {})
        obfs_type = obfs_conf.get('type', '')
        obfs_pwd  = obfs_conf.get('password', '')
        params = f"sni={sni}&insecure=0&allowInsecure=0&upmbps={up_m}&downmbps={dn_m}"
        if obfs_type:
            params += f"&obfs={obfs_type}"
        if obfs_pwd:
            params += f"&obfs-password={urlencode(obfs_pwd)}"
        links.append(f"hysteria2://{pwd}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'hysteria2', 'server': addr, 'port': port,
            'password': pwd, 'sni': sni, 'up': f"{up_m} Mbps", 'down': f"{dn_m} Mbps",
            'skip-cert-verify': False
        }
        if obfs_type:
            cp['obfs'] = obfs_type
        if obfs_pwd:
            cp['obfs-password'] = obfs_pwd
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'tuic':
        if not users: continue
        u    = users[0]
        uuid = u.get('uuid', '')
        pwd  = u.get('password', '')
        cc   = ib.get('congestion_control', 'bbr')
        params = f"sni={sni}&congestion_control={cc}&alpn=h3&udp_relay_mode=native"
        links.append(f"tuic://{uuid}:{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'tuic', 'server': addr, 'port': port,
            'uuid': uuid, 'password': pwd, 'alpn': ['h3'],
            'congestion-controller': cc, 'sni': sni, 'udp-relay-mode': 'native'
        }
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'anytls':
        if not users: continue
        pwd    = users[0].get('password', '')
        params = f"security=tls&sni={sni}&insecure=0&allowInsecure=0&type=tcp"
        links.append(f"anytls://{pwd}@{addr}:{port}?{params}#{tag_enc}")

    elif t == 'naive':
        if not users: continue
        u    = users[0]
        uname = u.get('username', '')
        pwd   = u.get('password', '')
        links.append(f"naive+https://{urlencode(uname)}:{urlencode(pwd)}@{addr}:{port}?padding=true#{tag_enc}")

with open(OUTPUT_FILE, 'w') as f:
    f.write('\n'.join(links) + '\n')

with open(B64_FILE, 'w') as f:
    f.write(base64.b64encode('\n'.join(links).encode()).decode() + '\n')

try:
    import yaml
    clash_doc = {
        'mixed-port': 7890,
        'allow-lan': False,
        'mode': 'rule',
        'log-level': 'info',
        'proxies': clash_proxies,
        'proxy-groups': [{
            'name': 'Proxy',
            'type': 'select',
            'proxies': clash_proxy_names + ['DIRECT']
        }],
        'rules': ['MATCH,Proxy']
    }
    with open(CLASH_FILE, 'w') as f:
        yaml.dump(clash_doc, f, allow_unicode=True, default_flow_style=False)
    print(f"Clash/Mihomo 配置已写入: {CLASH_FILE}")
except ImportError:
    with open(CLASH_FILE, 'w') as f:
        f.write("mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\n\nproxies:\n")
        for p in clash_proxies:
            f.write(f"  - name: {json.dumps(p['name'], ensure_ascii=False)}\n")
            f.write(f"    type: {p['type']}\n")
            f.write(f"    server: {p['server']}\n")
            f.write(f"    port: {p['port']}\n")
            for k, v in p.items():
                if k not in ('name','type','server','port'):
                    f.write(f"    {k}: {json.dumps(v, ensure_ascii=False) if isinstance(v,(dict,list)) else v}\n")
        f.write("\nproxy-groups:\n  - name: Proxy\n    type: select\n    proxies:\n")
        for n in clash_proxy_names:
            f.write(f"      - {json.dumps(n, ensure_ascii=False)}\n")
        f.write("      - DIRECT\n\nrules:\n  - MATCH,Proxy\n")

print(f"\n[✓] 共生成 {len(links)} 条订阅链接")
print(f"[✓] 明文订阅: {OUTPUT_FILE}")
print(f"[✓] Base64订阅 (V2RayN): {B64_FILE}")
print(f"[✓] Clash/Mihomo: {CLASH_FILE}")
print("")
print("══════════════ 所有节点链接 ══════════════")
for lk in links:
    print(lk)
print("══════════════════════════════════════════")
PYEOF
}

menu_links() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 六、生成节点链接 ══${NC}"
        echo ""
        echo "  1) 生成所有节点链接（singbox / V2RayN / Clash Mihomo）"
        echo "  2) 查看明文订阅"
        echo "  3) 查看 Base64 订阅（V2RayN 用）"
        echo "  4) 查看 Clash/Mihomo 配置"
        echo "  5) 显示订阅文件路径"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) generate_links; press_enter ;;
            2) cat /etc/sing-box/subscription.txt 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            3) cat /etc/sing-box/subscription.b64 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            4) cat /etc/sing-box/clash.yaml 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            5)
                echo "  明文订阅:       /etc/sing-box/subscription.txt"
                echo "  Base64 订阅:    /etc/sing-box/subscription.b64"
                echo "  Clash/Mihomo:   /etc/sing-box/clash.yaml"
                press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  全部执行 1→6
# ────────────────────────────────────────────────────────────────
run_all() {
    clear
    echo -e "${BOLD}${YELLOW}══ 全部执行 1→6 ══${NC}"
    echo ""
    echo "将依次执行："
    echo "  1. 基础安全设置（SSH/BBR/fail2ban）"
    echo "  2. SSL 证书申请"
    echo "  3. 安装 sing-box"
    echo "  4. 配置 sing-box 协议"
    echo "  5. 启动 sing-box 服务"
    echo "  6. 生成节点链接"
    echo ""
    read -rp "确认继续？(y/N): " c
    [[ "${c,,}" != "y" ]] && return

    detect_distro
    bootstrap_packages

    echo ""
    echo -e "${BLUE}── 步骤 1：基础安全设置 ──${NC}"
    setup_ssh_key
    disable_password_login
    change_ssh_port
    enable_bbr
    configure_ip_protocol
    setup_fail2ban

    echo ""
    echo -e "${BLUE}── 步骤 2：SSL 证书 ──${NC}"
    deploy_ssl

    echo ""
    echo -e "${BLUE}── 步骤 3：安装 sing-box ──${NC}"
    
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl gnupg2 ca-certificates lsb-release >/dev/null 2>&1 || true
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc 2>/dev/null || true
        chmod a+r /etc/apt/keyrings/sagernet.asc 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" | tee /etc/apt/sources.list.d/sagernet.list > /dev/null
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y sing-box >/dev/null 2>&1 || true
    fi
    if ! command -v sing-box &>/dev/null; then
        curl -fsSL https://sing-box.app/install.sh | bash >/dev/null 2>&1 || bash <(curl -fsSL https://sing-box.app/deb-install.sh) >/dev/null 2>&1 || true
    fi
    setup_singbox_service

    echo ""
    echo -e "${BLUE}── 步骤 4：配置 sing-box ──${NC}"
    configure_singbox

    echo ""
    echo -e "${BLUE}── 步骤 5：sing-box 服务 ──${NC}"
    systemctl enable sing-box
    systemctl restart sing-box
    systemctl is-active --quiet sing-box && log_success "sing-box 运行中" || log_warn "sing-box 启动失败，请检查配置"

    echo ""
    echo -e "${BLUE}── 步骤 6：生成节点链接 ──${NC}"
    generate_links

    press_enter
}

# ────────────────────────────────────────────────────────────────
#  主菜单
# ────────────────────────────────────────────────────────────────
main_menu() {
    # 保证主循环不因个别子命令返回非零值而意外退出
    set +e 
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║          服务器一键管理脚本  ($SCRIPT_VERSION)            ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  部署流程:"
        echo -e "   ${GREEN}1.${NC} 基础设置（SSH/fail2ban/BBR）       ${GREEN}2.${NC} SSL 证书申请与安装"
        echo -e "   ${GREEN}3.${NC} 安装 sing-box                      ${GREEN}4.${NC} 配置 sing-box"
        echo -e "   ${GREEN}5.${NC} sing-box 服务管理                  ${GREEN}6.${NC} 生成节点链接"
        echo ""
        echo -e "   ${YELLOW}7.${NC} ── 全部执行（1→6）──"
        echo ""
        echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
        echo "   0. 退出"
        echo ""
        read -rp "请选择: " opt
        
        # 处理空输入
        if [[ -z "$opt" ]]; then
            continue
        fi

        case $opt in
            1) detect_distro; menu_basic ;;
            2) menu_ssl ;;
            3) detect_distro; menu_install_service ;;
            4) configure_singbox ;;
            5) menu_service ;;
            6) menu_links ;;
            7) detect_distro; run_all ;;
            0)
                echo ""
                echo -e "${GREEN}感谢使用，再见！${NC}"
                echo -e "提示：退出脚本后，随时可以输入快捷命令 ${BOLD}${GREEN}jddj${NC} 重新进入主菜单。"
                echo ""
                exit 0 ;;
            *)
                log_warn "无效选项，请重新选择"
                sleep 1 ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  入口
# ────────────────────────────────────────────────────────────────
check_root
install_shortcut
main_menu
