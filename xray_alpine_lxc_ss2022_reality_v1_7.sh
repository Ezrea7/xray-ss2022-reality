#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# xray_alpine_lxc_ss2022_reality_v1_7.sh
# 仅保留：
#   1) Xray-core 安装/更新
#   2) 添加 Shadowsocks 2022-blake3-aes-256-gcm + REALITY
#   3) 卸载 Xray 与相关文件
# 目标：
#   - Alpine 可用
#   - LXC/OpenRC/无 init 环境可用
#   - 直接输出 Quantumult X 节点
#   - 不额外加入无关功能
# ============================================================

SCRIPT_VERSION="1.7.0"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_CLIENT_DIR="${XRAY_DIR}/clients"
XRAY_PID_FILE="/run/xray.pid"
XRAY_LOG_FILE="/var/log/xray.log"
DEFAULT_SNI="www.amd.com"
SHORTCUT_CMD="/usr/local/bin/ss2022"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()    { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn()    { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_error()   { echo -e "${RED}[错误] $1${NC}" >&2; }

_check_root() {
    if [ "${EUID}" -ne 0 ]; then
        _error "请使用 root 权限运行此脚本。"
        exit 1
    fi
}

_detect_init_system() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
    fi
}

_get_script_realpath() {
    local script_path="${BASH_SOURCE[0]:-}"
    [ -z "$script_path" ] && return 1
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$script_path" 2>/dev/null || printf "%s\n" "$script_path"
    else
        printf "%s\n" "$script_path"
    fi
}

_install_shortcut() {
    local script_path
    script_path="$(_get_script_realpath || true)"

    if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
        _warn "当前运行方式无法自动安装快捷命令 ss2022。请将脚本保存为本地文件后再运行一次。"
        return 0
    fi

    mkdir -p "$(dirname "$SHORTCUT_CMD")"
    if install -m 755 "$script_path" "$SHORTCUT_CMD"; then
        _success "已安装快捷命令: ss2022"
    else
        _warn "快捷命令安装失败，已跳过。"
    fi
}

_pkg_install() {
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    else
        _error "未识别到受支持的包管理器。"
        exit 1
    fi
}

_ensure_deps() {
    local missing=()
    local deps=(curl wget jq unzip openssl)
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        _info "正在安装依赖: ${missing[*]}"
        _pkg_install "${missing[@]}"
    fi

    _pkg_install ca-certificates >/dev/null 2>&1 || true

    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            _pkg_install iproute2 >/dev/null 2>&1 || _pkg_install net-tools >/dev/null 2>&1 || true
        elif command -v apt-get >/dev/null 2>&1; then
            _pkg_install iproute2 >/dev/null 2>&1 || _pkg_install net-tools >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            _pkg_install iproute >/dev/null 2>&1 || _pkg_install net-tools >/dev/null 2>&1 || true
        fi
    fi
}

_is_running_pid() {
    local pid="$1"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_manual_start_xray() {
    mkdir -p /run /var/log

    if [ -f "$XRAY_PID_FILE" ]; then
        local old_pid
        old_pid="$(cat "$XRAY_PID_FILE" 2>/dev/null || true)"
        if _is_running_pid "$old_pid"; then
            return 0
        fi
        rm -f "$XRAY_PID_FILE"
    fi

    nohup "$XRAY_BIN" run -c "$XRAY_CONFIG" >> "$XRAY_LOG_FILE" 2>&1 &
    echo $! > "$XRAY_PID_FILE"
    sleep 1

    local new_pid
    new_pid="$(cat "$XRAY_PID_FILE" 2>/dev/null || true)"
    if ! _is_running_pid "$new_pid"; then
        _error "Xray 手动启动失败，请检查 ${XRAY_LOG_FILE}"
        return 1
    fi
}

_manual_stop_xray() {
    if [ ! -f "$XRAY_PID_FILE" ]; then
        return 0
    fi

    local pid
    pid="$(cat "$XRAY_PID_FILE" 2>/dev/null || true)"
    if _is_running_pid "$pid"; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        _is_running_pid "$pid" && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$XRAY_PID_FILE"
}

_manage_xray_service() {
    local action="$1"

    case "$INIT_SYSTEM" in
        systemd)
            if systemctl "$action" xray >/dev/null 2>&1; then
                return 0
            fi
            ;;
        openrc)
            if rc-service xray "$action" >/dev/null 2>&1; then
                return 0
            fi
            ;;
    esac

    case "$action" in
        start) _manual_start_xray ;;
        stop) _manual_stop_xray ;;
        restart)
            _manual_stop_xray
            _manual_start_xray
            ;;
        status)
            if [ -f "$XRAY_PID_FILE" ] && _is_running_pid "$(cat "$XRAY_PID_FILE" 2>/dev/null || true)"; then
                _success "Xray 正在运行（手动模式）。"
            else
                _warn "Xray 未运行。"
            fi
            ;;
        *)
            _error "不支持的服务动作: $action"
            return 1
            ;;
    esac
}

_create_xray_service() {
    case "$INIT_SYSTEM" in
        systemd)
            cat > /etc/systemd/system/xray.service <<EOF_SYSTEMD
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable xray >/dev/null 2>&1 || true
            ;;
        openrc)
            cat > /etc/init.d/xray <<'EOF_OPENRC'
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
pidfile="/run/xray.pid"
command_background=true

depend() {
    need net
    after firewall
}
EOF_OPENRC
            chmod +x /etc/init.d/xray
            rc-update add xray default >/dev/null 2>&1 || true
            ;;
        *)
            ;;
    esac
}

_get_public_ip() {
    if [ -n "${server_ip:-}" ] && [ "${server_ip}" != "null" ]; then
        printf '%s' "$server_ip"
        return 0
    fi

    local ip=""
    if command -v timeout >/dev/null 2>&1; then
        ip="$(timeout 5 curl -s4 --max-time 2 icanhazip.com 2>/dev/null || timeout 5 curl -s4 --max-time 2 ipinfo.io/ip 2>/dev/null || true)"
        [ -z "$ip" ] && ip="$(timeout 5 curl -s6 --max-time 2 icanhazip.com 2>/dev/null || true)"
    else
        ip="$(curl -fsS4 --max-time 5 icanhazip.com 2>/dev/null || curl -fsS4 --max-time 5 ipinfo.io/ip 2>/dev/null || true)"
        [ -z "$ip" ] && ip="$(curl -fsS6 --max-time 5 icanhazip.com 2>/dev/null || true)"
    fi

    ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
    server_ip="$ip"
    printf '%s' "$ip"
}

_check_port_occupied() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]" && return 0
        ss -uln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]" && return 0
        netstat -uln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]" && return 0
    fi

    return 1
}

_check_xray_port_conflict() {
    local port="$1"

    if _check_port_occupied "$port"; then
        _error "端口 ${port} 已被系统占用。"
        return 0
    fi

    if [ -f "$XRAY_CONFIG" ] && jq -e --argjson port "$port" '.inbounds[]? | select(.port == $port)' "$XRAY_CONFIG" >/dev/null 2>&1; then
        _error "端口 ${port} 已被当前 Xray 配置占用。"
        return 0
    fi

    return 1
}

_input_port() {
    local port=""
    while true; do
        read -rp "请输入监听端口: " port
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            _error "请输入有效端口。"
            continue
        fi
        if _check_xray_port_conflict "$port"; then
            continue
        fi
        printf '%s' "$port"
        return 0
    done
}


_ensure_xray_base_config() {
    mkdir -p "$XRAY_DIR" "$XRAY_CLIENT_DIR"
    if [ ! -s "$XRAY_CONFIG" ]; then
        cat > "$XRAY_CONFIG" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": []
  }
}
JSON
    fi
}

_validate_xray_config() {
    "$XRAY_BIN" run -test -c "$1" >/dev/null 2>&1
}

_append_inbound_checked() {
    local inbound_json="$1"
    local tmp="${XRAY_CONFIG}.tmp.$$"

    jq --argjson inbound "$inbound_json" '.inbounds += [$inbound]' "$XRAY_CONFIG" > "$tmp"

    if ! _validate_xray_config "$tmp"; then
        rm -f "$tmp"
        _error "新配置未通过 Xray 校验，已取消写入。"
        return 1
    fi

    mv "$tmp" "$XRAY_CONFIG"
}

_install_xray() {
    _ensure_deps
    _detect_init_system

    local arch="$(uname -m)"
    local xray_arch=""
    case "$arch" in
        x86_64|amd64) xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l|armv7) xray_arch="arm32-v7a" ;;
        armv6l|armv6) xray_arch="arm32-v6" ;;
        *)
            _error "暂不支持的架构: ${arch}"
            return 1
            ;;
    esac

    local download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
    local dgst_url="${download_url}.dgst"
    local tmp_dir tmp_zip dgst_content expected_hash actual_hash version

    tmp_dir="$(mktemp -d)"
    tmp_zip="${tmp_dir}/xray.zip"

    _info "正在下载 Xray-core..."
    if ! wget -qO "$tmp_zip" "$download_url"; then
        rm -rf "$tmp_dir"
        _error "Xray-core 下载失败。"
        return 1
    fi

    dgst_content="$(wget -qO- "$dgst_url" 2>/dev/null || true)"
    if [ -n "$dgst_content" ]; then
        expected_hash="$(echo "$dgst_content" | grep 'SHA2-256' | head -1 | awk -F'= ' '{print $2}' | tr -d '[:space:]')"
        if [ -n "$expected_hash" ]; then
            actual_hash="$(sha256sum "$tmp_zip" | awk '{print $1}')"
            if [ "${expected_hash,,}" != "${actual_hash,,}" ]; then
                rm -rf "$tmp_dir"
                _error "Xray-core SHA256 校验失败。"
                return 1
            fi
        fi
    fi

    unzip -qo "$tmp_zip" -d "$tmp_dir"
    install -m 755 "${tmp_dir}/xray" "$XRAY_BIN"

    mkdir -p "$XRAY_DIR"
    [ -f "${tmp_dir}/geoip.dat" ] && install -m 644 "${tmp_dir}/geoip.dat" "${XRAY_DIR}/geoip.dat"
    [ -f "${tmp_dir}/geosite.dat" ] && install -m 644 "${tmp_dir}/geosite.dat" "${XRAY_DIR}/geosite.dat"

    rm -rf "$tmp_dir"

    _ensure_xray_base_config
    _create_xray_service

    if ! _validate_xray_config "$XRAY_CONFIG"; then
        _error "基础配置校验失败，请检查 ${XRAY_CONFIG}"
        return 1
    fi

    version="$($XRAY_BIN version 2>/dev/null | head -1 | awk '{print $2}')"
    _manage_xray_service restart || _manage_xray_service start || true
    _success "Xray-core v${version:-unknown} 安装/更新完成。"
}

_generate_reality_keys() {
    local keypair
    keypair="$($XRAY_BIN x25519 2>&1)"
    REALITY_PRIVATE_KEY="$(echo "$keypair" | awk 'NR==1 {print $NF}')"
    REALITY_PUBLIC_KEY="$(echo "$keypair" | awk 'NR==2 {print $NF}')"
    REALITY_SHORT_ID="$(openssl rand -hex 8)"

    if [ -z "${REALITY_PRIVATE_KEY}" ] || [ -z "${REALITY_PUBLIC_KEY}" ]; then
        _error "REALITY 密钥生成失败。"
        echo "$keypair" >&2
        return 1
    fi
}

_write_client_template() {
    local node_ip="$1"
    local port="$2"
    local sni="$3"
    local password="$4"
    local name="$5"
    local file="$6"

    jq -n \
        --arg server "$node_ip" \
        --argjson port "$port" \
        --arg method "2022-blake3-aes-256-gcm" \
        --arg ss_password "$password" \
        --arg server_name "$sni" \
        --arg fp "chrome" \
        --arg sid "$REALITY_SHORT_ID" \
        --arg pbk "$REALITY_PUBLIC_KEY" \
        --arg tag "$name" \
        '{
            outbounds: [
              {
                tag: $tag,
                protocol: "shadowsocks",
                settings: {
                  address: $server,
                  port: $port,
                  method: $method,
                  password: $ss_password,
                  uot: true,
                  UoTVersion: 1
                },
                streamSettings: {
                  network: "raw",
                  security: "reality",
                  realitySettings: {
                    serverName: $server_name,
                    fingerprint: "chrome",
                    shortId: $sid,
                    password: $pbk
                  }
                }
              }
            ]
        }' > "$file"
}

_build_quantumultx_line() {
    local node_ip="$1"
    local port="$2"
    local sni="$3"
    local password="$4"
    local name="$5"

    printf 'shadowsocks=%s:%s, method=2022-blake3-aes-256-gcm, password=%s, obfs=over-tls, obfs-host=%s, reality-base64-pubkey=%s, reality-hex-shortid=%s, udp-relay=true, udp-over-tcp=sp.v1, tag=%s\n' \
        "$node_ip" "$port" "$password" "$sni" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$name"
}

_detect_listen_host() {
    if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "1" ]; then
        printf '0.0.0.0'
        return 0
    fi

    if command -v ip >/dev/null 2>&1 && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        printf '::'
    else
        printf '0.0.0.0'
    fi
}

_add_ss2022_reality() {
    if [ ! -x "$XRAY_BIN" ]; then
        _error "请先安装 Xray-core。"
        return 1
    fi

    _ensure_xray_base_config

    local server_ip node_ip port sni name default_name inbound client_file password qx_line listen_host

    server_ip="$(_get_public_ip)"
    if [ -n "$server_ip" ]; then
        read -rp "请输入服务器 IP (回车默认当前检测 IP: ${server_ip}): " node_ip
        node_ip="${node_ip:-$server_ip}"
    else
        _warn "未能自动检测到当前公网 IP，请手动输入。"
        read -rp "请输入服务器 IP: " node_ip
    fi
    [ -z "$node_ip" ] && { _error "服务器 IP 不能为空。"; return 1; }

    port="$(_input_port)"

    read -rp "请输入伪装域名 SNI (默认: ${DEFAULT_SNI}): " sni
    sni="${sni:-$DEFAULT_SNI}"


    default_name="SS2022-REALITY-${port}"
    read -rp "请输入节点名称 (默认: ${default_name}): " name
    name="${name:-$default_name}"

    password="$(openssl rand -base64 32)"
    _generate_reality_keys || return 1
    listen_host="$(_detect_listen_host)"

    inbound=$(jq -n \
        --arg tag "ss2022-reality-${port}" \
        --arg listen_host "$listen_host" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg private_key "$REALITY_PRIVATE_KEY" \
        --arg short_id "$REALITY_SHORT_ID" \
        '{
            tag: $tag,
            listen: $listen_host,
            port: $port,
            protocol: "shadowsocks",
            settings: {
              network: "tcp",
              method: "2022-blake3-aes-256-gcm",
              password: $password
            },
            streamSettings: {
              network: "raw",
              security: "reality",
              realitySettings: {
                show: false,
                target: ($sni + ":443"),
                xver: 0,
                serverNames: [$sni],
                privateKey: $private_key,
                shortIds: [$short_id]
              }
            }
        }')

    _append_inbound_checked "$inbound" || return 1
    _manage_xray_service restart || true

    client_file="${XRAY_CLIENT_DIR}/ss2022-reality-${port}-client.json"
    _write_client_template "$node_ip" "$port" "$sni" "$password" "$name" "$client_file"
    qx_line="$(_build_quantumultx_line "$node_ip" "$port" "$sni" "$password" "$name")"

    _success "SS2022 + REALITY 节点添加成功。"
    echo -e "${YELLOW}服务器:${NC} ${node_ip}:${port}"
    echo -e "${YELLOW}协议:${NC} shadowsocks + reality"
    echo -e "${YELLOW}加密:${NC} 2022-blake3-aes-256-gcm"
    echo -e "${YELLOW}SS 密钥:${NC} ${password}"
    echo -e "${YELLOW}SNI:${NC} ${sni}"
    echo -e "${YELLOW}Reality Target:${NC} ${sni}:443"
    echo -e "${YELLOW}REALITY PublicKey:${NC} ${REALITY_PUBLIC_KEY}"
    echo -e "${YELLOW}REALITY ShortID:${NC} ${REALITY_SHORT_ID}"
    echo -e "${YELLOW}监听地址:${NC} ${listen_host}"
    echo -e "${YELLOW}Quantumult X:${NC}"
    echo "$qx_line"
    echo -e "${YELLOW}客户端模板:${NC} ${client_file}"
    echo -e "${YELLOW}说明:${NC} 只需自定义监听端口和 SNI；Reality target 固定为 SNI:443。服务端只监听 TCP，由客户端通过 udp-over-tcp=sp.v1 承载 UDP，更适合 Alpine/LXC。"
}


_uninstall_xray() {
    local answer=""
    read -rp "确认卸载 Xray、配置文件、客户端模板和快捷命令 ss2022 吗？[y/N]: " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) _warn "已取消卸载。"; return 0 ;;
    esac

    _manage_xray_service stop || true

    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable xray >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/xray.service
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        openrc)
            rc-update del xray default >/dev/null 2>&1 || true
            rm -f /etc/init.d/xray
            ;;
    esac

    rm -f "$XRAY_BIN" "$XRAY_PID_FILE" "$XRAY_LOG_FILE" "$SHORTCUT_CMD"
    rm -rf "$XRAY_DIR"

    _success "卸载完成。"
}

_show_menu() {
    clear
    echo "=================================================="
    echo " Xray 极简脚本 v${SCRIPT_VERSION}"
    echo " Alpine / LXC 兼容版"
    echo "=================================================="
    echo " 1) 安装/更新 Xray-core"
    echo " 2) 添加 SS2022 + REALITY"
    echo " 3) 卸载 Xray"
    echo " 0) 退出"
    echo "=================================================="
}

main() {
    _check_root
    _detect_init_system
    _install_shortcut

    while true; do
        _show_menu
        read -rp "请选择 [0-3]: " choice
        case "$choice" in
            1) _install_xray ;;
            2) _add_ss2022_reality ;;
            3) _uninstall_xray ;;
            0) exit 0 ;;
            *) _error "无效选择。" ;;
        esac
        echo
        read -rp "按回车继续..." _
    done
}

main "$@"
