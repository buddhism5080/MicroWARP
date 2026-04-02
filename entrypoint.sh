#!/bin/sh
set -e

if [ "${MICROWARP_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

WG_CONF="/etc/wireguard/wg0.conf"
ROTATE_IP_ON_START="${ROTATE_IP_ON_START:-0}"
mkdir -p /etc/wireguard

# SOCKS5 代理配置
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}
SOCKS_PID=""

is_enabled() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

print_warp_identity_summary() {
    PRIVATE_KEY=$(awk -F ' = ' '/^PrivateKey = / {print $2; exit}' "$WG_CONF")
    IPV4_ADDRESS=$(grep '^Address =' "$WG_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    IPV6_ADDRESS=$(grep '^Address =' "$WG_CONF" | grep -oE '([0-9a-fA-F:]+:+)+[0-9a-fA-F]+' | head -n 1)
    ENDPOINT=$(awk -F ' = ' '/^Endpoint = / {print $2; exit}' "$WG_CONF")
    PUBKEY_FINGERPRINT=$(printf '%s' "$PRIVATE_KEY" | sha256sum | awk '{print substr($1,1,16)}')

    echo "==> [MicroWARP] WARP 设备身份摘要:"
    echo "==> [MicroWARP]   PrivateKey SHA256/16: ${PUBKEY_FINGERPRINT}"
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

generate_warp_config() {
    local max_retries=3
    local attempt=1
    local raw_conf="/tmp/wg0.api.$$"

    WARP_STACK_MODE=$(printf '%s' "${WARP_STACK:-ipv6-preferred}" | tr '[:upper:]' '[:lower:]')

    while [ "$attempt" -le "$max_retries" ]; do
        echo "==> [MicroWARP] 正在向 CF 注册新设备 (API, 第${attempt}次尝试)..."

        if curl --retry 3 --retry-delay 2 --max-time 15 --silent --location --fail \
            "https://warp.cloudflare.nyc.mn/?run=register&format=wireguard" > "$raw_conf"; then

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
                } > "$WG_CONF"

                rm -f "$raw_conf"
                echo "==> [MicroWARP] 节点配置生成成功！"
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
    wg-quick up wg0 > /dev/null 2>&1

    TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
    if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
        if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
            echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由"
        fi
    fi

    sleep 3
    echo "==> [MicroWARP] 隧道已启动"
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
start_socks() {
    if [ -z "$SOCKS_PID" ] || ! kill -0 "$SOCKS_PID" 2>/dev/null; then
        echo "==> [MicroWARP] 🟢 节点状态健康，正在启动 SOCKS 服务..."
        if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
            microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS" > /dev/null 2>&1 &
        else
            microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" > /dev/null 2>&1 &
        fi
        SOCKS_PID=$!
        echo "==> [MicroWARP] 🚀 MicroSOCKS 已上线 (监听: ${LISTEN_ADDR}:${LISTEN_PORT}, PID: ${SOCKS_PID})"
    fi
}

stop_socks() {
    if [ -n "$SOCKS_PID" ] && kill -0 "$SOCKS_PID" 2>/dev/null; then
        echo "==> [MicroWARP] 🛑 切断 SOCKS 服务，避免请求黑洞..."
        kill "$SOCKS_PID" 2>/dev/null || true
        wait "$SOCKS_PID" 2>/dev/null || true
        SOCKS_PID=""
        echo "==> [MicroWARP] 🔻 SOCKS 服务已下线"
    fi
}

ensure_trace_ip() {
    TRACE_ATTEMPTS=${TRACE_ATTEMPTS:-3}
    ATTEMPT=1

    while [ "$ATTEMPT" -le "$TRACE_ATTEMPTS" ]; do
        TRACE_OUTPUT_V4=$(curl -4 -s -m 8 https://1.1.1.1/cdn-cgi/trace || true)
        TRACE_IP_V4=$(printf '%s\n' "$TRACE_OUTPUT_V4" | grep '^ip=' || true)
        TRACE_OUTPUT_V6=$(curl -6 -s -m 8 https://[2606:4700:4700::1111]/cdn-cgi/trace || true)
        TRACE_IP_V6=$(printf '%s\n' "$TRACE_OUTPUT_V6" | grep '^ip=' || true)

        if [ -n "$TRACE_IP_V4" ] || [ -n "$TRACE_IP_V6" ]; then
            echo "==> [MicroWARP] 当前出口 IP 已获取："
            [ -n "$TRACE_IP_V4" ] && printf 'IPv4 %s\n' "$TRACE_IP_V4"
            [ -n "$TRACE_IP_V6" ] && printf 'IPv6 %s\n' "$TRACE_IP_V6"
            return 0
        fi

        if [ "$ATTEMPT" -ge "$TRACE_ATTEMPTS" ]; then
            echo "==> [MicroWARP] ⚠️ 获取 IP 连续超时，底层连通性异常！"
            return 1
        fi

        echo "==> [MicroWARP] 第 ${ATTEMPT}/${TRACE_ATTEMPTS} 次未获取到出口 IP..."
        # 准备尝试重连前，因为网卡要重置，明确发现故障先切断代理
        stop_socks
        
        echo "==> [MicroWARP] 正在重新注册并重试..."
        ATTEMPT=$((ATTEMPT + 1))
        restart_warp_with_new_identity
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
        TEST_HTTP_CODE=$(curl -A 'Mozilla/5.0' -sL -o /dev/null -w '%{http_code}' -m 10 "$TEST_URL" || true)
        echo "==> [MicroWARP] 测速反馈 ${TEST_URL} HTTP 状态码: ${TEST_HTTP_CODE}"

        case "$TEST_HTTP_CODE" in
            4*|5*|000|"")
                IFS=$OLD_IFS
                return 1
                ;;
        esac
    done

    IFS=$OLD_IFS
    return 0
}

# ==========================================
# 核心网络就绪保证 (仅限发现异常进入修复或初次启动时)
# ==========================================
ensure_network_ready() {
    while true; do
        if ensure_trace_ip; then
            if check_test_urls; then
                # 测试均通过，安全上线
                start_socks
                return 0
            fi
        fi

        # 走到这里说明：虽然拿到IP但测试URL不通，或者根本拿不到IP
        echo "==> [MicroWARP] 连通性测试未通过！"
        
        # 确定网络有问题，立刻切断SOCKS（防透传泄漏）
        stop_socks 

        echo "==> [MicroWARP] 正在重新注册并重置节点..."
        restart_warp_with_new_identity
    done
}

periodic_test_url_monitor() {
    echo "==> [MicroWARP] 已启动守护模式，每 15 分钟进行一次健康巡检..."
    while true; do
        # 睡眠等待期间能随时响应容器的停止信号
        sleep 900 & wait $! 
        
        echo "==> [MicroWARP] 正在执行 15 分钟 TEST_URLS 巡检..."

        # 巡检时直接发起检测，不干扰正常运行的 SOCKS
        if check_test_urls; then
            echo "==> [MicroWARP] 巡检通过，SOCKS 服务继续保持在线"
            continue
        fi

        # 只有在确诊不通返回了非零状态，才触发保护机制并切断网络
        echo "==> [MicroWARP] ❌ 巡检未通过！触发节点重选保护机制..."
        stop_socks
        
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
# 1. 账号全自动申请与配置生成
# ==========================================
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
if [ "$WARP_STACK_MODE" = "ipv6-preferred" ]; then
    echo "precedence ::ffff:0:0/96  10" > /etc/gai.conf
    echo "==> [MicroWARP] 已启用 IPv6 优先地址选择策略"
fi

prepare_wg_quick_compat

# ==========================================
# 2. 捕获系统退出信号，实现优雅退出
# ==========================================
trap cleanup_on_exit INT TERM

# ==========================================
# 3. 核心运行流
# ==========================================
start_warp_interface

# 首次启动：挂起直到网络 100% 连通才上线 SOCKS
ensure_network_ready

# 接管主进程生命周期，死循环守护代理和网卡的健康
periodic_test_url_monitor
