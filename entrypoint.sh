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

# ==================== 核心修复：带重试 + 智能验证 + 自动清理 ====================
generate_warp_config() {
    local max_retries=3
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        echo "==> [MicroWARP] 正在向 CF 注册新设备 (fscarmen API, 第${attempt}次尝试)..."

        curl -s \
             -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; MicroWARP/1.0) AppleWebKit/537.36" \
             "https://warp.cloudflare.now.cc/?run=register&format=wireguard" > "$WG_CONF"

        # 更宽松的验证（兼容双空格、任意空白）
        if grep -q '^\[Interface\]' "$WG_CONF" && grep -q 'PrivateKey[[:space:]]*=' "$WG_CONF"; then
            echo "==> [MicroWARP] 原始配置获取成功，正在清理格式..."

            # === 关键清理步骤 ===
            # 1. 把所有连续空格/制表符统一成单个空格
            sed -i 's/[[:space:]]\{2,\}/ /g' "$WG_CONF"
            # 2. 删除尾部的 ## Warp account ## 账号信息（wg-quick 不需要）
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
    echo "    请检查容器网络 / VPS IP 是否被 Cloudflare 临时限制，或稍后重试。"
    exit 1
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
    print_warp_identity_summary
    start_warp_interface
}

# ...（ensure_trace_ip、check_test_urls、ensure_test_urls_ready、periodic_test_url_monitor 保持完全不变）...
# （下面这四个函数我就不重复贴了，你原来的保持原样即可）

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
# 2. 强力洗白与内核兼容性处理（你原来的代码保持不变，从这里开始往下全部保留）
# ==========================================
# 1. 提取 IPv4 / IPv6 地址...
# （后面所有 sed、PersistentKeepalive、print_warp_identity_summary、gai.conf、start_warp_interface 等全部照旧）

# ...（把你原来的第 2、3、4 部分完整复制粘贴在这里，我只在上面加了修复代码）

# 最终启动 SOCKS5 的部分也保持不变
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
