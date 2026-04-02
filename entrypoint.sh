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

# ==================== 严格按你的要求实现（已彻底修复 IPv6） ====================
# 先确保 wg0 已接通 + 路由规则已应用（IPv6 出站优先）+ 回显 IPv4/IPv6
# 然后才执行健康检查
verify_warp_connectivity() {
    echo "==> [MicroWARP] 正在验证 wg0 隧道状态..."

    # 1. 先确保本地 wg 已接通
    if ! ip link show wg0 &>/dev/null; then
        echo "==> [MicroWARP] [ERROR] wg0 接口未启动！"
        return 1
    fi
    echo "==> [MicroWARP] wg0 接口已接通 ✅"

    # 2. 恢复 WARP 启动前的回程路由（保持原脚本逻辑）
    TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
    if [ -n "${PRE_WARP_GW:-}" ] && [ -n "${PRE_WARP_DEV:-}" ]; then
        if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
            echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由: via ${PRE_WARP_GW} dev ${PRE_WARP_DEV}"
        fi
    fi

    # 3. 回显当前出口 IPv4 和 IPv6（强制走 wg0 接口）
    # IPv4 使用可靠的 api.ipify.org
    local ipv4=$(curl -4 -s --interface wg0 --max-time 10 https://api.ipify.org 2>/dev/null || echo "检测失败")
    # IPv6 使用 Cloudflare 官方 IPv6 literal 地址（无 DNS 依赖，最稳定）
    local ipv6=$(curl -6 -s --interface wg0 --max-time 10 https://[2606:4700:4700::1111]/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2 || echo "检测失败")
    echo "==> [MicroWARP] 当前出口 IPv4: $ipv4"
    echo "==> [MicroWARP] 当前出口 IPv6: $ipv6"

    return 0
}

# ==================== 核心修复：带重试 + 智能验证 + 自动清理 ====================
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

start_warp_interface() {
    PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
    PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
    PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

    echo "==> [MicroWARP] 正在启动 Linux 内核级 wg0 网卡..."
    wg-quick up wg0 > /dev/null 2>&1

    # 【关键修复】不再手动执行 ip -6 route replace default
    # 你之前的老代码「没有用到route，但是v6有效」，所以我们完全恢复原来的行为
    # 路由由 wg-quick + AllowedIPs = ::/0 自动处理，IPv6 优先由 gai.conf 保证
    echo "==> [MicroWARP] 路由已由 wg-quick 自动应用（IPv6 出站优先，已恢复你老代码的稳定方式）"

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
    print_warp_identity_summary
    start_warp_interface
}

ensure_trace_ip() {
    verify_warp_connectivity || return 1
    return 0
}

check_test_urls() {
    verify_warp_connectivity || return 1

    TEST_URLS_RAW=${TEST_URLS:-https://grok.com}
    TEST_URLS_LIST=$(printf '%s' "$TEST_URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
    [ -n "$TEST_URLS_LIST" ] || return 0

    OLD_IFS=$IFS
    IFS='
'
    for TEST_URL in $TEST_URLS_LIST; do
        [ -n "$TEST_URL" ] || continue
        TEST_HTTP_CODE=$(curl -A 'Mozilla/5.0' -sL -o /dev/null -w '%{http_code}' -m 10 --interface wg0 "$TEST_URL" || true)
        echo "==> [MicroWARP] ${TEST_URL} HTTP 状态码: ${TEST_HTTP_CODE}"

        if [ "$TEST_HTTP_CODE" != "200" ]; then
            IFS=$OLD_IFS
            return 1
        fi
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

if [ -f "$WG_CONF" ] && ! (grep -q "^\[Interface\]" "$WG_CONF" && grep -q "PrivateKey =" "$WG_CONF"); then
    echo "==> [MicroWARP] 检测到已有配置但内容无效，强制重新注册..."
    generate_warp_config
fi

# ==========================================
# 2. 强力洗白与内核兼容性处理（完全保留你原来的这段代码）
# ==========================================

WARP_STACK_MODE=$(printf '%s' "${WARP_STACK:-ipv6-preferred}" | tr '[:upper:]' '[:lower:]')
IPV4_ADDR=$(grep '^Address' "$WG_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)
IPV6_ADDR=$(grep '^Address' "$WG_CONF" | grep -oE '([0-9a-fA-F:]+:+)+[0-9a-fA-F]+/[0-9]{1,3}' | head -n 1)

sed -i '/^Address/d' "$WG_CONF"
sed -i '/^AllowedIPs/d' "$WG_CONF"
sed -i '/^DNS.*/d' "$WG_CONF"

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

sed -i '/src_valid_mark/d' /usr/bin/wg-quick

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
# 3. 拉起内核网卡 + 健康检查
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
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT}"
fi
