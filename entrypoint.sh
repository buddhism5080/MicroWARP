#!/bin/sh
set -e

if [ "${MICROWARP_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

WG_CONF="/etc/wireguard/wg0.conf"
ROTATE_IP_ON_START="${ROTATE_IP_ON_START:-0}"
WARP_STACK_MODE=$(printf '%s' "${WARP_STACK:-ipv6-preferred}" | tr '[:upper:]' '[:lower:]')
WARP_API_URL="${WARP_API_URL:-https://warp.cloudflare.nyc.mn/?run=register&format=wireguard}"
WARP_API_PROXY="${WARP_API_PROXY:-}"
TEST_URLS_CHECK_INTERVAL="${TEST_URLS_CHECK_INTERVAL:-900}"
TZ="${TZ:-Asia/Shanghai}"
export TZ
mkdir -p /etc/wireguard

# SOCKS5 代理配置
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}
SOCKS_PID=""
SOCKS_ONLINE_AT_EPOCH=""
SOCKS_ONLINE_AT_TEXT=""
HAPROXY_PID=""
HAPROXY_CFG="/var/run/microwarp/haproxy.cfg"
INSTANCE_STATE_DIR="/var/run/microwarp"
MAX_WARP_INSTANCES=100
INSTANCE_SUBNET_PREFIX="10.66"
INSTANCE_START_STAGGER_SECONDS=1
# If an instance stays offline this long, treat its WARP conf as stale and force re-register.
# Default 7200s = 2 hours. Set 0 to disable.
CONFIG_STALE_OFFLINE_SECONDS="${CONFIG_STALE_OFFLINE_SECONDS:-7200}"
WARP_INSTANCE_COUNT=1

is_enabled() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

get_warp_instance_count() {
    RAW_COUNT=${WARP_INSTANCES:-1}

    case "$RAW_COUNT" in
        ''|*[!0-9]*)
            printf '1\n'
            return 0
            ;;
    esac

    if [ "$RAW_COUNT" -lt 1 ]; then
        printf '1\n'
        return 0
    fi

    if [ "$RAW_COUNT" -gt "$MAX_WARP_INSTANCES" ]; then
        printf '%s\n' "$MAX_WARP_INSTANCES"
        return 0
    fi

    printf '%s\n' "$RAW_COUNT"
}

get_instance_ids() {
    COUNT=${1:-1}
    IDS=""
    I=1
    while [ "$I" -le "$COUNT" ]; do
        if [ -n "$IDS" ]; then
            IDS="$IDS $I"
        else
            IDS="$I"
        fi
        I=$((I + 1))
    done
    printf '%s\n' "$IDS"
}

get_instance_netns_name() {
    printf 'mw%s\n' "$1"
}

get_instance_conf_path() {
    printf '/etc/wireguard/instances/%s/wg0.conf\n' "$1"
}

get_instance_wg_name() {
    printf 'mw%s\n' "$1"
}

get_instance_host_veth() {
    printf 'mw-h%s\n' "$1"
}

get_instance_ns_veth() {
    printf 'mw-n%s\n' "$1"
}

get_instance_host_ip() {
    printf '%s.%s.1\n' "$INSTANCE_SUBNET_PREFIX" "$1"
}

get_instance_ns_ip() {
    printf '%s.%s.2\n' "$INSTANCE_SUBNET_PREFIX" "$1"
}

get_instance_socks_endpoint() {
    printf '%s:%s\n' "$(get_instance_ns_ip "$1")" "1080"
}

get_instance_status_file() {
    printf '%s/inst%s.status\n' "$INSTANCE_STATE_DIR" "$1"
}

get_instance_pid_file() {
    printf '%s/inst%s.pid\n' "$INSTANCE_STATE_DIR" "$1"
}

get_instance_recover_pid_file() {
    printf '%s/inst%s.recover.pid\n' "$INSTANCE_STATE_DIR" "$1"
}

get_instance_offline_since_file() {
    # Persist next to conf so restart does not reset the "offline for 2h" clock.
    printf '/etc/wireguard/instances/%s/offline_since\n' "$1"
}

get_single_offline_since_file() {
    printf '/etc/wireguard/offline_since\n'
}

get_config_stale_offline_seconds() {
    RAW=${CONFIG_STALE_OFFLINE_SECONDS:-7200}
    case "$RAW" in
        ''|*[!0-9]*)
            printf '7200\n'
            return 0
            ;;
    esac
    printf '%s\n' "$RAW"
}

# Returns 0 if offline long enough that conf should be considered stale.
is_offline_long_enough_for_stale_config() {
    OFFLINE_SINCE_EPOCH=$1
    NOW_EPOCH=$(date +%s)
    THRESHOLD=$(get_config_stale_offline_seconds)

    if [ "$THRESHOLD" -le 0 ]; then
        return 1
    fi

    case "$OFFLINE_SINCE_EPOCH" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    ELAPSED=$((NOW_EPOCH - OFFLINE_SINCE_EPOCH))
    if [ "$ELAPSED" -lt 0 ]; then
        ELAPSED=0
    fi

    [ "$ELAPSED" -ge "$THRESHOLD" ]
}

record_instance_offline_since() {
    INST_ID=$1
    FILE=$(get_instance_offline_since_file "$INST_ID")
    mkdir -p "$(dirname "$FILE")"
    if [ ! -f "$FILE" ]; then
        date +%s > "$FILE"
        echo "==> [MicroWARP] [inst${INST_ID}] 开始累计离线时间（超过 $(get_config_stale_offline_seconds)s 未上线将强制换新配置）"
    fi
}

clear_instance_offline_since() {
    INST_ID=$1
    rm -f "$(get_instance_offline_since_file "$INST_ID")"
}

get_instance_offline_since_epoch() {
    FILE=$(get_instance_offline_since_file "$1")
    if [ -f "$FILE" ]; then
        tr -d '\n' < "$FILE"
    else
        printf ''
    fi
}

instance_should_force_new_config() {
    INST_ID=$1
    SINCE=$(get_instance_offline_since_epoch "$INST_ID")
    [ -n "$SINCE" ] || return 1
    is_offline_long_enough_for_stale_config "$SINCE"
}

record_single_offline_since() {
    FILE=$(get_single_offline_since_file)
    mkdir -p "$(dirname "$FILE")"
    if [ ! -f "$FILE" ]; then
        date +%s > "$FILE"
        echo "==> [MicroWARP] 开始累计离线时间（超过 $(get_config_stale_offline_seconds)s 未上线将强制换新配置）"
    fi
}

clear_single_offline_since() {
    rm -f "$(get_single_offline_since_file)"
}

single_should_force_new_config() {
    FILE=$(get_single_offline_since_file)
    [ -f "$FILE" ] || return 1
    SINCE=$(tr -d '\n' < "$FILE")
    is_offline_long_enough_for_stale_config "$SINCE"
}

get_haproxy_lock_dir() {
    printf '%s/haproxy.lock.d\n' "$INSTANCE_STATE_DIR"
}

get_register_lock_dir() {
    printf '%s/register.lock.d\n' "$INSTANCE_STATE_DIR"
}

# mkdir-based lock (no flock dependency on Alpine busybox)
with_dir_lock() {
    LOCK_DIR=$1
    shift
    mkdir -p "$(dirname "$LOCK_DIR")"
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 1
    done
    "$@"
    STATUS=$?
    rmdir "$LOCK_DIR" 2>/dev/null || true
    return $STATUS
}

is_instance_recovering() {
    INST_ID=$1
    PID_FILE=$(get_instance_recover_pid_file "$INST_ID")
    if [ ! -f "$PID_FILE" ]; then
        return 1
    fi
    PID=$(tr -d '\n' < "$PID_FILE")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        return 0
    fi
    rm -f "$PID_FILE"
    return 1
}

stop_instance_recovery() {
    INST_ID=$1
    PID_FILE=$(get_instance_recover_pid_file "$INST_ID")
    if [ -f "$PID_FILE" ]; then
        PID=$(tr -d '\n' < "$PID_FILE")
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
            # Do not wait long; recovery may be mid-curl. Best-effort.
            i=0
            while [ "$i" -lt 20 ] && kill -0 "$PID" 2>/dev/null; do
                sleep 0.1 2>/dev/null || sleep 1
                i=$((i + 1))
            done
            kill -9 "$PID" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

stop_all_instance_recoveries() {
    for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        stop_instance_recovery "$INST_ID"
    done
}

render_haproxy_config() {
    BIND_IP=$1
    BIND_P=$2
    STATUS_LIST=$3

    cat <<EOF
global
    daemon
    maxconn 4096

defaults
    mode tcp
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    option redispatch

frontend socks_in
    bind ${BIND_IP}:${BIND_P}
    default_backend warp_pool

backend warp_pool
    balance roundrobin
    option tcp-check
EOF

    OLD_IFS=$IFS
    IFS=' '
    for ITEM in $STATUS_LIST; do
        [ -n "$ITEM" ] || continue
        INST_ID=${ITEM%%:*}
        INST_STATUS=${ITEM#*:}
        [ "$INST_STATUS" = "up" ] || continue
        ENDPOINT=$(get_instance_socks_endpoint "$INST_ID")
        printf '    server inst%s %s check inter 3s fall 2 rise 1\n' "$INST_ID" "$ENDPOINT"
    done
    IFS=$OLD_IFS
}

print_warp_identity_summary() {
    TARGET_CONF=${1:-$WG_CONF}
    LABEL=${2:-}

    PRIVATE_KEY=$(awk -F ' = ' '/^PrivateKey = / {print $2; exit}' "$TARGET_CONF")
    IPV4_ADDRESS=$(grep '^Address =' "$TARGET_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    IPV6_ADDRESS=$(grep '^Address =' "$TARGET_CONF" | grep -oE '([0-9a-fA-F:]+:+)+[0-9a-fA-F]+' | head -n 1)
    ENDPOINT=$(awk -F ' = ' '/^Endpoint = / {print $2; exit}' "$TARGET_CONF")
    PRIVATE_KEY_FINGERPRINT=$(printf '%s' "$PRIVATE_KEY" | sha256sum | awk '{print substr($1,1,16)}')

    if [ -n "$LABEL" ]; then
        echo "==> [MicroWARP] WARP 设备身份摘要 [${LABEL}]:"
    else
        echo "==> [MicroWARP] WARP 设备身份摘要:"
    fi
    echo "==> [MicroWARP]   PrivateKey SHA256/16: ${PRIVATE_KEY_FINGERPRINT}"
    [ -n "$IPV4_ADDRESS" ] && echo "==> [MicroWARP]   Interface IPv4: ${IPV4_ADDRESS}"
    [ -n "$IPV6_ADDRESS" ] && echo "==> [MicroWARP]   Interface IPv6: ${IPV6_ADDRESS}"
    [ -n "$ENDPOINT" ] && echo "==> [MicroWARP]   Peer Endpoint: ${ENDPOINT}"
}

pick_endpoint_ip() {
    CLEAN_ENDPOINTS=$(printf '%s' "$ENDPOINT_IP" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
    [ -z "$CLEAN_ENDPOINTS" ] && return 1

    ENDPOINT_COUNT=$(printf '%s\n' "$CLEAN_ENDPOINTS" | wc -l | tr -d ' ')
    SELECTED_INDEX=$(( ($(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ') % ENDPOINT_COUNT) + 1 ))
    SELECTED_ENDPOINT=$(printf '%s\n' "$CLEAN_ENDPOINTS" | sed -n "${SELECTED_INDEX}p")
    [ -n "$SELECTED_ENDPOINT" ] || return 1

    ENDPOINT_IP_SELECTED="$SELECTED_ENDPOINT"
    return 0
}

fetch_warp_config() {
    API_URLS=$(printf '%s' "$WARP_API_URL" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
    [ -n "$API_URLS" ] || return 1

    OLD_IFS=$IFS
    IFS='
'
    for API_URL in $API_URLS; do
        [ -n "$API_URL" ] || continue
        echo "==> [MicroWARP] API 地址: ${API_URL}"

        if [ -n "$WARP_API_PROXY" ]; then
            echo "==> [MicroWARP] API 请求将通过已配置代理发起"
            curl --proxy "$WARP_API_PROXY" --retry 3 --retry-delay 2 --max-time 15 --silent --location --fail \
                "$API_URL" > "$raw_conf" && {
                IFS=$OLD_IFS
                return 0
            }
        else
            curl --retry 3 --retry-delay 2 --max-time 15 --silent --location --fail \
                "$API_URL" > "$raw_conf" && {
                IFS=$OLD_IFS
                return 0
            }
        fi

        echo "==> [MicroWARP] [WARN] API 请求失败，尝试下一个地址..."
    done

    IFS=$OLD_IFS
    return 1
}

generate_warp_config() {
    local target_conf=${1:-$WG_CONF}
    local max_retries=3
    local attempt=1
    local raw_conf="/tmp/wg0.api.$$"
    local target_dir

    target_dir=$(dirname "$target_conf")
    mkdir -p "$target_dir"

    while [ "$attempt" -le "$max_retries" ]; do
        echo "==> [MicroWARP] 正在向 API 注册新设备 (第${attempt}次尝试)... -> ${target_conf}"

        if fetch_warp_config; then

            sed -i 's/\r$//' "$raw_conf"

            if grep -q '^\[Interface\]' "$raw_conf" &&
               grep -q '^\[Peer\]' "$raw_conf" &&
               grep -q '^PrivateKey[[:space:]]*=' "$raw_conf" &&
               grep -q '^PublicKey[[:space:]]*=' "$raw_conf" &&
               grep -q '^Endpoint[[:space:]]*=' "$raw_conf"; then

                PRIVATE_KEY=$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$raw_conf" | head -n1)
                PUBLIC_KEY=$(sed -n 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*//p' "$raw_conf" | head -n1)
                ENDPOINT=$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' "$raw_conf" | head -n1)
                MTU=$(sed -n 's/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*//p' "$raw_conf" | head -n1)

                IPV4_ADDR=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$raw_conf" \
                    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
                    | head -n1)

                IPV6_ADDR=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$raw_conf" \
                    | grep ':' \
                    | head -n1)

                [ -n "$PRIVATE_KEY" ] || { echo "==> [ERROR] PrivateKey 提取失败"; rm -f "$raw_conf"; attempt=$((attempt+1)); sleep 3; continue; }
                [ -n "$PUBLIC_KEY" ]  || { echo "==> [ERROR] PublicKey 提取失败";  rm -f "$raw_conf"; attempt=$((attempt+1)); sleep 3; continue; }
                [ -n "$ENDPOINT" ]    || { echo "==> [ERROR] Endpoint 提取失败";   rm -f "$raw_conf"; attempt=$((attempt+1)); sleep 3; continue; }

                if [ -n "$ENDPOINT_IP" ]; then
                    if pick_endpoint_ip; then
                        echo "==> [MicroWARP] 🔀 检测到自定义 Endpoint 候选，已随机选中节点: $ENDPOINT_IP_SELECTED"
                        ENDPOINT="$ENDPOINT_IP_SELECTED"
                    else
                        echo "==> [MicroWARP] 🔀 检测到自定义 Endpoint IP，正在覆盖默认节点: $ENDPOINT_IP"
                        ENDPOINT="$ENDPOINT_IP"
                    fi
                fi

                [ -n "$MTU" ] || MTU=1280

                {
                    echo "[Interface]"
                    echo "PrivateKey = $PRIVATE_KEY"

                    case "$WARP_STACK_MODE" in
                        ipv4-only)
                            [ -n "$IPV4_ADDR" ] && echo "Address = ${IPV4_ADDR}/32"
                            ;;
                        ipv6-only)
                            [ -n "$IPV6_ADDR" ] && echo "Address = ${IPV6_ADDR}/128"
                            ;;
                        ipv6-preferred|dual|*)
                            if [ -n "$IPV4_ADDR" ] && [ -n "$IPV6_ADDR" ]; then
                                echo "Address = ${IPV4_ADDR}/32, ${IPV6_ADDR}/128"
                            elif [ -n "$IPV4_ADDR" ]; then
                                echo "Address = ${IPV4_ADDR}/32"
                            elif [ -n "$IPV6_ADDR" ]; then
                                echo "Address = ${IPV6_ADDR}/128"
                            fi
                            ;;
                    esac

                    echo "MTU = $MTU"
                    echo
                    echo "[Peer]"
                    echo "PublicKey = $PUBLIC_KEY"

                    case "$WARP_STACK_MODE" in
                        ipv4-only)
                            echo "AllowedIPs = 0.0.0.0/0"
                            ;;
                        ipv6-only)
                            echo "AllowedIPs = ::/0"
                            ;;
                        ipv6-preferred|dual|*)
                            echo "AllowedIPs = 0.0.0.0/0, ::/0"
                            ;;
                    esac

                    echo "Endpoint = $ENDPOINT"
                    echo "PersistentKeepalive = 15"
                } > "$target_conf"

                rm -f "$raw_conf"
                echo "==> [MicroWARP] 节点配置生成成功！(${target_conf})"
                return 0
            fi
        fi

        echo "==> [MicroWARP] [WARN] 第${attempt}次返回无效配置，原始内容预览："
        head -30 "$raw_conf" 2>/dev/null || true
        rm -f "$raw_conf"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$max_retries" ] && sleep 5
    done

    echo "==> [MicroWARP] [ERROR] API 连续 ${max_retries} 次失败，无法生成有效配置！"
    exit 1
}

prepare_wg_quick_compat() {
    sed -i '/src_valid_mark/d' /usr/bin/wg-quick 2>/dev/null || true
}

start_warp_interface() {
    PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
    PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
    PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

    echo "==> [MicroWARP] 正在启动 Linux 内核级 wg0 网卡..."
    if ! wg-quick up wg0 > /dev/null 2>&1; then
        echo "==> [MicroWARP] [WARN] wg0 启动失败"
        return 1
    fi

    TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
    if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
        if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
            echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由"
        fi
    fi

    sleep 3
    echo "==> [MicroWARP] 隧道已启动"
    return 0
}

restart_warp_with_new_identity() {
    wg-quick down wg0 > /dev/null 2>&1 || true
    generate_warp_config
    print_warp_identity_summary
    start_warp_interface
}

# ==========================================
# SOCKS5 代理生命周期管理
# ==========================================
format_uptime_duration() {
    TOTAL_SECONDS=${1:-0}

    case "$TOTAL_SECONDS" in
        ''|*[!0-9-]*)
            TOTAL_SECONDS=0
            ;;
    esac

    [ "$TOTAL_SECONDS" -lt 0 ] && TOTAL_SECONDS=0

    DAYS=$((TOTAL_SECONDS / 86400))
    HOURS=$(( (TOTAL_SECONDS % 86400) / 3600 ))
    MINUTES=$(( (TOTAL_SECONDS % 3600) / 60 ))
    SECONDS=$((TOTAL_SECONDS % 60))

    if [ "$DAYS" -gt 0 ]; then
        printf '%dd %02dh %02dm %02ds\n' "$DAYS" "$HOURS" "$MINUTES" "$SECONDS"
        return 0
    fi

    printf '%02dh %02dm %02ds\n' "$HOURS" "$MINUTES" "$SECONDS"
}

record_socks_online_started_at() {
    SOCKS_ONLINE_AT_EPOCH=$(date +%s)
    SOCKS_ONLINE_AT_TEXT=$(date '+%Y-%m-%d %H:%M:%S %z')
}

print_socks_health_check_success() {
    if [ -z "$SOCKS_ONLINE_AT_EPOCH" ] || [ -z "$SOCKS_ONLINE_AT_TEXT" ]; then
        echo "==> [MicroWARP] 巡检通过，SOCKS 服务继续保持在线"
        return 0
    fi

    NOW_EPOCH=$(date +%s)
    UPTIME_SECONDS=$((NOW_EPOCH - SOCKS_ONLINE_AT_EPOCH))
    [ "$UPTIME_SECONDS" -lt 0 ] && UPTIME_SECONDS=0
    UPTIME_TEXT=$(format_uptime_duration "$UPTIME_SECONDS")

    echo "==> [MicroWARP] 巡检通过，SOCKS 服务继续保持在线（上线时间: ${SOCKS_ONLINE_AT_TEXT}，已上线: ${UPTIME_TEXT}）"
}

start_socks() {
    if [ -z "$SOCKS_PID" ] || ! kill -0 "$SOCKS_PID" 2>/dev/null; then
        echo "==> [MicroWARP] 🟢 节点状态健康，正在启动 SOCKS 服务..."
        if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
            microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS" > /dev/null 2>&1 &
        else
            microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" > /dev/null 2>&1 &
        fi
        SOCKS_PID=$!
        record_socks_online_started_at
        echo "==> [MicroWARP] 🚀 MicroSOCKS 已上线 (监听: ${LISTEN_ADDR}:${LISTEN_PORT}, PID: ${SOCKS_PID})"
    fi
}

stop_socks() {
    if [ -n "$SOCKS_PID" ] && kill -0 "$SOCKS_PID" 2>/dev/null; then
        echo "==> [MicroWARP] 🛑 切断 SOCKS 服务，避免请求黑洞..."
        kill "$SOCKS_PID" 2>/dev/null || true
        wait "$SOCKS_PID" 2>/dev/null || true
        echo "==> [MicroWARP] 🔻 SOCKS 服务已下线"
    fi

    SOCKS_PID=""
    SOCKS_ONLINE_AT_EPOCH=""
    SOCKS_ONLINE_AT_TEXT=""
}

# Extract a usable public IP from common probe response shapes:
# - Cloudflare trace: ip=x.x.x.x
# - plain text: x.x.x.x / 2a09:...
# - tiny JSON: {"ip":"..."} / "ip": "..."
extract_ip_from_probe_body() {
    BODY=$1
    FAMILY=${2:-any}   # v4 | v6 | any
    CANDIDATE=$(printf '%s\n' "$BODY" | tr -d '\r' | awk '
        BEGIN { found="" }
        {
            line=$0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /^ip=/) {
                sub(/^ip=/, "", line)
                found=line
                exit
            }
            if (match(line, /"ip"[[:space:]]*:[[:space:]]*"/)) {
                line=substr(line, RSTART)
                sub(/^"ip"[[:space:]]*:[[:space:]]*"/, "", line)
                sub(/".*/, "", line)
                found=line
                exit
            }
            # plain single-token body
            if (NF==1 && line !~ /[^0-9A-Fa-f:.]/) {
                found=line
                exit
            }
        }
        END { if (found != "") print found }
    ')

    [ -n "$CANDIDATE" ] || return 1
    CANDIDATE=$(printf '%s' "$CANDIDATE" | tr -d '[:space:]')

    case "$FAMILY" in
        v4)
            printf '%s\n' "$CANDIDATE" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
            ;;
        v6)
            # must look like IPv6 (contains colon, not dotted-quad only)
            case "$CANDIDATE" in
                *:*) ;;
                *) return 1 ;;
            esac
            printf '%s\n' "$CANDIDATE" | grep -Eq '^[0-9A-Fa-f:]+$' || return 1
            ;;
        *)
            ;;
    esac

    printf '%s\n' "$CANDIDATE"
    return 0
}

# Default multi-source lists (comma-separated). Prefer:
# - IP-literal HTTPS endpoints (no DNS dependency)
# - globally anycast / highly available providers
# Override via EGRESS_IP_V4_URLS / EGRESS_IP_V6_URLS if needed.
get_egress_ip_v4_urls() {
    RAW=${EGRESS_IP_V4_URLS:-https://1.1.1.1/cdn-cgi/trace,https://1.0.0.1/cdn-cgi/trace,https://cloudflare.com/cdn-cgi/trace,https://api.ipify.org,https://checkip.amazonaws.com,https://ipv4.icanhazip.com,https://ifconfig.me/ip}
    printf '%s\n' "$RAW"
}

get_egress_ip_v6_urls() {
    RAW=${EGRESS_IP_V6_URLS:-https://[2606:4700:4700::1111]/cdn-cgi/trace,https://[2606:4700:4700::1001]/cdn-cgi/trace,https://api64.ipify.org,https://ipv6.icanhazip.com}
    printf '%s\n' "$RAW"
}

get_egress_ip_curl_max_time() {
    RAW=${EGRESS_IP_CURL_MAX_TIME:-4}
    case "$RAW" in
        ''|*[!0-9]*) printf '4\n' ;;
        0) printf '1\n' ;;
        *) printf '%s\n' "$RAW" ;;
    esac
}

# Probe one family through optional netns. Sets PROBED_IP on success.
# Usage: probe_egress_ip_family <v4|v6> [netns_name]
probe_egress_ip_family() {
    FAMILY=$1
    NS_NAME=${2:-}
    PROBED_IP=''
    MAX_TIME=$(get_egress_ip_curl_max_time)

    if [ "$FAMILY" = "v4" ]; then
        URLS_RAW=$(get_egress_ip_v4_urls)
        CURL_FAMILY_FLAG='-4'
    else
        URLS_RAW=$(get_egress_ip_v6_urls)
        CURL_FAMILY_FLAG='-6'
    fi

    URLS=$(printf '%s' "$URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
    [ -n "$URLS" ] || return 1

    OLD_IFS=$IFS
    IFS='
'
    for URL in $URLS; do
        [ -n "$URL" ] || continue
        if [ -n "$NS_NAME" ]; then
            BODY=$(ip netns exec "$NS_NAME" curl $CURL_FAMILY_FLAG -sS -L --connect-timeout 2 -m "$MAX_TIME" \
                -A 'MicroWARP-health/1.0' --fail "$URL" 2>/dev/null || true)
        else
            BODY=$(curl $CURL_FAMILY_FLAG -sS -L --connect-timeout 2 -m "$MAX_TIME" \
                -A 'MicroWARP-health/1.0' --fail "$URL" 2>/dev/null || true)
        fi
        [ -n "$BODY" ] || continue
        if IP_VAL=$(extract_ip_from_probe_body "$BODY" "$FAMILY"); then
            PROBED_IP=$IP_VAL
            PROBED_IP_SOURCE=$URL
            IFS=$OLD_IFS
            return 0
        fi
    done
    IFS=$OLD_IFS
    return 1
}

# Best-effort dual-stack egress discovery. Never cuts traffic by itself.
# Returns 0 if at least one family succeeded; 1 if all sources failed.
# Sets TRACE_IP_V4 / TRACE_IP_V6 to "ip=..." lines (or empty).
probe_egress_ips() {
    NS_NAME=${1:-}
    LABEL=${2:-}
    TRACE_IP_V4=''
    TRACE_IP_V6=''
    PREFIX='==> [MicroWARP]'
    [ -n "$LABEL" ] && PREFIX="==> [MicroWARP] [${LABEL}]"

    PROBED_IP=''
    PROBED_IP_SOURCE=''
    if probe_egress_ip_family v4 "$NS_NAME"; then
        TRACE_IP_V4="ip=${PROBED_IP}"
        echo "${PREFIX} 出口 IPv4: ${PROBED_IP}  (via ${PROBED_IP_SOURCE})"
    fi

    PROBED_IP=''
    PROBED_IP_SOURCE=''
    if probe_egress_ip_family v6 "$NS_NAME"; then
        TRACE_IP_V6="ip=${PROBED_IP}"
        echo "${PREFIX} 出口 IPv6: ${PROBED_IP}  (via ${PROBED_IP_SOURCE})"
    fi

    if [ -n "$TRACE_IP_V4" ] || [ -n "$TRACE_IP_V6" ]; then
        return 0
    fi

    echo "${PREFIX} ⚠️ 出口 IP 多源探测均失败（不单独据此切断服务，继续以 TEST_URLS 为准）"
    return 1
}

ensure_trace_ip() {
    # Soft signal only: multi-source probe. Do NOT stop SOCKS here.
    # Hard fail / cut traffic is decided by run_health_checks + TEST_URLS.
    if probe_egress_ips '' ''; then
        return 0
    fi
    return 1
}

is_retryable_test_url_curl_exit() {
    case "${1:-}" in
        5|6|7|28|52|55|56)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

get_test_url_retry_reason() {
    case "${1:-}" in
        28)
            printf '请求超时\n'
            ;;
        5|6)
            printf 'DNS 波动\n'
            ;;
        7|52|55|56)
            printf '本地网络波动\n'
            ;;
        *)
            printf '可重试错误\n'
            ;;
    esac
}

check_single_test_url() {
    TARGET_URL=$1
    RETRYABLE_FAILURE_RETRIES=2
    ATTEMPT=1

    while true; do
        if TEST_HTTP_CODE=$(curl -A 'Mozilla/5.0' -sL -o /dev/null -w '%{http_code}' -m 10 "$TARGET_URL"); then
            CURL_EXIT=0
        else
            CURL_EXIT=$?
        fi

        [ -n "$TEST_HTTP_CODE" ] || TEST_HTTP_CODE="000"
        echo "==> [MicroWARP] 测速反馈 ${TARGET_URL} HTTP 状态码: ${TEST_HTTP_CODE}"

        if is_retryable_test_url_curl_exit "$CURL_EXIT" && [ "$ATTEMPT" -le "$RETRYABLE_FAILURE_RETRIES" ]; then
            RETRY_REASON=$(get_test_url_retry_reason "$CURL_EXIT")
            echo "==> [MicroWARP] ${TARGET_URL} ${RETRY_REASON}，5 秒后重试 (${ATTEMPT}/${RETRYABLE_FAILURE_RETRIES})..."
            ATTEMPT=$((ATTEMPT + 1))
            sleep 5
            continue
        fi

        case "$TEST_HTTP_CODE" in
            4*|5*|000|"")
                return 1
                ;;
        esac

        return 0
    done
}

check_test_urls() {
    TEST_URLS_RAW=${TEST_URLS:-https://grok.com}
    TEST_URLS_LIST=$(printf '%s' "$TEST_URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
    [ -n "$TEST_URLS_LIST" ] || return 0

    OLD_IFS=$IFS
    IFS='
'
    for TEST_URL in $TEST_URLS_LIST; do
        [ -n "$TEST_URL" ] || continue
        if ! check_single_test_url "$TEST_URL"; then
            IFS=$OLD_IFS
            return 1
        fi
    done

    IFS=$OLD_IFS
    return 0
}

get_wg_reconnect_retries() {
    RAW_RETRIES=${WG_RECONNECT_RETRIES:-5}

    case "$RAW_RETRIES" in
        '')
            printf '5\n'
            return 0
            ;;
        -*)
            printf '0\n'
            return 0
            ;;
        *[!0-9]*)
            printf '5\n'
            return 0
            ;;
    esac

    case "$RAW_RETRIES" in
        0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20)
            printf '%s\n' "$RAW_RETRIES"
            ;;
        *)
            printf '20\n'
            ;;
    esac
}

run_health_checks() {
    # Egress IP is diagnostic + best-effort. TEST_URLS is the real pass/fail gate
    # when configured. IP-only hard-fail only if no TEST_URLS are set.
    IP_OK=0
    ensure_trace_ip && IP_OK=1 || true

    TEST_URLS_RAW=${TEST_URLS:-https://grok.com}
    TEST_URLS_LIST=$(printf '%s' "$TEST_URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')

    if [ -n "$TEST_URLS_LIST" ]; then
        check_test_urls
        return $?
    fi

    # No TEST_URLS configured: fall back to IP probe as connectivity signal.
    [ "$IP_OK" -eq 1 ]
}

restart_wg_interface() {
    echo "==> [MicroWARP] 正在断开并重连 wg0..."
    wg-quick down wg0 > /dev/null 2>&1 || true
    if start_warp_interface; then
        return 0
    fi

    echo "==> [MicroWARP] [WARN] WG 接口重连失败"
    return 1
}

try_wg_reconnect_recovery() {
    RECONNECT_RETRIES=$(get_wg_reconnect_retries)

    if [ "$RECONNECT_RETRIES" -le 0 ]; then
        echo "==> [MicroWARP] 已禁用 WG 重连重试，跳过接口重连阶段"
        return 1
    fi

    ATTEMPT=1
    while [ "$ATTEMPT" -le "$RECONNECT_RETRIES" ]; do
        echo "==> [MicroWARP] 正在执行 WG 重连重试 (${ATTEMPT}/${RECONNECT_RETRIES})..."
        if restart_wg_interface && run_health_checks; then
            echo "==> [MicroWARP] WG 重连后健康检查已恢复"
            return 0
        fi

        ATTEMPT=$((ATTEMPT + 1))
        [ "$ATTEMPT" -le "$RECONNECT_RETRIES" ] && sleep 3
    done

    echo "==> [MicroWARP] [WARN] WG 重连重试全部失败"
    return 1
}

# ==========================================
# 核心网络就绪保证 (仅限发现异常进入修复或初次启动时)
# ==========================================
ensure_network_ready() {
    while true; do
        if run_health_checks; then
            start_socks
            clear_single_offline_since
            return 0
        fi

        echo "==> [MicroWARP] 连通性测试未通过！"
        stop_socks
        record_single_offline_since

        FORCE_NEW=0
        if single_should_force_new_config; then
            FORCE_NEW=1
            FILE=$(get_single_offline_since_file)
            SINCE=$(tr -d '\n' < "$FILE")
            NOW_EPOCH=$(date +%s)
            ELAPSED=$((NOW_EPOCH - SINCE))
            echo "==> [MicroWARP] 已连续离线 ${ELAPSED}s ≥ $(get_config_stale_offline_seconds)s，判定配置失效，跳过重连并强制换新配置"
        fi

        if [ "$FORCE_NEW" -eq 0 ]; then
            if try_wg_reconnect_recovery; then
                start_socks
                clear_single_offline_since
                return 0
            fi
            echo "==> [MicroWARP] WG 重连重试后仍未恢复，正在重新注册并重置节点..."
        fi

        restart_warp_with_new_identity
    done
}

periodic_test_url_monitor() {
    echo "==> [MicroWARP] 已启动守护模式，每 ${TEST_URLS_CHECK_INTERVAL} 秒进行一次健康巡检..."
    while true; do
        # 睡眠等待期间能随时响应容器的停止信号
        sleep "$TEST_URLS_CHECK_INTERVAL" & wait $!

        echo "==> [MicroWARP] 正在执行 TEST_URLS 巡检（间隔 ${TEST_URLS_CHECK_INTERVAL} 秒）..."

        # 巡检时直接发起检测，不干扰正常运行的 SOCKS
        if check_test_urls; then
            print_socks_health_check_success
            clear_single_offline_since
            continue
        fi

        # 只有在确诊不通返回了非零状态，才触发保护机制并切断网络
        echo "==> [MicroWARP] ❌ 巡检未通过！触发节点重选保护机制..."
        stop_socks
        record_single_offline_since

        # 进入修复死循环，修复成功后内部会重新调用 start_socks
        ensure_network_ready
    done
}

cleanup_on_exit() {
    echo "==> [MicroWARP] 收到退出信号，正在清理进程和网卡..."
    stop_socks
    wg-quick down wg0 >/dev/null 2>&1 || true
    exit 0
}

# ==========================================
# 多实例（单容器内）: netns + haproxy 健康 LB
# ==========================================
set_instance_status() {
    INST_ID=$1
    STATUS=$2
    mkdir -p "$INSTANCE_STATE_DIR"
    printf '%s\n' "$STATUS" > "$(get_instance_status_file "$INST_ID")"
}

get_instance_status() {
    STATUS_FILE=$(get_instance_status_file "$1")
    if [ -f "$STATUS_FILE" ]; then
        tr -d '\n' < "$STATUS_FILE"
    else
        printf 'down'
    fi
}

collect_instance_status_list() {
    LIST=""
    for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        STATUS=$(get_instance_status "$INST_ID")
        if [ -n "$LIST" ]; then
            LIST="$LIST ${INST_ID}:${STATUS}"
        else
            LIST="${INST_ID}:${STATUS}"
        fi
    done
    printf '%s\n' "$LIST"
}

count_healthy_instances() {
    COUNT=0
    for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        if [ "$(get_instance_status "$INST_ID")" = "up" ]; then
            COUNT=$((COUNT + 1))
        fi
    done
    printf '%s\n' "$COUNT"
}

enable_host_forwarding() {
    if [ -w /proc/sys/net/ipv4/ip_forward ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    fi
    # best-effort NAT for netns underlay traffic
    iptables -t nat -C POSTROUTING -s "${INSTANCE_SUBNET_PREFIX}.0.0/16" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "${INSTANCE_SUBNET_PREFIX}.0.0/16" -j MASQUERADE 2>/dev/null \
        || true
}

destroy_instance_netns() {
    INST_ID=$1
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    HOST_VETH=$(get_instance_host_veth "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")

    stop_instance_socks "$INST_ID"

    ip netns exec "$NS_NAME" wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    ip link delete "$HOST_VETH" >/dev/null 2>&1 || true
    ip netns delete "$NS_NAME" >/dev/null 2>&1 || true
}

setup_instance_netns() {
    INST_ID=$1
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    HOST_VETH=$(get_instance_host_veth "$INST_ID")
    NS_VETH=$(get_instance_ns_veth "$INST_ID")
    HOST_IP=$(get_instance_host_ip "$INST_ID")
    NS_IP=$(get_instance_ns_ip "$INST_ID")

    destroy_instance_netns "$INST_ID"

    echo "==> [MicroWARP] [inst${INST_ID}] 创建 netns ${NS_NAME} 与 veth 对"
    ip netns add "$NS_NAME"
    ip link add "$HOST_VETH" type veth peer name "$NS_VETH"
    ip link set "$NS_VETH" netns "$NS_NAME"

    ip addr add "${HOST_IP}/24" dev "$HOST_VETH"
    ip link set "$HOST_VETH" up

    ip netns exec "$NS_NAME" ip addr add "${NS_IP}/24" dev "$NS_VETH"
    ip netns exec "$NS_NAME" ip link set "$NS_VETH" up
    ip netns exec "$NS_NAME" ip link set lo up
    ip netns exec "$NS_NAME" ip route replace default via "$HOST_IP" dev "$NS_VETH"

    # DNS inside netns for any residual hostname lookups.
    # NEVER copy the container resolv.conf: Docker often points at 127.0.0.11,
    # which only exists in the default netns and is unreachable here.
    write_netns_resolv_conf "$NS_NAME"
}

write_netns_resolv_conf() {
    NS_NAME=$1
    mkdir -p "/etc/netns/${NS_NAME}"
    printf '%s\n' \
        'nameserver 1.1.1.1' \
        'nameserver 8.8.8.8' \
        'nameserver 2606:4700:4700::1111' \
        > "/etc/netns/${NS_NAME}/resolv.conf"
}

# Split "host:port", "[v6]:port", bare host, or bare IP into HOST + PORT (default 2408).
parse_endpoint_host_port() {
    EP=$1
    ENDPOINT_HOST=''
    ENDPOINT_PORT='2408'

    [ -n "$EP" ] || return 1

    case "$EP" in
        \[*\]:*)
            ENDPOINT_HOST=$(printf '%s\n' "$EP" | sed -n 's/^\[\(.*\)\]:\([0-9]\+\)$/\1/p')
            ENDPOINT_PORT=$(printf '%s\n' "$EP" | sed -n 's/^\[.*\]:\([0-9]\+\)$/\1/p')
            ;;
        *:*)
            # Only treat as host:port when there is a single colon (IPv4/hostname).
            # IPv6 literals without brackets contain multiple colons.
            COLON_COUNT=$(printf '%s' "$EP" | awk -F: '{print NF-1}')
            if [ "$COLON_COUNT" -eq 1 ]; then
                ENDPOINT_HOST=${EP%:*}
                ENDPOINT_PORT=${EP##*:}
            else
                ENDPOINT_HOST=$EP
                ENDPOINT_PORT=2408
            fi
            ;;
        *)
            ENDPOINT_HOST=$EP
            ENDPOINT_PORT=2408
            ;;
    esac

    [ -n "$ENDPOINT_HOST" ] || return 1
    case "$ENDPOINT_PORT" in
        ''|*[!0-9]*) ENDPOINT_PORT=2408 ;;
    esac
    return 0
}

is_ipv4_literal() {
    case "$1" in
        *[!0-9.]*|'') return 1 ;;
    esac
    # rough dotted-quad check
    printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

is_ipv6_literal() {
    case "$1" in
        *:*) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve on the *default* netns (container host ns). Never call this inside ip netns exec.
resolve_host_to_ip() {
    HOST=$1
    RES=''

    [ -n "$HOST" ] || return 1

    if is_ipv4_literal "$HOST" || is_ipv6_literal "$HOST"; then
        printf '%s\n' "$HOST"
        return 0
    fi

    # Prefer IPv4 — underlay veth path is IPv4.
    if command -v getent >/dev/null 2>&1; then
        RES=$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1 {print $1; exit}')
        if [ -z "$RES" ]; then
            RES=$(getent ahosts "$HOST" 2>/dev/null | awk 'NR==1 {print $1; exit}')
        fi
        if [ -z "$RES" ]; then
            RES=$(getent hosts "$HOST" 2>/dev/null | awk 'NR==1 {print $1; exit}')
        fi
    fi

    # Alpine image usually has busybox nslookup even without getent.
    if [ -z "$RES" ] && command -v nslookup >/dev/null 2>&1; then
        RES=$(nslookup "$HOST" 1.1.1.1 2>/dev/null | awk '
            /^Name:/ { found=1; next }
            found && /^Address/ {
                addr=$NF
                sub(/\r$/, "", addr)
                if (addr ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print addr; exit }
            }
        ')
    fi

    if [ -z "$RES" ] && command -v busybox >/dev/null 2>&1; then
        RES=$(busybox nslookup "$HOST" 1.1.1.1 2>/dev/null | awk '
            /^Name:/ { found=1; next }
            found && /^Address/ {
                addr=$NF
                sub(/\r$/, "", addr)
                if (addr ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print addr; exit }
            }
        ')
    fi

    if [ -z "$RES" ]; then
        return 1
    fi
    printf '%s\n' "$RES"
    return 0
}

format_endpoint_ip_port() {
    IP=$1
    PORT=$2
    if is_ipv6_literal "$IP" && ! is_ipv4_literal "$IP"; then
        printf '[%s]:%s\n' "$IP" "$PORT"
    else
        printf '%s:%s\n' "$IP" "$PORT"
    fi
}

# Materialize a runtime conf for wg-quick:
# - interface name = mwN (not wg0)
# - Endpoint hostname resolved in the default netns to a concrete IP
#   so netns startup does not depend on Docker's 127.0.0.11 stub resolver
prepare_instance_wg_conf() {
    INST_ID=$1
    CONF_PATH=$(get_instance_conf_path "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")
    WG_LINK_CONF="/etc/wireguard/${WG_NAME}.conf"
    RUNTIME_CONF="/etc/wireguard/${WG_NAME}.runtime.conf"

    mkdir -p /etc/wireguard

    if [ ! -f "$CONF_PATH" ]; then
        echo "==> [MicroWARP] [inst${INST_ID}] [ERROR] 缺少配置文件: ${CONF_PATH}"
        return 1
    fi

    # Start from the persisted conf (keeps keys/addresses intact).
    cp "$CONF_PATH" "$RUNTIME_CONF"

    RAW_ENDPOINT=$(awk -F ' = ' '/^[[:space:]]*Endpoint[[:space:]]*=/ {print $2; exit}' "$RUNTIME_CONF" | tr -d '\r')
    if [ -n "$RAW_ENDPOINT" ] && parse_endpoint_host_port "$RAW_ENDPOINT"; then
        if RESOLVED_IP=$(resolve_host_to_ip "$ENDPOINT_HOST"); then
            NEW_ENDPOINT=$(format_endpoint_ip_port "$RESOLVED_IP" "$ENDPOINT_PORT")
            if [ "$NEW_ENDPOINT" != "$RAW_ENDPOINT" ]; then
                echo "==> [MicroWARP] [inst${INST_ID}] Endpoint 预解析: ${RAW_ENDPOINT} -> ${NEW_ENDPOINT}"
            fi
            # Replace only the Endpoint line; keep the on-disk identity conf unchanged.
            sed -i "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = ${NEW_ENDPOINT}|" "$RUNTIME_CONF"
        else
            echo "==> [MicroWARP] [inst${INST_ID}] [WARN] 无法在默认 netns 解析 Endpoint 主机名: ${ENDPOINT_HOST}（仍尝试原值）"
        fi
    fi

    # wg-quick uses the conf basename as the interface name.
    ln -sfn "$RUNTIME_CONF" "$WG_LINK_CONF"
    return 0
}

start_instance_warp() {
    INST_ID=$1
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")
    HOST_IP=$(get_instance_host_ip "$INST_ID")
    NS_VETH=$(get_instance_ns_veth "$INST_ID")
    WG_LOG="/tmp/wg-up-inst${INST_ID}.log"

    if ! prepare_instance_wg_conf "$INST_ID"; then
        return 1
    fi

    # Clean any half-up interface from a previous attempt.
    ip netns exec "$NS_NAME" wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    ip netns exec "$NS_NAME" ip link delete "$WG_NAME" >/dev/null 2>&1 || true

    echo "==> [MicroWARP] [inst${INST_ID}] 正在 netns 内启动 WireGuard (${WG_NAME})..."
    # Bound the up attempt: DNS/UDP stalls must not freeze serial multi-instance boot.
    # Do NOT use eval with nested quotes — call timeout/wg-quick directly.
    if command -v timeout >/dev/null 2>&1; then
        UP_OK=0
        timeout 20 ip netns exec "$NS_NAME" wg-quick up "$WG_NAME" >"$WG_LOG" 2>&1 && UP_OK=1
    else
        UP_OK=0
        ip netns exec "$NS_NAME" wg-quick up "$WG_NAME" >"$WG_LOG" 2>&1 && UP_OK=1
    fi

    if [ "$UP_OK" -ne 1 ]; then
        echo "==> [MicroWARP] [inst${INST_ID}] [WARN] WireGuard 启动失败"
        if [ -s "$WG_LOG" ]; then
            echo "==> [MicroWARP] [inst${INST_ID}] wg-quick 输出:"
            tail -n 20 "$WG_LOG" | sed 's/^/    /'
        fi
        return 1
    fi

    # Ensure underlay connected route to host still wins for LB health/traffic ingress
    ip netns exec "$NS_NAME" ip route replace "${INSTANCE_SUBNET_PREFIX}.${INST_ID}.0/24" dev "$NS_VETH" 2>/dev/null || true
    ip netns exec "$NS_NAME" ip route replace "$HOST_IP" dev "$NS_VETH" 2>/dev/null || true

    # Pin a host route for the resolved endpoint via underlay so AllowedIPs=0.0.0.0/0
    # cannot blackhole WireGuard handshake packets back into the tunnel.
    RAW_ENDPOINT=$(awk -F ' = ' '/^[[:space:]]*Endpoint[[:space:]]*=/ {print $2; exit}' "/etc/wireguard/${WG_NAME}.runtime.conf" 2>/dev/null | tr -d '\r')
    if [ -n "$RAW_ENDPOINT" ] && parse_endpoint_host_port "$RAW_ENDPOINT"; then
        if is_ipv4_literal "$ENDPOINT_HOST"; then
            ip netns exec "$NS_NAME" ip route replace "$ENDPOINT_HOST" via "$HOST_IP" dev "$NS_VETH" 2>/dev/null || true
        elif is_ipv6_literal "$ENDPOINT_HOST"; then
            ip netns exec "$NS_NAME" ip -6 route replace "$ENDPOINT_HOST" via fe80::1 dev "$NS_VETH" 2>/dev/null || true
        fi
    fi

    sleep 2
    echo "==> [MicroWARP] [inst${INST_ID}] 隧道已启动"
    return 0
}

stop_instance_socks() {
    INST_ID=$1
    PID_FILE=$(get_instance_pid_file "$INST_ID")

    if [ -f "$PID_FILE" ]; then
        PID=$(tr -d '\n' < "$PID_FILE")
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "==> [MicroWARP] [inst${INST_ID}] 停止内部 SOCKS (PID: ${PID})"
            kill "$PID" 2>/dev/null || true
            wait "$PID" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

start_instance_socks() {
    INST_ID=$1
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    NS_IP=$(get_instance_ns_ip "$INST_ID")
    PID_FILE=$(get_instance_pid_file "$INST_ID")

    if [ -f "$PID_FILE" ]; then
        PID=$(tr -d '\n' < "$PID_FILE")
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            return 0
        fi
    fi

    echo "==> [MicroWARP] [inst${INST_ID}] 启动内部 MicroSOCKS (${NS_IP}:1080)"
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        ip netns exec "$NS_NAME" microsocks -i "$NS_IP" -p 1080 -u "$SOCKS_USER" -P "$SOCKS_PASS" > /dev/null 2>&1 &
    else
        ip netns exec "$NS_NAME" microsocks -i "$NS_IP" -p 1080 > /dev/null 2>&1 &
    fi
    echo $! > "$PID_FILE"
}

ns_ensure_trace_ip() {
    INST_ID=$1
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    # Soft: multi-source. Failure alone must not condemn the instance.
    probe_egress_ips "$NS_NAME" "inst${INST_ID}"
}

ns_check_single_test_url() {
    INST_ID=$1
    TARGET_URL=$2
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    RETRYABLE_FAILURE_RETRIES=2
    ATTEMPT=1

    while true; do
        if TEST_HTTP_CODE=$(ip netns exec "$NS_NAME" curl -A 'Mozilla/5.0' -sL -o /dev/null -w '%{http_code}' -m 10 "$TARGET_URL"); then
            CURL_EXIT=0
        else
            CURL_EXIT=$?
        fi

        [ -n "$TEST_HTTP_CODE" ] || TEST_HTTP_CODE="000"
        echo "==> [MicroWARP] [inst${INST_ID}] 测速反馈 ${TARGET_URL} HTTP 状态码: ${TEST_HTTP_CODE}"

        if is_retryable_test_url_curl_exit "$CURL_EXIT" && [ "$ATTEMPT" -le "$RETRYABLE_FAILURE_RETRIES" ]; then
            RETRY_REASON=$(get_test_url_retry_reason "$CURL_EXIT")
            echo "==> [MicroWARP] [inst${INST_ID}] ${TARGET_URL} ${RETRY_REASON}，5 秒后重试 (${ATTEMPT}/${RETRYABLE_FAILURE_RETRIES})..."
            ATTEMPT=$((ATTEMPT + 1))
            sleep 5
            continue
        fi

        case "$TEST_HTTP_CODE" in
            4*|5*|000|"")
                return 1
                ;;
        esac

        return 0
    done
}

ns_check_test_urls() {
    INST_ID=$1
    TEST_URLS_RAW=${TEST_URLS:-https://grok.com}
    TEST_URLS_LIST=$(printf '%s' "$TEST_URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
    [ -n "$TEST_URLS_LIST" ] || return 0

    OLD_IFS=$IFS
    IFS='
'
    for TEST_URL in $TEST_URLS_LIST; do
        [ -n "$TEST_URL" ] || continue
        if ! ns_check_single_test_url "$INST_ID" "$TEST_URL"; then
            IFS=$OLD_IFS
            return 1
        fi
    done

    IFS=$OLD_IFS
    return 0
}

run_instance_health_checks() {
    INST_ID=$1
    IP_OK=0
    ns_ensure_trace_ip "$INST_ID" && IP_OK=1 || true

    TEST_URLS_RAW=${TEST_URLS:-https://grok.com}
    TEST_URLS_LIST=$(printf '%s' "$TEST_URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')

    if [ -n "$TEST_URLS_LIST" ]; then
        ns_check_test_urls "$INST_ID"
        return $?
    fi

    [ "$IP_OK" -eq 1 ]
}

restart_instance_wg() {
    INST_ID=$1
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")

    echo "==> [MicroWARP] [inst${INST_ID}] 正在断开并重连 WireGuard..."
    ip netns exec "$NS_NAME" wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    start_instance_warp "$INST_ID"
}

try_instance_wg_reconnect_recovery() {
    INST_ID=$1
    RECONNECT_RETRIES=$(get_wg_reconnect_retries)

    if [ "$RECONNECT_RETRIES" -le 0 ]; then
        echo "==> [MicroWARP] [inst${INST_ID}] 已禁用 WG 重连重试"
        return 1
    fi

    ATTEMPT=1
    while [ "$ATTEMPT" -le "$RECONNECT_RETRIES" ]; do
        echo "==> [MicroWARP] [inst${INST_ID}] WG 重连重试 (${ATTEMPT}/${RECONNECT_RETRIES})..."
        if restart_instance_wg "$INST_ID" && run_instance_health_checks "$INST_ID"; then
            echo "==> [MicroWARP] [inst${INST_ID}] WG 重连后健康检查已恢复"
            return 0
        fi
        ATTEMPT=$((ATTEMPT + 1))
        [ "$ATTEMPT" -le "$RECONNECT_RETRIES" ] && sleep 3
    done

    echo "==> [MicroWARP] [inst${INST_ID}] [WARN] WG 重连重试全部失败"
    return 1
}

restart_instance_with_new_identity() {
    INST_ID=$1
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")
    CONF_PATH=$(get_instance_conf_path "$INST_ID")

    ip netns exec "$NS_NAME" wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    # Serialize API registration so many background revivers don't stampede the API.
    with_dir_lock "$(get_register_lock_dir)" generate_warp_config "$CONF_PATH"
    print_warp_identity_summary "$CONF_PATH" "inst${INST_ID}"
    start_instance_warp "$INST_ID"
}

mark_instance_up() {
    INST_ID=$1
    start_instance_socks "$INST_ID"
    set_instance_status "$INST_ID" "up"
    clear_instance_offline_since "$INST_ID"
    echo "==> [MicroWARP] [inst${INST_ID}] ✅ 已标记为健康并加入负载均衡池"
}

mark_instance_down() {
    INST_ID=$1
    stop_instance_socks "$INST_ID"
    set_instance_status "$INST_ID" "down"
    record_instance_offline_since "$INST_ID"
    echo "==> [MicroWARP] [inst${INST_ID}] ❌ 已标记为不健康并从负载均衡池剔除"
}

_reload_haproxy_from_status_unlocked() {
    mkdir -p "$INSTANCE_STATE_DIR"
    STATUS_LIST=$(collect_instance_status_list)
    HEALTHY=$(count_healthy_instances)

    render_haproxy_config "$LISTEN_ADDR" "$LISTEN_PORT" "$STATUS_LIST" > "$HAPROXY_CFG"
    echo "==> [MicroWARP] 刷新 HAProxy 后端（健康实例: ${HEALTHY}/${WARP_INSTANCE_COUNT}）"

    if [ -n "$HAPROXY_PID" ] && kill -0 "$HAPROXY_PID" 2>/dev/null; then
        # soft reload keeps the frontend port open
        if haproxy -D -f "$HAPROXY_CFG" -p "${INSTANCE_STATE_DIR}/haproxy.pid" -sf "$HAPROXY_PID" 2>/dev/null; then
            if [ -f "${INSTANCE_STATE_DIR}/haproxy.pid" ]; then
                HAPROXY_PID=$(tr -d '\n' < "${INSTANCE_STATE_DIR}/haproxy.pid")
            fi
            return 0
        fi
        echo "==> [MicroWARP] [WARN] HAProxy soft-reload 失败，尝试重启"
        kill "$HAPROXY_PID" 2>/dev/null || true
        wait "$HAPROXY_PID" 2>/dev/null || true
        HAPROXY_PID=""
    fi

    # Also accept PID from a previous process written to the pid file (multi-worker safe-ish)
    if [ -z "$HAPROXY_PID" ] && [ -f "${INSTANCE_STATE_DIR}/haproxy.pid" ]; then
        OLD_PID=$(tr -d '\n' < "${INSTANCE_STATE_DIR}/haproxy.pid")
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            if haproxy -D -f "$HAPROXY_CFG" -p "${INSTANCE_STATE_DIR}/haproxy.pid" -sf "$OLD_PID" 2>/dev/null; then
                if [ -f "${INSTANCE_STATE_DIR}/haproxy.pid" ]; then
                    HAPROXY_PID=$(tr -d '\n' < "${INSTANCE_STATE_DIR}/haproxy.pid")
                fi
                return 0
            fi
            kill "$OLD_PID" 2>/dev/null || true
        fi
    fi

    haproxy -D -f "$HAPROXY_CFG" -p "${INSTANCE_STATE_DIR}/haproxy.pid"
    if [ -f "${INSTANCE_STATE_DIR}/haproxy.pid" ]; then
        HAPROXY_PID=$(tr -d '\n' < "${INSTANCE_STATE_DIR}/haproxy.pid")
    fi
    record_socks_online_started_at
    echo "==> [MicroWARP] 🚀 HAProxy 已上线 (监听: ${LISTEN_ADDR}:${LISTEN_PORT}, PID: ${HAPROXY_PID})"
}

reload_haproxy_from_status() {
    with_dir_lock "$(get_haproxy_lock_dir)" _reload_haproxy_from_status_unlocked
}

# Background self-revival loop for ONE instance. Can run forever without blocking others.
# On success: mark up + reload HAProxy, then exit. On failure: keep retrying with backoff.
# If offline continuously for CONFIG_STALE_OFFLINE_SECONDS (default 2h), skip reconnect and
# force a new WARP registration — existing conf is treated as stale/invalid.
instance_recovery_worker() {
    INST_ID=$1
    PID_FILE=$(get_instance_recover_pid_file "$INST_ID")
    echo $$ > "$PID_FILE"
    # shellcheck disable=SC2064
    trap 'rm -f "$PID_FILE"' EXIT INT TERM

    BACKOFF=5
    MAX_BACKOFF=60
    echo "==> [MicroWARP] [inst${INST_ID}] 后台复活 worker 启动 (PID $$)"

    while true; do
        if run_instance_health_checks "$INST_ID"; then
            mark_instance_up "$INST_ID"
            reload_haproxy_from_status
            echo "==> [MicroWARP] [inst${INST_ID}] 🎉 后台复活成功，已重新加入 LB"
            rm -f "$PID_FILE"
            trap - EXIT INT TERM
            exit 0
        fi

        FORCE_NEW=0
        if instance_should_force_new_config "$INST_ID"; then
            FORCE_NEW=1
            SINCE=$(get_instance_offline_since_epoch "$INST_ID")
            NOW_EPOCH=$(date +%s)
            ELAPSED=$((NOW_EPOCH - SINCE))
            echo "==> [MicroWARP] [inst${INST_ID}] 已连续离线 ${ELAPSED}s ≥ $(get_config_stale_offline_seconds)s，判定配置失效，跳过重连并强制换新配置"
        fi

        if [ "$FORCE_NEW" -eq 0 ]; then
            echo "==> [MicroWARP] [inst${INST_ID}] 后台复活：健康检查未过，尝试 WG 重连..."
            if try_instance_wg_reconnect_recovery "$INST_ID"; then
                mark_instance_up "$INST_ID"
                reload_haproxy_from_status
                echo "==> [MicroWARP] [inst${INST_ID}] 🎉 WG 重连后后台复活成功"
                rm -f "$PID_FILE"
                trap - EXIT INT TERM
                exit 0
            fi
            echo "==> [MicroWARP] [inst${INST_ID}] 后台复活：重连无效，重新注册 WARP 身份..."
        fi

        if restart_instance_with_new_identity "$INST_ID" && run_instance_health_checks "$INST_ID"; then
            mark_instance_up "$INST_ID"
            reload_haproxy_from_status
            echo "==> [MicroWARP] [inst${INST_ID}] 🎉 重注册后后台复活成功"
            rm -f "$PID_FILE"
            trap - EXIT INT TERM
            exit 0
        fi

        mark_instance_down "$INST_ID"
        reload_haproxy_from_status
        echo "==> [MicroWARP] [inst${INST_ID}] 后台复活本轮失败，${BACKOFF}s 后继续（永不放弃）"
        sleep "$BACKOFF"
        BACKOFF=$((BACKOFF * 2))
        if [ "$BACKOFF" -gt "$MAX_BACKOFF" ]; then
            BACKOFF=$MAX_BACKOFF
        fi
    done
}

# Kick off background revival if not already running. Non-blocking.
request_instance_recovery() {
    INST_ID=$1
    mkdir -p "$INSTANCE_STATE_DIR"

    if is_instance_recovering "$INST_ID"; then
        echo "==> [MicroWARP] [inst${INST_ID}] 后台复活已在进行中，跳过重复拉起"
        return 0
    fi

    # Ensure status is down and socks is off before spawning recovery.
    mark_instance_down "$INST_ID"
    reload_haproxy_from_status

    echo "==> [MicroWARP] [inst${INST_ID}] 拉起后台复活 worker..."
    instance_recovery_worker "$INST_ID" &
    echo $! > "$(get_instance_recover_pid_file "$INST_ID")"
}

# Foreground bounded attempt (startup path only). Returns quickly-ish.
ensure_instance_ready() {
    INST_ID=$1
    # Optional second arg: max full identity re-registers in THIS call (startup budget).
    MAX_REREG=${2:-1}

    REREG_COUNT=0
    while true; do
        if run_instance_health_checks "$INST_ID"; then
            mark_instance_up "$INST_ID"
            return 0
        fi

        echo "==> [MicroWARP] [inst${INST_ID}] 连通性测试未通过"
        mark_instance_down "$INST_ID"
        reload_haproxy_from_status

        if try_instance_wg_reconnect_recovery "$INST_ID"; then
            mark_instance_up "$INST_ID"
            return 0
        fi

        case "$MAX_REREG" in
            ''|*[!0-9]*)
                MAX_REREG=1
                ;;
        esac

        if [ "$REREG_COUNT" -ge "$MAX_REREG" ]; then
            echo "==> [MicroWARP] [inst${INST_ID}] 启动期预算用尽，交给后台 worker 继续复活"
            request_instance_recovery "$INST_ID"
            return 1
        fi

        echo "==> [MicroWARP] [inst${INST_ID}] 重连失败，重新注册 WARP 设备..."
        restart_instance_with_new_identity "$INST_ID"
        REREG_COUNT=$((REREG_COUNT + 1))
    done
}

stagger_next_instance_start() {
    CURRENT_ID=$1
    TOTAL_COUNT=$2

    # No delay after the last instance.
    [ "$CURRENT_ID" -lt "$TOTAL_COUNT" ] || return 0
    [ "$INSTANCE_START_STAGGER_SECONDS" -gt 0 ] 2>/dev/null || return 0

    echo "==> [MicroWARP] 启动错峰：inst${CURRENT_ID} 完成，等待 ${INSTANCE_START_STAGGER_SECONDS}s 后再启动下一个实例"
    sleep "$INSTANCE_START_STAGGER_SECONDS"
}

bootstrap_multi_instances() {
    enable_host_forwarding
    mkdir -p "$INSTANCE_STATE_DIR" /etc/wireguard/instances
    echo "==> [MicroWARP] 多实例串行启动（实例间错开 ${INSTANCE_START_STAGGER_SECONDS}s，避免并发注册/建隧）"

    for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        CONF_PATH=$(get_instance_conf_path "$INST_ID")
        set_instance_status "$INST_ID" "down"
        # Start offline clock only if not already tracking (e.g. after container restart while still down).
        record_instance_offline_since "$INST_ID"

        if [ ! -f "$CONF_PATH" ]; then
            # migrate legacy single-instance conf to inst1 if present
            if [ "$INST_ID" = "1" ] && [ -f "$WG_CONF" ] && ! is_enabled "$ROTATE_IP_ON_START"; then
                mkdir -p "$(dirname "$CONF_PATH")"
                cp "$WG_CONF" "$CONF_PATH"
                echo "==> [MicroWARP] [inst1] 复用已有 ${WG_CONF}"
            else
                echo "==> [MicroWARP] [inst${INST_ID}] 未检测到配置，自动注册..."
                generate_warp_config "$CONF_PATH"
            fi
        elif is_enabled "$ROTATE_IP_ON_START"; then
            echo "==> [MicroWARP] [inst${INST_ID}] ROTATE_IP_ON_START 生效，重新注册..."
            generate_warp_config "$CONF_PATH"
        else
            echo "==> [MicroWARP] [inst${INST_ID}] 检测到已有配置，跳过注册"
        fi

        print_warp_identity_summary "$CONF_PATH" "inst${INST_ID}"
        setup_instance_netns "$INST_ID"
        start_instance_warp "$INST_ID" || true
        stagger_next_instance_start "$INST_ID" "$WARP_INSTANCE_COUNT"
    done

    # Bring frontend up early (may temporarily have zero backends), then fill healthy ones.
    reload_haproxy_from_status

    # Startup: quick bounded check per instance; failures hand off to background workers.
    for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        ensure_instance_ready "$INST_ID" 1 || true
        reload_haproxy_from_status
        stagger_next_instance_start "$INST_ID" "$WARP_INSTANCE_COUNT"
    done

    HEALTHY=$(count_healthy_instances)
    if [ "$HEALTHY" -le 0 ]; then
        echo "==> [MicroWARP] [WARN] 启动期尚无健康实例；各实例已/将在后台自行复活，主流程继续进入守护"
        for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
            request_instance_recovery "$INST_ID"
        done
        # Wait until at least one is up so clients aren't stuck on empty pool at first boot.
        WAIT_ROUNDS=0
        while [ "$(count_healthy_instances)" -le 0 ]; do
            WAIT_ROUNDS=$((WAIT_ROUNDS + 1))
            echo "==> [MicroWARP] 等待至少一个实例后台复活... (${WAIT_ROUNDS})"
            sleep 5
            # re-kick any worker that died unexpectedly
            for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
                if [ "$(get_instance_status "$INST_ID")" != "up" ]; then
                    request_instance_recovery "$INST_ID"
                fi
            done
        done
    fi

    HEALTHY=$(count_healthy_instances)
    echo "==> [MicroWARP] 多实例就绪：${HEALTHY}/${WARP_INSTANCE_COUNT} 健康，统一入口 ${LISTEN_ADDR}:${LISTEN_PORT}"
    echo "==> [MicroWARP] down 实例由各自后台 worker 独立复活，不阻塞主巡检"
    return 0
}

# Health-check stagger: spread probes evenly across TEST_URLS_CHECK_INTERVAL.
# e.g. interval=900, instances=3 → 300s between each instance check.
get_health_check_stagger_seconds() {
    INTERVAL=${TEST_URLS_CHECK_INTERVAL:-900}
    COUNT=${1:-${WARP_INSTANCE_COUNT:-1}}

    case "$INTERVAL" in
        ''|*[!0-9]*)
            INTERVAL=900
            ;;
    esac

    case "$COUNT" in
        ''|*[!0-9]*)
            COUNT=1
            ;;
    esac

    if [ "$COUNT" -le 1 ]; then
        [ "$INTERVAL" -gt 0 ] 2>/dev/null || INTERVAL=1
        printf '%s\n' "$INTERVAL"
        return 0
    fi

    if [ "$INTERVAL" -le 0 ]; then
        printf '1\n'
        return 0
    fi

    STAGGER=$((INTERVAL / COUNT))
    if [ "$STAGGER" -lt 1 ]; then
        STAGGER=1
    fi
    printf '%s\n' "$STAGGER"
}

# Lightweight monitor visit: if healthy keep/restore up; if not, kick off background revival and move on.
probe_instance_and_schedule_recovery() {
    INST_ID=$1

    # If a recovery worker is already busy, just skip heavy work.
    if is_instance_recovering "$INST_ID"; then
        echo "==> [MicroWARP] [inst${INST_ID}] 后台复活进行中，本轮巡检跳过重活"
        return 0
    fi

    echo "==> [MicroWARP] [inst${INST_ID}] 执行健康巡检..."
    if run_instance_health_checks "$INST_ID"; then
        OLD_STATUS=$(get_instance_status "$INST_ID")
        mark_instance_up "$INST_ID"
        if [ "$OLD_STATUS" != "up" ]; then
            reload_haproxy_from_status
            echo "==> [MicroWARP] [inst${INST_ID}] 已恢复并重新加入 LB"
        fi
        return 0
    fi

    echo "==> [MicroWARP] [inst${INST_ID}] ❌ 巡检失败 → 立刻踢出 LB，并交给后台 worker 自行复活"
    request_instance_recovery "$INST_ID"
    return 0
}

# Back-compat name used by older call sites / tests.
check_and_recover_one_instance() {
    probe_instance_and_schedule_recovery "$1"
    printf '0\n'
}

recover_unhealthy_instances_once() {
    for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        probe_instance_and_schedule_recovery "$INST_ID"
    done
}

multi_periodic_monitor() {
    HEALTH_STAGGER=$(get_health_check_stagger_seconds "$WARP_INSTANCE_COUNT")
    echo "==> [MicroWARP] 多实例守护模式：巡检总间隔 ${TEST_URLS_CHECK_INTERVAL}s / ${WARP_INSTANCE_COUNT} 实例 → 错峰 ${HEALTH_STAGGER}s"
    echo "==> [MicroWARP] 主循环只做轻量探活；失败实例在后台独立重连/重注册直到复活"

    while true; do
        for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
            probe_instance_and_schedule_recovery "$INST_ID"

            HEALTHY=$(count_healthy_instances)
            RECOVERING=0
            for X in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
                if is_instance_recovering "$X"; then
                    RECOVERING=$((RECOVERING + 1))
                fi
            done
            echo "==> [MicroWARP] 健康 ${HEALTHY}/${WARP_INSTANCE_COUNT}，后台复活中 ${RECOVERING}"

            echo "==> [MicroWARP] 健康巡检错峰：等待 ${HEALTH_STAGGER}s 后检查下一个实例"
            sleep "$HEALTH_STAGGER" & wait $!
        done
    done
}

multi_cleanup_on_exit() {
    echo "==> [MicroWARP] 收到退出信号，正在清理多实例资源..."

    stop_all_instance_recoveries

    if [ -n "$HAPROXY_PID" ] && kill -0 "$HAPROXY_PID" 2>/dev/null; then
        kill "$HAPROXY_PID" 2>/dev/null || true
        wait "$HAPROXY_PID" 2>/dev/null || true
    fi
    HAPROXY_PID=""

    for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        destroy_instance_netns "$INST_ID"
        set_instance_status "$INST_ID" "down"
    done

    iptables -t nat -D POSTROUTING -s "${INSTANCE_SUBNET_PREFIX}.0.0/16" -j MASQUERADE 2>/dev/null || true
    exit 0
}

# ==========================================
# 1. 初始化
# ==========================================
WARP_INSTANCE_COUNT=$(get_warp_instance_count)
echo "==> [MicroWARP] WARP 实例数: ${WARP_INSTANCE_COUNT} (WARP_INSTANCES=${WARP_INSTANCES:-1})"

if [ "$WARP_STACK_MODE" = "ipv6-preferred" ]; then
    echo "precedence ::ffff:0:0/96  10" > /etc/gai.conf
    echo "==> [MicroWARP] 已启用 IPv6 优先地址选择策略"
fi

prepare_wg_quick_compat

if [ "$WARP_INSTANCE_COUNT" -le 1 ]; then
    # 单实例：保持原有路径与 volume 兼容
    if [ ! -f "$WG_CONF" ]; then
        echo "==> [MicroWARP] 未检测到配置，正在全自动初始化 Cloudflare WARP..."
        generate_warp_config
    elif is_enabled "$ROTATE_IP_ON_START"; then
        echo "==> [MicroWARP] 检测到 ROTATE_IP_ON_START=${ROTATE_IP_ON_START}，正在重新注册 WARP 设备以刷新出口 IP..."
        generate_warp_config
    else
        echo "==> [MicroWARP] 检测到已有持久化配置，跳过注册。"
    fi

    print_warp_identity_summary
    trap cleanup_on_exit INT TERM
    start_warp_interface
    ensure_network_ready
    periodic_test_url_monitor
else
    # 多实例：单容器内多条 WARP 隧道 + 统一 SOCKS 入口 + 健康 LB
    echo "==> [MicroWARP] 多实例模式：容器内并行 ${WARP_INSTANCE_COUNT} 条 WARP，仅暴露 ${LISTEN_ADDR}:${LISTEN_PORT}"
    echo "==> [MicroWARP] 提示：多实例需要 netns，建议 cap_add: [NET_ADMIN, SYS_ADMIN, SYS_MODULE]"
    trap multi_cleanup_on_exit INT TERM
    bootstrap_multi_instances
    multi_periodic_monitor
fi
