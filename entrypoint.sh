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

# ==================== 严格按你的要求实现（已修复 IPv6 检测） ====================
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

    # 2. 应用/强化路由规则（所有出站优先走 IPv6）
    echo "==> [MicroWARP] 正在应用路由规则 (所有出站优先走 IPv6)..."
    ip -6 route replace default dev wg0 metric 10 2>/dev/null || true
    ip route replace default dev wg0 metric 100 2>/dev/null || true

    # 3. 恢复 WARP 启动前的回程路由（保持原脚本逻辑）
    TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
    if [ -n "${PRE_WARP_GW:-}" ] && [ -n "${PRE_WARP_DEV:-}" ]; then
        if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
            echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由: via ${PRE_WARP_GW} dev ${PRE_WARP_DEV}"
        fi
    fi

    # 4. 回显当前出口 IPv4 和 IPv6（强制走 wg0 接口）
    # IPv4 使用可靠的 api.ipify.org
    local ipv4=$(curl -4 -s --interface wg0 --max-time 10 https://api.ipify.org 2>/dev/null || echo "检测失败")
    # IPv6 使用 Cloudflare 官方 IPv6 literal 地址（无 DNS 依赖，更稳定）
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

        # 完全模仿原脚本 curl 特征：使用 .nyc.mn + retry 参数
        curl --retry 3 --retry-delay 2 --max-time 10 --silent --location --fail \
             "https://warp.cloudflare.nyc.mn/?run=register&format=wireguard" > "$WG_CONF"

        # 更宽松的验证（兼容双空格、任意空白）
        if grep -q '^\[Interface\]' "$WG_CONF" && grep -q 'PrivateKey[[:space:]]*=' "$WG_CONF"; then
            echo "==> [MicroWARP] 原始配置获取成功，正在清理格式..."

            # 自动清理：统一空格 + 删除尾部 ## Warp account ## 信息
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
    echo "    请稍后重试，或检查容器网络是否被 Cloudflare 限制。"
    exit 1
}

start_warp_interface() {
    PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
    PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
    PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

    echo "==> [MicroWARP] 正在启动 Linux 内核级 wg0 网卡..."
    wg-quick up wg0 > /dev/null 2>&1

    # === 启动时立即应用 IPv6 出站优先路由（你的要求）===
    echo "==> [MicroWARP] 正在应用路由规则 (所有出站优先走 IPv6)..."
    ip -6 route replace default dev wg0 metric 10 2>/dev/null || true
    ip route replace default dev wg0 metric 100 2>/dev/null || true

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

# ==================== 已按你的要求修改 ====================
ensure_trace_ip() {
    # 先确保 wg 已接通 + 路由已应用 + 回显 IP，然后才继续
    verify_warp_connectivity || return 1
    return 0
}

check_test_urls() {
    # === 严格按你的要求：先验证 wg + 路由 + IP 回显，再执行测试 ===
    verify_warp_connectivity || return 1

    TEST_URLS_RAW=${TEST_URLS:-https://grok.com}
    TEST_URLS_LIST=$(printf '%s' "$TEST_URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
    [ -n "$TEST_URLS_LIST" ] || return 0

    OLD_IFS=$IFS
    IFS='
'
    for TEST_URL in $TEST_URLS_LIST; do
        [ -n "$TEST_URL" ] || continue
        # 只认可 200 状态码 + 强制走 wg0
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

# ==================== 新增：防止坏配置导致死循环 ====================
if [ -f "$WG_CONF" ] && ! (grep -q "^\[Interface\]" "$WG_CONF" && grep -q "PrivateKey =" "$WG_CONF"); then
    echo "==> [MicroWARP] 检测到已有配置但内容无效，强制重新注册..."
    generate_warp_config
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
