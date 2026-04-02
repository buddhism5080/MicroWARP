#!/bin/sh
set -e

if [ "${MICROWARP_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

WG_CONF="/etc/wireguard/wg0.conf"
ROTATE_IP_ON_START="${ROTATE_IP_ON_START:-0}"
mkdir -p /etc/wireguard

is_enabled() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

print_warp_identity_summary() {
    PRIVATE_KEY=$(awk -F ' = ' '/^PrivateKey = / {print $2; exit}' "$WG_CONF")
    # 新 API 返回的 Address 是裸 IP（无 /32 /128），使用正则精准提取（不受行序影响）
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

    while [ $attempt -le $max_retries ]; do
        echo "==> [MicroWARP] 正在向 CF 注册新设备 (fscarmen API, 第${attempt}次尝试)..."

        curl --retry 3 --retry-delay 2 --max-time 10 --silent --location --fail \
             "https://warp.cloudflare.nyc.mn/?run=register&format=wireguard" > "$WG_CONF"

        if grep -q '^\[Interface\]' "$WG_CONF" && grep -q 'PrivateKey[[:space:]]*=' "$WG_CONF"; then
            echo "==> [MicroWARP] 原始配置获取成功，正在清理格式..."

            sed -i 's/[[:space:]]\{2,\}/ /g' "$WG_CONF"
            sed -i '/^## Warp account ##/,$d' "$WG_CONF"

            echo "==> [MicroWARP] 节点配置生成成功！(已标准化)"
            return 0
        fi

        echo "==> [MicroWARP] [WARN] 第${attempt}次返回无效配置，原始内容预览："
        cat "$WG_CONF" | head -30
        rm -f "$WG_CONF"
        attempt=$((attempt + 1))
        [ $attempt -le $max_retries ] && sleep 8
    done

    echo "==> [MicroWARP] [ERROR] API 连续 ${max_retries} 次失败，无法生成有效配置！"
    exit 1
}

# ==========================================
# 强力洗白函数（兼容新 API 裸 IP 格式 + 每次重新注册都必须执行）
# ==========================================
wash_warp_config() {
    # 1. 提取 IPv4 / IPv6 地址（适配新 API 返回的裸 IP，无 /32 /128）
    WARP_STACK_MODE=$(printf '%s' "${WARP_STACK:-ipv6-preferred}" | tr '[:upper:]' '[:lower:]')
    IPV4_ADDR=$(grep '^Address =' "$WG_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    IPV6_ADDR=$(grep '^Address =' "$WG_CONF" | grep -oE '([0-9a-fA-F:]+:+)+[0-9a-fA-F]+' | head -n 1)

    # 2. 物理删除所有原始的 Address、AllowedIPs、DNS
    sed -i '/^Address/d' "$WG_CONF"
    sed -i '/^AllowedIPs/d' "$WG_CONF"
    sed -i '/^DNS.*/d' "$WG_CONF"

    # 3. 重建路由规则（强制加上标准 CIDR 掩码，确保 wg-quick 完全兼容）
    case "$WARP_STACK_MODE" in
        ipv4-only)
            [ -n "$IPV4_ADDR" ] && sed -i "/\[Interface\]/a Address = $IPV4_ADDR/32" "$WG_CONF"
            sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"
            ;;
        ipv6-only)
            [ -n "$IPV6_ADDR" ] && sed -i "/\[Interface\]/a Address = $IPV6_ADDR/128" "$WG_CONF"
            sed -i "/\[Peer\]/a AllowedIPs = ::\/0" "$WG_CONF"
            ;;
        ipv6-preferred|dual|*)
            [ -n "$IPV6_ADDR" ] && sed -i "/\[Interface\]/a Address = $IPV6_ADDR/128" "$WG_CONF"
            [ -n "$IPV4_ADDR" ] && sed -i "/\[Interface\]/a Address = $IPV4_ADDR/32" "$WG_CONF"
            sed -i "/\[Peer\]/a AllowedIPs = ::\/0" "$WG_CONF"
            sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"
            ;;
    esac

    # 删除 Alpine 系统自带 wg-quick 中不兼容的路由标记
    sed -i '/src_valid_mark/d' /usr/bin/wg-quick 2>/dev/null || true

    # 抗断流绝杀：强制 15 秒 UDP 心跳
    if ! grep -q "PersistentKeepalive" "$WG_CONF"; then
        sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$WG_CONF"
    else
        sed -i 's/PersistentKeepalive.*/PersistentKeepalive = 15/g' "$WG_CONF"
    fi

    # 防阻断绝杀：自定义 Endpoint 随机/覆盖
    if [ -n "$ENDPOINT_IP" ]; then
        if pick_endpoint_ip; then
            echo "==> [MicroWARP] 🔀 检测到自定义 Endpoint 候选，已随机选中节点: $ENDPOINT_IP_SELECTED"
            sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP_SELECTED/g" "$WG_CONF"
        else
            echo "==> [MicroWARP] 🔀 检测到自定义 Endpoint IP，正在覆盖默认节点: $ENDPOINT_IP"
            sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP/g" "$WG_CONF"
        fi
    fi
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
            echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由: via ${PRE_WARP_GW} dev ${PRE_WARP_DEV}"
        fi
    fi
}

restart_warp_with_new_identity() {
    wg-quick down wg0 > /dev/null 2>&1 || true
    generate_warp_config
    wash_warp_config          # 每次重新注册都执行完整洗白（兼容新 API 格式）
    print_warp_identity_summary
    start_warp_interface
}

ensure_trace_ip() {
    TRACE_ATTEMPTS=${TRACE_ATTEMPTS:-3}
    ATTEMPT=1

    while [ "$ATTEMPT" -le "$TRACE_ATTEMPTS" ]; do
        echo "==> [MicroWARP] 当前出口 IP 已成功变更为："
        TRACE_OUTPUT_V4=$(curl -4 -s -m 5 https://1.1.1.1/cdn-cgi/trace || true)
        TRACE_IP_V4=$(printf '%s\n' "$TRACE_OUTPUT_V4" | grep '^ip=' || true)
        TRACE_OUTPUT_V6=$(curl -6 -s -m 5 https://[2606:4700:4700::1111]/cdn-cgi/trace || true)
        TRACE_IP_V6=$(printf '%s\n' "$TRACE_OUTPUT_V6" | grep '^ip=' || true)

        [ -n "$TRACE_IP_V4" ] && printf 'IPv4 %s\n' "$TRACE_IP_V4"
        [ -n "$TRACE_IP_V6" ] && printf 'IPv6 %s\n' "$TRACE_IP_V6"

        if [ -n "$TRACE_IP_V4" ] || [ -n "$TRACE_IP_V6" ]; then
            return 0
        fi

        if [ "$ATTEMPT" -ge "$TRACE_ATTEMPTS" ]; then
            echo "⚠️ 获取超时 (可能是底层握手延迟或节点被强阻断)"
            return 1
        fi

        echo "==> [MicroWARP] 第 ${ATTEMPT}/${TRACE_ATTEMPTS} 次未获取到出口 IP，正在重新注册并重试..."
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
        echo "==> [MicroWARP] ${TEST_URL} HTTP 状态码: ${TEST_HTTP_CODE}"

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

ensure_test_urls_ready() {
    while true; do
        ensure_trace_ip || return 1

        if check_test_urls; then
            return 0
        fi

        echo "==> [MicroWARP] 存在测试 URL 未通过，正在重新注册并重试..."
        restart_warp_with_new_identity
    done
}

periodic_test_url_monitor() {
    while true; do
        sleep 900
        echo "==> [MicroWARP] 正在执行 15 分钟 TEST_URLS 巡检..."

        if check_test_urls; then
            echo "==> [MicroWARP] 15 分钟 TEST_URLS 巡检通过"
            continue
        fi

        echo "==> [MicroWARP] TEST_URLS 巡检未通过，正在重新注册并恢复..."
        while ! ensure_test_urls_ready; do
            echo "==> [MicroWARP] 恢复流程未完成，60 秒后继续重试..."
            sleep 60
        done
    done
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

# ==========================================
# 2. 强力洗白（仅首次启动执行一次，后续重注册由 restart_warp_with_new_identity 负责）
# ==========================================
if [ ! -f "$WG_CONF" ] || is_enabled "$ROTATE_IP_ON_START"; then
    wash_warp_config
else
    # 已有持久化配置时，仍然执行一次洗白（确保格式一致 + 注入最新参数）
    wash_warp_config
fi

print_warp_identity_summary
if [ "$WARP_STACK_MODE" = "ipv6-preferred" ]; then
    echo "precedence ::ffff:0:0/96  10" > /etc/gai.conf
    echo "==> [MicroWARP] 已启用 IPv6 优先地址选择策略"
fi

# ==========================================
# 3. 拉起内核网卡 + 监控
# ==========================================
start_warp_interface
ensure_test_urls_ready
periodic_test_url_monitor &

# ==========================================
# 4. 启动 C 语言 SOCKS5 代理服务
# ==========================================
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    echo "==> [MicroWARP] 🔒 身份认证已开启 (User: $SOCKS_USER)"
    echo "==> [MicroWARP] 🚀 MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
else
    echo "==> [MicroWARP] ⚠️ 未设置密码，当前为公开访问模式"
    echo "==>[MicroWARP] 🚀 MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
fi
