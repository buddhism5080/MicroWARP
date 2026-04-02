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
    IPV4_ADDRESS=$(awk -F ' = ' '/^Address = / && $2 ~ /^[0-9]/ {print $2; exit}' "$WG_CONF")
    IPV6_ADDRESS=$(awk -F ' = ' '/^Address = / && $2 ~ /:/ {print $2; exit}' "$WG_CONF")
    ENDPOINT=$(awk -F ' = ' '/^Endpoint = / {print $2; exit}' "$WG_CONF")
    PUBKEY_FINGERPRINT=$(printf '%s' "$PRIVATE_KEY" | sha256sum | awk '{print substr($1,1,16)}')

    echo "==> [MicroWARP] WARP 设备身份摘要:"
    echo "==> [MicroWARP]   PrivateKey SHA256/16: ${PUBKEY_FINGERPRINT}"
    [ -n "$IPV4_ADDRESS" ] && echo "==> [MicroWARP]   Interface IPv4: ${IPV4_ADDRESS}"
    [ -n "$IPV6_ADDRESS" ] && echo "==> [MicroWARP]   Interface IPv6: ${IPV6_ADDRESS}"
    [ -n "$ENDPOINT" ] && echo "==> [MicroWARP]   Peer Endpoint: ${ENDPOINT}"
}

generate_warp_config() {
    echo "==> [MicroWARP] 正在向 CF 注册新设备 (fscarmen API)..."
    curl -s "https://warp.cloudflare.now.cc/?run=register&format=wireguard" > "$WG_CONF"
    echo "==> [MicroWARP] 节点配置生成成功！"
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
    # 已移除优选 Endpoint 逻辑（按你要求）
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
# 1. 账号全自动申请与配置生成 (可选每次启动刷新设备身份)
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
# 2. 强力洗白与内核兼容性处理
# ==========================================

# 1. 提取 IPv4 / IPv6 地址，并根据环境变量决定路由栈
WARP_STACK_MODE=$(printf '%s' "${WARP_STACK:-ipv6-preferred}" | tr '[:upper:]' '[:lower:]')
IPV4_ADDR=$(grep '^Address' "$WG_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)
IPV6_ADDR=$(grep '^Address' "$WG_CONF" | grep -oE '([0-9a-fA-F:]+:+)+[0-9a-fA-F]+/[0-9]{1,3}' | head -n 1)

# 2. 物理删除所有原始的 Address, AllowedIPs, DNS，防止 RTNETLINK 崩溃或 DNS 死锁
sed -i '/^Address/d' "$WG_CONF"
sed -i '/^AllowedIPs/d' "$WG_CONF"
sed -i '/^DNS.*/d' "$WG_CONF"

# 3. 重建路由规则，默认双栈并偏向 IPv6
case "$WARP_STACK_MODE" in
    ipv4-only)
        [ -n "$IPV4_ADDR" ] && sed -i "/\[Interface\]/a Address = $IPV4_ADDR" "$WG_CONF"
        sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"
        ;;
    ipv6-only)
        [ -n "$IPV6_ADDR" ] && sed -i "/\[Interface\]/a Address = $IPV6_ADDR" "$WG_CONF"
        sed -i "/\[Peer\]/a AllowedIPs = ::\/0" "$WG_CONF"
        ;;
    ipv6-preferred|dual|*)
        [ -n "$IPV6_ADDR" ] && sed -i "/\[Interface\]/a Address = $IPV6_ADDR" "$WG_CONF"
        [ -n "$IPV4_ADDR" ] && sed -i "/\[Interface\]/a Address = $IPV4_ADDR" "$WG_CONF"
        sed -i "/\[Peer\]/a AllowedIPs = ::\/0" "$WG_CONF"
        sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"
        ;;
esac

# 删除 Alpine 系统自带 wg-quick 中不兼容的路由标记
sed -i '/src_valid_mark/d' /usr/bin/wg-quick

# 【抗断流绝杀】强制注入 15 秒 UDP 心跳保活
if ! grep -q "PersistentKeepalive" "$WG_CONF"; then
    sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$WG_CONF"
else
    sed -i 's/PersistentKeepalive.*/PersistentKeepalive = 15/g' "$WG_CONF"
fi

print_warp_identity_summary
if [ "$WARP_STACK_MODE" = "ipv6-preferred" ]; then
    echo "precedence ::ffff:0:0/96  10" > /etc/gai.conf
    echo "==> [MicroWARP] 已启用 IPv6 优先地址选择策略"
fi

# ==========================================
# 3. 拉起内核网卡
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
