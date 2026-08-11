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
HAPROXY_SOCK="/var/run/microwarp/haproxy.sock"
INSTANCE_STATE_DIR="/var/run/microwarp"
MAX_WARP_INSTANCES=100
INSTANCE_SUBNET_PREFIX="10.66"
INSTANCE_START_STAGGER_SECONDS=1
# If an instance stays offline this long, treat its WARP conf as stale and force re-register.
# Default 7200s = 2 hours. Set 0 to disable.
CONFIG_STALE_OFFLINE_SECONDS="${CONFIG_STALE_OFFLINE_SECONDS:-7200}"
# Max continuous healthy uptime (seconds) per multi-instance backend.
# When exceeded AND the instance currently has no busy client connections (idle)
# AND healthy pool is not below half, force it offline and reconnect.
# Default 0 = disabled. Single-instance (WARP_INSTANCES<=1) never uses this.
MAX_CONN_DURATION="${MAX_CONN_DURATION:-0}"
# After kicking a multi-instance backend out of HAProxy, wait for busy client
# sockets to drain before stopping internal SOCKS.
# Unset/empty = wait indefinitely until idle (IM-friendly; no force-kill on timeout).
# 0 = stop SOCKS immediately. Positive N = max wait seconds then force stop.
INSTANCE_DRAIN_TIMEOUT="${INSTANCE_DRAIN_TIMEOUT-}"
# Admin HTTP: bind fixed 0.0.0.0:9180 (host maps port).
# ADMIN_HTTP_TOKEN = HMAC secret (empty disables server).
# Auth: HMAC-SHA256(secret, METHOD\nPATH\nts) + timestamp within ±120s (skew env).
ADMIN_HTTP_TOKEN="${ADMIN_HTTP_TOKEN:-}"
ADMIN_HTTP_HMAC_SKEW_SECONDS="${ADMIN_HTTP_HMAC_SKEW_SECONDS:-120}"
WARP_INSTANCE_COUNT=1

is_enabled() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

get_warp_instance_count() {
    # Single-active branch: floor 2 (need primary + at least one standby).
    RAW_COUNT=${WARP_INSTANCES:-2}

    case "$RAW_COUNT" in
        ''|*[!0-9]*)
            printf '2\n'
            return 0
            ;;
    esac

    if [ "$RAW_COUNT" -lt 2 ]; then
        printf '2\n'
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

get_admin_http_pid_file() {
    printf '%s/admin_http.pid\n' "$INSTANCE_STATE_DIR"
}

get_primary_id_file() {
    printf '%s/primary.id\n' "$INSTANCE_STATE_DIR"
}

get_rotate_lock_file() {
    printf '%s/rotate.lock\n' "$INSTANCE_STATE_DIR"
}

get_instance_last_healthy_file() {
    printf '%s/inst%s.last_healthy\n' "$INSTANCE_STATE_DIR" "$1"
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

get_max_conn_duration() {
    RAW=${MAX_CONN_DURATION:-0}
    case "$RAW" in
        ''|*[!0-9]*)
            printf '0\n'
            return 0
            ;;
    esac
    printf '%s\n' "$RAW"
}

get_instance_online_since_file() {
    # Ephemeral: online clock resets on container restart (fine for uptime rotation).
    printf '%s/inst%s.online_since\n' "$INSTANCE_STATE_DIR" "$1"
}

record_instance_online_since() {
    _oid=$1
    FILE=$(get_instance_online_since_file "$_oid")
    mkdir -p "$(dirname "$FILE")"
    # Only stamp if missing so re-mark-up during healthy probes does not reset the clock.
    if [ ! -f "$FILE" ]; then
        date +%s > "$FILE"
    fi
}

clear_instance_online_since() {
    _oid=$1
    rm -f "$(get_instance_online_since_file "$_oid")"
}

get_instance_online_since_epoch() {
    FILE=$(get_instance_online_since_file "$1")
    if [ -f "$FILE" ]; then
        tr -d '\n' < "$FILE"
    else
        printf ''
    fi
}

# Seconds since mark-up (empty string if never online / no stamp).
get_instance_online_elapsed_seconds() {
    local SINCE NOW ELAPSED
    SINCE=$(get_instance_online_since_epoch "$1")
    case "$SINCE" in
        ''|*[!0-9]*)
            printf ''
            return 0
            ;;
    esac
    NOW=$(date +%s)
    ELAPSED=$((NOW - SINCE))
    if [ "$ELAPSED" -lt 0 ]; then
        ELAPSED=0
    fi
    printf '%s\n' "$ELAPSED"
}

# Human-readable start time from epoch (Alpine busybox: date -d @epoch).
format_epoch_local_text() {
    local EPOCH="$1"
    case "$EPOCH" in
        ''|*[!0-9]*)
            printf ''
            return 0
            ;;
    esac
    date -d "@${EPOCH}" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf '%s' "$EPOCH"
}

# Log line used at multi-instance health probe start: include continuous online duration when known.
print_instance_health_probe_start() {
    local INST_ID="$1"
    local ELAPSED UPTIME_TEXT SINCE ONLINE_AT

    ELAPSED=$(get_instance_online_elapsed_seconds "$INST_ID")
    case "$ELAPSED" in
        ''|*[!0-9]*)
            echo "==> [inst${INST_ID}] 执行健康巡检..."
            return 0
            ;;
    esac

    UPTIME_TEXT=$(format_uptime_duration "$ELAPSED")
    SINCE=$(get_instance_online_since_epoch "$INST_ID")
    ONLINE_AT=$(format_epoch_local_text "$SINCE")
    if [ -n "$ONLINE_AT" ]; then
        echo "==> [inst${INST_ID}] 执行健康巡检（上线时间: ${ONLINE_AT}，已在线: ${UPTIME_TEXT}）..."
    else
        echo "==> [inst${INST_ID}] 执行健康巡检（已在线: ${UPTIME_TEXT}）..."
    fi
}

# Busy (non-idle) TCP states for client sessions:
#   established  — active data path
#   syn-sent / syn-recv — handshake in progress
#   fin-wait-1/2, close-wait, last-ack, closing — teardown still holding a session
# TIME-WAIT is intentionally excluded: pure post-close linger must not block rotation.
#
# CRITICAL: many ss builds (iproute2 on Alpine etc.) do NOT accept comma-separated
# state lists — `ss state established,syn-sent` prints "wrong state name" yet still
# exits 0 with empty output, which previously made every instance look idle and let
# MAX_CONN_DURATION kill live sessions. Always query one state at a time.
SS_BUSY_TCP_STATES='established syn-sent syn-recv fin-wait-1 fin-wait-2 close-wait last-ack closing'

# Count non-idle TCP sockets matching an ss filter expression (e.g. "dst 10.66.1.2:1080").
# Prints a non-negative integer. On ss unavailability / hard failure prints "unknown"
# so callers can fail closed (do not treat as idle).
count_busy_tcp_sockets() {
    local FILTER="$1"
    local STATE TOTAL=0 N OUT RC ANY_OK=0

    if ! command -v ss >/dev/null 2>&1; then
        printf 'unknown\n'
        return 0
    fi

    for STATE in $SS_BUSY_TCP_STATES; do
        # Capture stderr: "wrong state name" must not be treated as zero busy.
        OUT=$(ss -Htn state "$STATE" $FILTER 2>&1)
        RC=$?
        if [ "$RC" -ne 0 ]; then
            # Some older ss reject individual states; skip unknown state names only.
            case "$OUT" in
                *'wrong state name'*|*'invalid'*|*'unknown'*)
                    continue
                    ;;
            esac
            printf 'unknown\n'
            return 0
        fi
        case "$OUT" in
            *'wrong state name'*)
                # ss may exit 0 while rejecting the state — never count as idle.
                continue
                ;;
        esac
        ANY_OK=1
        N=$(printf '%s\n' "$OUT" | sed '/^$/d' | wc -l | tr -d ' ')
        case "$N" in
            ''|*[!0-9]*) N=0 ;;
        esac
        TOTAL=$((TOTAL + N))
    done

    if [ "$ANY_OK" -eq 0 ]; then
        printf 'unknown\n'
        return 0
    fi
    printf '%s\n' "$TOTAL"
}

# True (0) if no busy TCP clients to this instance's backend SOCKS endpoint.
# HAProxy talks to 10.66.<id>.2:1080 from the host netns; ss (iproute2) is available.
# Fail CLOSED: unknown/error ⇒ not idle (refuse MAX_CONN rotation).
is_instance_idle() {
    local INST_ID="$1"
    local COUNT

    if ! command -v ss >/dev/null 2>&1; then
        # Without ss we cannot prove idle; refuse forced rotation to avoid killing live traffic.
        return 1
    fi

    COUNT=$(count_instance_busy_clients "$INST_ID")
    case "$COUNT" in
        ''|*[!0-9]*)
            echo "==> [inst${INST_ID}] [WARN] 无法可靠统计 busy 连接（${COUNT:-?}），视为非空闲"
            return 1
            ;;
    esac
    [ "$COUNT" -eq 0 ]
}

# Prints drain wait budget:
#   empty  → infinite (wait until busy=0; no force timeout)
#   0      → skip wait / stop immediately
#   N>0    → max seconds
# Blank/unset/non-numeric → infinite (prefer not killing long-lived IM sessions).
get_instance_drain_timeout() {
    RAW=${INSTANCE_DRAIN_TIMEOUT-}
    case "$RAW" in
        '')
            printf '\n'
            return 0
            ;;
        *[!0-9]*)
            printf '\n'
            return 0
            ;;
    esac
    printf '%s\n' "$RAW"
}

# Busy HAProxy→backend sockets for one instance (host netns view).
count_instance_busy_clients() {
    local INST_ID="$1"
    local NS_IP

    NS_IP=$(get_instance_ns_ip "$INST_ID")
    # FILTER must be separate ss tokens: dst host:port
    count_busy_tcp_sockets "dst ${NS_IP}:1080"
}

# Wait until instance has no busy client sockets.
# INSTANCE_DRAIN_TIMEOUT empty/unset → wait indefinitely (IM-friendly).
# 0 → skip wait; positive N → force-stop after N seconds.
# Returns 0 if drained idle, 1 if timed out / cannot observe (caller still stops SOCKS).
wait_instance_drain() {
    local INST_ID="$1"
    local TIMEOUT COUNT SLEPT

    TIMEOUT=$(get_instance_drain_timeout)
    # Explicit 0 only: empty TIMEOUT means infinite wait below.
    if [ -n "$TIMEOUT" ] && [ "$TIMEOUT" -le 0 ]; then
        echo "==> [inst${INST_ID}] INSTANCE_DRAIN_TIMEOUT=0，跳过连接排空，立即停服务"
        return 1
    fi

    if ! command -v ss >/dev/null 2>&1; then
        echo "==> [inst${INST_ID}] [WARN] 无 ss，无法观察 busy 连接，跳过排空直接停服务"
        return 1
    fi

    COUNT=$(count_instance_busy_clients "$INST_ID")
    case "$COUNT" in
        ''|*[!0-9]*)
            if [ -n "$TIMEOUT" ]; then
                echo "==> [inst${INST_ID}] [WARN] busy 统计不可靠（${COUNT:-?}），仍等待最多 ${TIMEOUT}s 后停服务"
            else
                echo "==> [inst${INST_ID}] [WARN] busy 统计不可靠（${COUNT:-?}），无限期等待至可观测且空闲（未设 INSTANCE_DRAIN_TIMEOUT）"
            fi
            COUNT=-1
            ;;
    esac
    if [ "$COUNT" -eq 0 ]; then
        echo "==> [inst${INST_ID}] 已无 busy 连接，可以停服务"
        return 0
    fi

    if [ "$COUNT" -gt 0 ] || [ "$COUNT" -lt 0 ]; then
        if [ -n "$TIMEOUT" ]; then
            echo "==> [inst${INST_ID}] 复活进度: 开始排空 busy=${COUNT}，最长等待 ${TIMEOUT}s"
        else
            echo "==> [inst${INST_ID}] 复活进度: 开始排空 busy=${COUNT}，无超时上限（等到空闲）"
        fi
    fi
    SLEPT=0
    while true; do
        sleep 1
        SLEPT=$((SLEPT + 1))
        COUNT=$(count_instance_busy_clients "$INST_ID")
        case "$COUNT" in
            ''|*[!0-9]*) COUNT=-1 ;;
        esac
        if [ "$COUNT" -eq 0 ]; then
            echo "==> [inst${INST_ID}] 复活进度: 排空完成 busy=0，已等待 ${SLEPT}s → 停 SOCKS"
            return 0
        fi
        if [ -n "$TIMEOUT" ] && [ "$SLEPT" -ge "$TIMEOUT" ]; then
            echo "==> [inst${INST_ID}] 复活进度: 排空超时 ${TIMEOUT}s 仍 busy=${COUNT} → 强制停 SOCKS"
            return 1
        fi
        # Keep log noise low: every 5s.
        if [ $((SLEPT % 5)) -eq 0 ]; then
            if [ -n "$TIMEOUT" ]; then
                echo "==> [inst${INST_ID}] 复活进度: 排空中 busy=${COUNT}，已等待 ${SLEPT}s/${TIMEOUT}s"
            else
                echo "==> [inst${INST_ID}] 复活进度: 排空中 busy=${COUNT}，已等待 ${SLEPT}s（无上限，等到空闲）"
            fi
            # fleet snapshot every 30s while this inst drains
            if [ $((SLEPT % 30)) -eq 0 ]; then
                print_health_summary 2>/dev/null || true
            fi
        fi
    done
}

# After runtime drain: wait for idle (or timeout), then stop internal SOCKS.
# Servers stay in HAProxy config permanently; admin state goes to maint until revive.
drain_and_stop_instance_socks() {
    local INST_ID="$1"
    wait_instance_drain "$INST_ID" || true
    stop_instance_socks "$INST_ID"
    set_instance_status "$INST_ID" "down"
    # maint: no new traffic + stop health-checks while we restart WARP/SOCKS (no reload).
    haproxy_set_server_state "$INST_ID" "maint" || true
}

# True (0) when healthy instances are strictly less than half of WARP_INSTANCE_COUNT.
# Uses integer compare: healthy * 2 < total  (e.g. 1/3 → skip; 2/3 → allow; 1/2 → allow).
healthy_instances_below_half() {
    local TOTAL HEALTHY
    TOTAL=${WARP_INSTANCE_COUNT:-1}
    case "$TOTAL" in
        ''|*[!0-9]*)
            TOTAL=1
            ;;
    esac
    if [ "$TOTAL" -le 0 ]; then
        TOTAL=1
    fi

    HEALTHY=$(count_healthy_instances 2>/dev/null || printf '0')
    case "$HEALTHY" in
        ''|*[!0-9]*)
            HEALTHY=0
            ;;
    esac

    [ "$((HEALTHY * 2))" -lt "$TOTAL" ]
}

# Returns 0 if this healthy multi-instance backend should be force-rotated now:
# continuous uptime >= MAX_CONN_DURATION AND ready/up pool not below half.
# Busy is OK: recovery enters runtime drain first, then waits until idle (or until
# INSTANCE_DRAIN_TIMEOUT if set) before stopping SOCKS.
# Single-instance (WARP_INSTANCES<=1) always returns 1 — never force-offline.
instance_should_force_rotate_for_max_conn() {
    local INST_ID="$1"
    local THRESHOLD SINCE NOW_EPOCH ELAPSED HEALTHY TOTAL BUSY DRAIN_TO
    THRESHOLD=$(get_max_conn_duration)

    if [ "$THRESHOLD" -le 0 ]; then
        return 1
    fi

    TOTAL=${WARP_INSTANCE_COUNT:-1}
    case "$TOTAL" in
        ''|*[!0-9]*) TOTAL=1 ;;
    esac
    # Single-instance path must never be force-rotated by MAX_CONN_DURATION.
    if [ "$TOTAL" -le 1 ]; then
        return 1
    fi

    SINCE=$(get_instance_online_since_epoch "$INST_ID")
    case "$SINCE" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    NOW_EPOCH=$(date +%s)
    ELAPSED=$((NOW_EPOCH - SINCE))
    if [ "$ELAPSED" -lt 0 ]; then
        ELAPSED=0
    fi

    if [ "$ELAPSED" -lt "$THRESHOLD" ]; then
        return 1
    fi

    # Capacity guard: never MAX_CONN-drain when ready(up) pool is already < half.
    if healthy_instances_below_half; then
        HEALTHY=$(count_healthy_instances 2>/dev/null || printf '0')
        echo "==> [inst${INST_ID}] 已连续在线 ${ELAPSED}s ≥ ${THRESHOLD}s，但 ready 实例 ${HEALTHY}/${TOTAL} 少于一半，跳过 MAX_CONN drain"
        return 1
    fi

    BUSY=$(count_instance_busy_clients "$INST_ID" 2>/dev/null || printf '?')
    case "$BUSY" in
        ''|*[!0-9]*) BUSY='?' ;;
    esac
    DRAIN_TO=$(get_instance_drain_timeout)
    if [ "$BUSY" = "0" ]; then
        echo "==> [inst${INST_ID}] 已连续在线 ${ELAPSED}s ≥ ${THRESHOLD}s 且空闲(busy=0)，准备 drain 后强制重连"
    elif [ -n "$DRAIN_TO" ]; then
        echo "==> [inst${INST_ID}] 已连续在线 ${ELAPSED}s ≥ ${THRESHOLD}s 且仍有 busy=${BUSY} → 仍进入 drain，空闲或 ${DRAIN_TO}s 超时后再停 SOCKS/重连"
    else
        echo "==> [inst${INST_ID}] 已连续在线 ${ELAPSED}s ≥ ${THRESHOLD}s 且仍有 busy=${BUSY} → 仍进入 drain，无限期等到空闲后再停 SOCKS/重连（未设 INSTANCE_DRAIN_TIMEOUT）"
    fi
    return 0
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
    _oid=$1
    FILE=$(get_instance_offline_since_file "$_oid")
    mkdir -p "$(dirname "$FILE")"
    if [ ! -f "$FILE" ]; then
        date +%s > "$FILE"
        echo "==> [inst${_oid}] 开始累计离线时间（超过 $(get_config_stale_offline_seconds)s 未上线将强制换新配置）"
    fi
}

clear_instance_offline_since() {
    _oid=$1
    rm -f "$(get_instance_offline_since_file "$_oid")"
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
    _oid=$1
    SINCE=$(get_instance_offline_since_epoch "$_oid")
    [ -n "$SINCE" ] || return 1
    is_offline_long_enough_for_stale_config "$SINCE"
}

record_single_offline_since() {
    FILE=$(get_single_offline_since_file)
    mkdir -p "$(dirname "$FILE")"
    if [ ! -f "$FILE" ]; then
        date +%s > "$FILE"
        echo "==> 开始累计离线时间（超过 $(get_config_stale_offline_seconds)s 未上线将强制换新配置）"
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

get_config_retry_queue_dir() {
    printf '%s/config_retry.queue\n' "$INSTANCE_STATE_DIR"
}

get_config_retry_worker_pid_file() {
    printf '%s/config_retry.worker.pid\n' "$INSTANCE_STATE_DIR"
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
    local INST_ID="$1"
    local PID_FILE PID
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

# Count instances currently in background recovery (live recover pid).
count_instances_recovering() {
    local _id N=0
    for _id in $(get_instance_ids "${WARP_INSTANCE_COUNT:-1}"); do
        if is_instance_recovering "$_id"; then
            N=$((N + 1))
        fi
    done
    printf '%s\n' "$N"
}

count_instances_with_status() {
    local WANT="$1"
    local _id ST N=0
    for _id in $(get_instance_ids "${WARP_INSTANCE_COUNT:-1}"); do
        ST=$(get_instance_status "$_id")
        if [ "$ST" = "$WANT" ]; then
            N=$((N + 1))
        fi
    done
    printf '%s\n' "$N"
}

# Busy sockets are only meaningful while draining (wait_instance_drain).
# Do NOT ss-scan every instance on the monitor tick — wasteful for up/standby.
sum_draining_busy_clients() {
    local _id ST C TOTAL=0
    for _id in $(get_instance_ids "${WARP_INSTANCE_COUNT:-1}"); do
        ST=$(get_instance_status "$_id")
        [ "$ST" = "draining" ] || continue
        C=$(count_instance_busy_clients "$_id" 2>/dev/null || printf '0')
        case "$C" in
            ''|*[!0-9]*) continue ;;
        esac
        TOTAL=$((TOTAL + C))
    done
    printf '%s\n' "$TOTAL"
}

# Back-compat alias (callers that still say "all" only get draining busy).
sum_all_busy_clients() {
    sum_draining_busy_clients
}

# One-line fleet health: 健康 9/10，后台复活中 1
# busy only reported when someone is draining (else omit / show -).
print_health_summary() {
    local TOTAL HEALTHY RECOVERING DRAINING DOWN BUSY EXTRA
    TOTAL=${WARP_INSTANCE_COUNT:-1}
    HEALTHY=$(count_healthy_instances 2>/dev/null || printf '0')
    RECOVERING=$(count_instances_recovering 2>/dev/null || printf '0')
    DRAINING=$(count_instances_with_status draining 2>/dev/null || printf '0')
    DOWN=$(count_instances_with_status down 2>/dev/null || printf '0')
    EXTRA="draining ${DRAINING}，down ${DOWN}"
    case "$DRAINING" in
        ''|0)
            echo "==> 健康 ${HEALTHY}/${TOTAL}，后台复活中 ${RECOVERING}（${EXTRA}）"
            ;;
        *)
            BUSY=$(sum_draining_busy_clients 2>/dev/null || printf '0')
            echo "==> 健康 ${HEALTHY}/${TOTAL}，后台复活中 ${RECOVERING}（${EXTRA}，排空中busy=${BUSY}）"
            ;;
    esac
}


stop_instance_recovery() {
    local INST_ID="$1"
    local PID_FILE PID i
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
    local _iid
    for _iid in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        stop_instance_recovery "$_iid"
    done
    stop_config_retry_worker
}

# --- Serial background queue for instances that failed WARP config fetch ---
# One worker processes the queue FIFO so register API is not stampeded, and a
# single bad inst never exits the whole container.
is_config_retry_worker_running() {
    local PID_FILE PID
    PID_FILE=$(get_config_retry_worker_pid_file)
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

stop_config_retry_worker() {
    local PID_FILE PID i
    PID_FILE=$(get_config_retry_worker_pid_file)
    if [ -f "$PID_FILE" ]; then
        PID=$(tr -d '\n' < "$PID_FILE")
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
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

is_instance_queued_for_config_retry() {
    local INST_ID="$1"
    local QDIR
    QDIR=$(get_config_retry_queue_dir)
    [ -f "${QDIR}/${INST_ID}" ]
}

# List queued instance ids in FIFO order (by mtime, then name).
list_config_retry_queue_ids() {
    local QDIR
    QDIR=$(get_config_retry_queue_dir)
    if [ ! -d "$QDIR" ]; then
        return 0
    fi
    # Prefer ls -1tr (oldest first). Fall back to plain names if busybox lacks -t.
    if ls -1tr "$QDIR" >/dev/null 2>&1; then
        ls -1tr "$QDIR" 2>/dev/null | sed '/^$/d'
    else
        ls -1 "$QDIR" 2>/dev/null | sed '/^$/d' | sort -n
    fi
}

enqueue_instance_config_retry() {
    local INST_ID="$1"
    local QDIR MARK
    QDIR=$(get_config_retry_queue_dir)
    mkdir -p "$QDIR" "$INSTANCE_STATE_DIR"
    MARK="${QDIR}/${INST_ID}"
    if [ -f "$MARK" ]; then
        echo "==> [inst${INST_ID}] 已在配置重试队列中，跳过重复入队"
    else
        # Record enqueue time for FIFO / observability.
        date +%s > "$MARK" 2>/dev/null || printf '1\n' > "$MARK"
        echo "==> [inst${INST_ID}] 配置获取失败 → 已加入后台串行重试队列"
    fi
    set_instance_status "$INST_ID" "down"
    record_instance_offline_since "$INST_ID"
    ensure_config_retry_worker
}

# Full bring-up after a late successful registration (netns may not exist yet).
bring_up_instance_after_config() {
    local INST_ID="$1"
    local CONF_PATH
    CONF_PATH=$(get_instance_conf_path "$INST_ID")

    if [ ! -f "$CONF_PATH" ]; then
        echo "==> [inst${INST_ID}] [WARN] bring_up_instance_after_config: 配置仍不存在"
        return 1
    fi

    print_warp_identity_summary "$CONF_PATH" "inst${INST_ID}"
    setup_instance_netns "$INST_ID" || true
    start_instance_warp "$INST_ID" || true

    if run_instance_health_checks "$INST_ID"; then
        mark_instance_up "$INST_ID"
        reload_haproxy_from_status
        echo "==> [inst${INST_ID}] 🎉 队列重试注册后已上线并加入 LB"
        return 0
    fi

    echo "==> [inst${INST_ID}] 配置已生成但连通性未过，交给常规后台复活 worker"
    request_instance_recovery "$INST_ID"
    return 1
}

# One serial worker: FIFO over failed register attempts. Never exits the container.
config_retry_worker() {
    local PID_FILE QDIR INST_ID CONF_PATH BACKOFF MAX_BACKOFF EMPTY_ROUNDS
    PID_FILE=$(get_config_retry_worker_pid_file)
    QDIR=$(get_config_retry_queue_dir)
    # Parent records real job pid via $!. Do not overwrite with $$ (BusyBox ash).
    # shellcheck disable=SC2064
    trap 'rm -f "$PID_FILE"' EXIT INT TERM

    BACKOFF=5
    MAX_BACKOFF=60
    EMPTY_ROUNDS=0
    echo "==> 配置串行重试 worker 启动"

    while true; do
        INST_ID=$(list_config_retry_queue_ids | head -n1 || true)
        if [ -z "$INST_ID" ]; then
            EMPTY_ROUNDS=$((EMPTY_ROUNDS + 1))
            # Stay alive briefly in case bootstrap enqueues more; then exit cleanly.
            if [ "$EMPTY_ROUNDS" -ge 3 ]; then
                echo "==> 配置重试队列已空，worker 退出"
                rm -f "$PID_FILE"
                trap - EXIT INT TERM
                exit 0
            fi
            sleep 2
            continue
        fi
        EMPTY_ROUNDS=0

        CONF_PATH=$(get_instance_conf_path "$INST_ID")
        echo "==> [inst${INST_ID}] 队列串行重试：获取/注册 WARP 配置..."

        if [ -f "$CONF_PATH" ] && ! is_enabled "$ROTATE_IP_ON_START"; then
            echo "==> [inst${INST_ID}] 队列中发现配置已存在，直接拉起"
            rm -f "${QDIR}/${INST_ID}"
            bring_up_instance_after_config "$INST_ID" || true
            BACKOFF=5
            continue
        fi

        if with_dir_lock "$(get_register_lock_dir)" generate_warp_config "$CONF_PATH"; then
            rm -f "${QDIR}/${INST_ID}"
            bring_up_instance_after_config "$INST_ID" || true
            BACKOFF=5
            continue
        fi

        # Keep marker; move to end of FIFO by refreshing mtime after siblings.
        date +%s > "${QDIR}/${INST_ID}" 2>/dev/null || true
        echo "==> [inst${INST_ID}] 队列本轮注册仍失败，${BACKOFF}s 后继续串行重试（不退出容器）"
        sleep "$BACKOFF"
        BACKOFF=$((BACKOFF * 2))
        if [ "$BACKOFF" -gt "$MAX_BACKOFF" ]; then
            BACKOFF=$MAX_BACKOFF
        fi
    done
}

ensure_config_retry_worker() {
    local _pid _pid_file
    mkdir -p "$INSTANCE_STATE_DIR"
    if is_config_retry_worker_running; then
        return 0
    fi
    _pid_file=$(get_config_retry_worker_pid_file)
    echo "==> 拉起配置串行重试 worker..."
    config_retry_worker &
    _pid=$!
    echo "$_pid" > "$_pid_file"
    echo "==> 配置串行重试 worker 已记录 PID ${_pid}"
}

render_haproxy_config() {
    BIND_IP=$1
    BIND_P=$2
    STATUS_LIST=$3
    # NOTE: every known instance stays in the config for its whole life.
    # Availability is toggled at runtime via stats socket:
    #   set server warp_pool/instK state {ready|drain|maint}
    # — no add/remove server lines, no reload on drain/ready (saves reload churn).

    cat <<EOF
global
    daemon
    master-worker
    maxconn 4096
    # Explicit root + chroot /: we intentionally run privileged in this container
    # (netns / bind). Silences HAProxy 3.x startup warnings that look like crashes.
    user root
    chroot /
    stats socket ${HAPROXY_SOCK:-/var/run/microwarp/haproxy.sock} mode 600 level admin

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
        _sid=${ITEM%%:*}
        # status ignored for membership — always emit the server line
        ENDPOINT=$(get_instance_socks_endpoint "$_sid")
        printf '    server inst%s %s check inter 3s fall 2 rise 1\n' "$_sid" "$ENDPOINT"
    done
    IFS=$OLD_IFS
}

get_haproxy_sock() {
    printf '%s\n' "${HAPROXY_SOCK:-$INSTANCE_STATE_DIR/haproxy.sock}"
}

# Send one CLI command to the master stats socket. No reload.
# Returns 0 if the socket accepts the command (HAProxy replies).
haproxy_runtime_cmd() {
    local CMD="$1"
    local SOCK OUT
    SOCK=$(get_haproxy_sock)

    if [ ! -S "$SOCK" ]; then
        return 1
    fi

    if command -v socat >/dev/null 2>&1; then
        OUT=$(printf '%s\n' "$CMD" | socat -T2 STDIO "UNIX-CONNECT:${SOCK}" 2>/dev/null) || return 1
        # HAProxy returns empty or an error string; treat obvious failures.
        case "$OUT" in
            *'Unknown command'*|*'No such'*|*'failed'*)
                return 1
                ;;
        esac
        return 0
    fi

    # Minimal Python fallback (rarely present in the image).
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$SOCK" "$CMD" <<'PY' 2>/dev/null
import socket, sys
sock_path, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect(sock_path)
s.sendall((cmd + "\n").encode())
data = b""
try:
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
except Exception:
    pass
s.close()
text = data.decode(errors="replace")
if "Unknown command" in text or "No such" in text:
    sys.exit(1)
sys.exit(0)
PY
        return $?
    fi

    return 1
}

# Admin state: ready | drain | maint  (HAProxy official runtime API — no reload).
haproxy_set_server_state() {
    local INST_ID="$1"
    local STATE="$2"
    local CMD

    case "$STATE" in
        ready|drain|maint) ;;
        *)
            echo "==> [inst${INST_ID}] [WARN] invalid HAProxy state '$STATE'"
            return 1
            ;;
    esac

    CMD="set server warp_pool/inst${INST_ID} state ${STATE}"
    if haproxy_runtime_cmd "$CMD"; then
        echo "==> [inst${INST_ID}] HAProxy runtime state → ${STATE}（无 reload）"
        return 0
    fi
    echo "==> [inst${INST_ID}] [WARN] HAProxy runtime state ${STATE} 失败（socket 不可用或命令被拒）"
    return 1
}

get_haproxy_pid_file() {
    printf '%s/haproxy.pid\n' "$INSTANCE_STATE_DIR"
}

# True if $1 looks like a live process id we can signal.
is_live_pid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$1" 2>/dev/null
}

# Always re-read the pidfile. Background recovery workers inherit a stale copy of
# HAPROXY_PID; treating that dead-but-nonempty value as authoritative caused cold
# starts (and a new "已上线" log line + new PID) on almost every backend change.
# Prefer: live pidfile → live shell HAPROXY_PID → empty.
refresh_haproxy_pid() {
    local PID_FILE CAND
    PID_FILE=$(get_haproxy_pid_file)

    if [ -f "$PID_FILE" ]; then
        CAND=$(tr -d ' \n\r\t' < "$PID_FILE" 2>/dev/null || true)
        if is_live_pid "$CAND"; then
            HAPROXY_PID=$CAND
            return 0
        fi
    fi

    if is_live_pid "$HAPROXY_PID"; then
        # Shell has a live pid the file lost — rewrite file for other workers.
        printf '%s\n' "$HAPROXY_PID" > "$PID_FILE" 2>/dev/null || true
        return 0
    fi

    HAPROXY_PID=""
    return 1
}

# Master-worker soft reload keeps the same master PID (USR2). Fallback: -sf.
# Returns 0 only if a live master remains afterwards.
haproxy_try_soft_reload() {
    local CFG="$1"
    local PID_FILE OLD_PID
    PID_FILE=$(get_haproxy_pid_file)

    refresh_haproxy_pid || return 1
    OLD_PID=$HAPROXY_PID

    # Preferred: signal existing master (master-worker). PID stays stable.
    if kill -USR2 "$OLD_PID" 2>/dev/null; then
        # Give master a moment to re-exec workers / rewrite pidfile if needed.
        sleep 0.2 2>/dev/null || true
        if refresh_haproxy_pid && [ "$HAPROXY_PID" = "$OLD_PID" ]; then
            return 0
        fi
        # Master may have rewritten pidfile with same or new pid; still live is OK.
        if is_live_pid "$HAPROXY_PID"; then
            return 0
        fi
        # USR2 accepted but process gone — fall through.
    fi

    # Fallback: classic soft-finish (new process, old finishes). PID will change.
    if haproxy -W -D -f "$CFG" -p "$PID_FILE" -sf "$OLD_PID" 2>/dev/null; then
        sleep 0.1 2>/dev/null || true
        if refresh_haproxy_pid; then
            return 0
        fi
    fi

    return 1
}

haproxy_cold_start() {
    local CFG="$1"
    local PID_FILE
    PID_FILE=$(get_haproxy_pid_file)

    # Best-effort stop any leftover master we still know about.
    if refresh_haproxy_pid; then
        kill "$HAPROXY_PID" 2>/dev/null || true
        sleep 0.2 2>/dev/null || true
        kill -9 "$HAPROXY_PID" 2>/dev/null || true
    fi
    HAPROXY_PID=""

    haproxy -W -D -f "$CFG" -p "$PID_FILE"
    sleep 0.1 2>/dev/null || true
    if refresh_haproxy_pid; then
        record_socks_online_started_at
        return 0
    fi
    return 1
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
        echo "==> WARP 设备身份摘要 [${LABEL}]:"
    else
        echo "==> WARP 设备身份摘要:"
    fi
    echo "==>   PrivateKey SHA256/16: ${PRIVATE_KEY_FINGERPRINT}"
    [ -n "$IPV4_ADDRESS" ] && echo "==>   Interface IPv4: ${IPV4_ADDRESS}"
    [ -n "$IPV6_ADDRESS" ] && echo "==>   Interface IPv6: ${IPV6_ADDRESS}"
    [ -n "$ENDPOINT" ] && echo "==>   Peer Endpoint: ${ENDPOINT}"
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

# Effective proxy for WARP register API only.
# Priority:
#   1) explicit WARP_API_PROXY (always wins)
#   2) multi-instance + healthy backends > 1 → local HAProxy SOCKS (socks5h)
#   3) otherwise direct (no proxy)
# Healthy>1 avoids chicken-and-egg on first boot (0/1 up still register direct).
get_effective_warp_api_proxy() {
    local HEALTHY
    if [ -n "$WARP_API_PROXY" ]; then
        printf '%s\n' "$WARP_API_PROXY"
        return 0
    fi

    case "${WARP_INSTANCE_COUNT:-1}" in
        ''|*[!0-9]*)
            printf '\n'
            return 0
            ;;
    esac

    if [ "$WARP_INSTANCE_COUNT" -le 1 ]; then
        printf '\n'
        return 0
    fi

    HEALTHY=$(count_healthy_instances 2>/dev/null || printf '0')
    case "$HEALTHY" in
        ''|*[!0-9]*)
            HEALTHY=0
            ;;
    esac

    if [ "$HEALTHY" -gt 1 ]; then
        # Loopback only: BIND_ADDR may be 0.0.0.0 which is not a valid curl proxy host.
        # socks5h = resolve API hostname via the proxy (through a healthy WARP inst).
        printf 'socks5h://127.0.0.1:%s\n' "${LISTEN_PORT:-1080}"
        return 0
    fi

    printf '\n'
    return 0
}

fetch_warp_config() {
    local EFFECTIVE_PROXY
    API_URLS=$(printf '%s' "$WARP_API_URL" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')
    [ -n "$API_URLS" ] || return 1

    EFFECTIVE_PROXY=$(get_effective_warp_api_proxy)

    OLD_IFS=$IFS
    IFS='
'
    for API_URL in $API_URLS; do
        [ -n "$API_URL" ] || continue
        echo "==> API 地址: ${API_URL}"

        if [ -n "$EFFECTIVE_PROXY" ]; then
            if [ -n "$WARP_API_PROXY" ]; then
                echo "==> API 请求将通过已配置代理发起 (${EFFECTIVE_PROXY})"
            else
                echo "==> API 请求经本机 HAProxy SOCKS 发起（健康实例>1，${EFFECTIVE_PROXY}）"
            fi
            curl --proxy "$EFFECTIVE_PROXY" --retry 3 --retry-delay 2 --max-time 15 --silent --location --fail \
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

        echo "==> [WARN] API 请求失败，尝试下一个地址..."
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
        echo "==> 正在向 API 注册新设备 (第${attempt}次尝试)... -> ${target_conf}"

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
                        echo "==> 🔀 检测到自定义 Endpoint 候选，已随机选中节点: $ENDPOINT_IP_SELECTED"
                        ENDPOINT="$ENDPOINT_IP_SELECTED"
                    else
                        echo "==> 🔀 检测到自定义 Endpoint IP，正在覆盖默认节点: $ENDPOINT_IP"
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
                echo "==> 节点配置生成成功！(${target_conf})"
                return 0
            fi
        fi

        echo "==> [WARN] 第${attempt}次返回无效配置，原始内容预览："
        head -30 "$raw_conf" 2>/dev/null || true
        rm -f "$raw_conf"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$max_retries" ] && sleep 5
    done

    echo "==> [ERROR] API 连续 ${max_retries} 次失败，无法生成有效配置！"
    # Never exit the container here: multi-instance bootstrap/recovery must
    # keep running and hand the failed inst to a serial background retry queue.
    # Callers that need hard-fail (single-instance first boot) check the return code.
    return 1
}

prepare_wg_quick_compat() {
    sed -i '/src_valid_mark/d' /usr/bin/wg-quick 2>/dev/null || true
}

start_warp_interface() {
    PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
    PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
    PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

    echo "==> 正在启动 Linux 内核级 wg0 网卡..."
    if ! wg-quick up wg0 > /dev/null 2>&1; then
        echo "==> [WARN] wg0 启动失败"
        return 1
    fi

    TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
    if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
        if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
            echo "==> 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由"
        fi
    fi

    sleep 3
    echo "==> 隧道已启动"
    return 0
}

restart_warp_with_new_identity() {
    wg-quick down wg0 > /dev/null 2>&1 || true
    if ! generate_warp_config; then
        echo "==> [WARN] 重新注册失败，保留旧配置并交由上层重试"
        return 1
    fi
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
        echo "==> 巡检通过，SOCKS 服务继续保持在线"
        return 0
    fi

    NOW_EPOCH=$(date +%s)
    UPTIME_SECONDS=$((NOW_EPOCH - SOCKS_ONLINE_AT_EPOCH))
    [ "$UPTIME_SECONDS" -lt 0 ] && UPTIME_SECONDS=0
    UPTIME_TEXT=$(format_uptime_duration "$UPTIME_SECONDS")

    echo "==> 巡检通过，SOCKS 服务继续保持在线（上线时间: ${SOCKS_ONLINE_AT_TEXT}，已上线: ${UPTIME_TEXT}）"
}

start_socks() {
    if [ -z "$SOCKS_PID" ] || ! kill -0 "$SOCKS_PID" 2>/dev/null; then
        echo "==> 🟢 节点状态健康，正在启动 SOCKS 服务..."
        if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
            microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS" > /dev/null 2>&1 &
        else
            microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" > /dev/null 2>&1 &
        fi
        SOCKS_PID=$!
        record_socks_online_started_at
        echo "==> 🚀 MicroSOCKS 已上线 (监听: ${LISTEN_ADDR}:${LISTEN_PORT}, PID: ${SOCKS_PID})"
    fi
}

stop_socks() {
    if [ -n "$SOCKS_PID" ] && kill -0 "$SOCKS_PID" 2>/dev/null; then
        echo "==> 🛑 切断 SOCKS 服务，避免请求黑洞..."
        kill "$SOCKS_PID" 2>/dev/null || true
        wait "$SOCKS_PID" 2>/dev/null || true
        echo "==> 🔻 SOCKS 服务已下线"
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

# Default multi-source lists (comma-separated), ordered first-success-wins.
# Same-vendor endpoints are interleaved (e.g. 1.1.1.1 ... later 1.0.0.1)
# so a single provider outage does not burn adjacent slots.
# Prefer CF IP-literal /cdn-cgi/trace early (no DNS), then family-specific
# hostnames verified under curl -4/-6.
# Override via EGRESS_IP_V4_URLS / EGRESS_IP_V6_URLS if needed.
get_egress_ip_v4_urls() {
    RAW=${EGRESS_IP_V4_URLS:-https://1.1.1.1/cdn-cgi/trace,https://api4.ipify.org,https://ipv4.icanhazip.com,https://v4.ident.me,https://1.0.0.1/cdn-cgi/trace,https://ipinfo.io/ip,https://api.ipify.org}
    printf '%s\n' "$RAW"
}

get_egress_ip_v6_urls() {
    RAW=${EGRESS_IP_V6_URLS:-https://[2606:4700:4700::1111]/cdn-cgi/trace,https://api6.ipify.org,https://ipv6.icanhazip.com,https://[2606:4700:4700::1001]/cdn-cgi/trace,https://v6.ident.me}
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

# Max probe URLs to try per address family in one health check.
# Default 4: if 4 links all fail to yield an IP for a family, that family is done.
# If BOTH families get no IP after their tries, WARP is declared down.
# Set EGRESS_IP_FAIL_THRESHOLD=0 to only log and never hard-fail on IP alone.
get_egress_ip_fail_threshold() {
    RAW=${EGRESS_IP_FAIL_THRESHOLD:-4}
    case "$RAW" in
        ''|*[!0-9]*) printf '4\n' ;;
        *) printf '%s\n' "$RAW" ;;
    esac
}

# Probe one family through optional netns. Sets PROBED_IP on success.
# Tries at most EGRESS_IP_FAIL_THRESHOLD URLs (default 4), first-success-wins.
# Usage: probe_egress_ip_family <v4|v6> [netns_name]
# Sets PROBE_URL_ATTEMPTS to how many links were tried.
probe_egress_ip_family() {
    FAMILY=$1
    NS_NAME=${2:-}
    PROBED_IP=''
    PROBED_IP_SOURCE=''
    PROBE_URL_ATTEMPTS=0
    MAX_TIME=$(get_egress_ip_curl_max_time)
    MAX_URLS=$(get_egress_ip_fail_threshold)
    # 0 => try entire list (no hard cap); still used only as soft diagnostic by caller
    if [ "$MAX_URLS" -eq 0 ]; then
        MAX_URLS=9999
    fi

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
        if [ "$PROBE_URL_ATTEMPTS" -ge "$MAX_URLS" ]; then
            break
        fi
        PROBE_URL_ATTEMPTS=$((PROBE_URL_ATTEMPTS + 1))

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

# Dual-stack egress discovery for one health-check tick.
# Returns 0 if at least one family got an IP; 1 if all tried links failed.
# Sets TRACE_IP_V4 / TRACE_IP_V6 and EGRESS_IP_URLS_TRIED.
probe_egress_ips() {
    NS_NAME=${1:-}
    LABEL=${2:-}
    TRACE_IP_V4=''
    TRACE_IP_V6=''
    EGRESS_IP_URLS_TRIED=0
    PREFIX='==> '
    [ -n "$LABEL" ] && PREFIX="==> [${LABEL}]"

    PROBED_IP=''
    PROBED_IP_SOURCE=''
    PROBE_URL_ATTEMPTS=0
    if probe_egress_ip_family v4 "$NS_NAME"; then
        TRACE_IP_V4="ip=${PROBED_IP}"
        echo "${PREFIX} 出口 IPv4: ${PROBED_IP}  (via ${PROBED_IP_SOURCE}, tried ${PROBE_URL_ATTEMPTS} link(s))"
    fi
    EGRESS_IP_URLS_TRIED=$((EGRESS_IP_URLS_TRIED + PROBE_URL_ATTEMPTS))

    PROBED_IP=''
    PROBED_IP_SOURCE=''
    PROBE_URL_ATTEMPTS=0
    if probe_egress_ip_family v6 "$NS_NAME"; then
        TRACE_IP_V6="ip=${PROBED_IP}"
        echo "${PREFIX} 出口 IPv6: ${PROBED_IP}  (via ${PROBED_IP_SOURCE}, tried ${PROBE_URL_ATTEMPTS} link(s))"
    fi
    EGRESS_IP_URLS_TRIED=$((EGRESS_IP_URLS_TRIED + PROBE_URL_ATTEMPTS))

    if [ -n "$TRACE_IP_V4" ] || [ -n "$TRACE_IP_V6" ]; then
        return 0
    fi

    MAX_URLS=$(get_egress_ip_fail_threshold)
    echo "${PREFIX} ⚠️ 出口 IP 探测失败：本轮已试链接均未取到 IP（每栈最多试 ${MAX_URLS} 条，同厂商已错开）"
    return 1
}

# optional arg1 = inst id (empty for single-instance)
# Returns 0 on IP success;
#         1 soft fail only when EGRESS_IP_FAIL_THRESHOLD=0 (never hard-fail on IP);
#         2 hard fail: this round tried up to N links/family and got no IP → WARP down.
ensure_trace_ip() {
    # Use _tid only — never touch global INST_ID (ash/bash global assign leaks to caller loops).
    _tid=${1:-}
    LABEL=''
    NS_NAME=''
    if [ -n "$_tid" ]; then
        LABEL="inst${_tid}"
        NS_NAME=$(get_instance_netns_name "$_tid")
    fi

    if probe_egress_ips "$NS_NAME" "$LABEL"; then
        return 0
    fi

    THRESH=$(get_egress_ip_fail_threshold)
    PREFIX='==> '
    [ -n "$LABEL" ] && PREFIX="==> [${LABEL}]"

    if [ "$THRESH" -eq 0 ]; then
        echo "${PREFIX} 出口 IP 本轮未取到（EGRESS_IP_FAIL_THRESHOLD=0，不据此判死）"
        return 1
    fi

    echo "${PREFIX} 本轮 ${THRESH} 条链接内未取到出口 IP，判定 WARP 连接失败"
    return 2
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
        echo "==> 测速反馈 ${TARGET_URL} HTTP 状态码: ${TEST_HTTP_CODE}"

        if is_retryable_test_url_curl_exit "$CURL_EXIT" && [ "$ATTEMPT" -le "$RETRYABLE_FAILURE_RETRIES" ]; then
            RETRY_REASON=$(get_test_url_retry_reason "$CURL_EXIT")
            echo "==> ${TARGET_URL} ${RETRY_REASON}，5 秒后重试 (${ATTEMPT}/${RETRYABLE_FAILURE_RETRIES})..."
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
    # Egress IP: try up to EGRESS_IP_FAIL_THRESHOLD links per family (default 4).
    # If this round gets no IP from those links => WARP hard-fail (rc 2).
    # Soft rc 1 only when threshold is 0; then TEST_URLS may still pass.
    ensure_trace_ip
    IP_RC=$?

    if [ "$IP_RC" -eq 2 ]; then
        # This round: N links failed to yield any egress IP → WARP down.
        stop_socks
        return 1
    fi

    TEST_URLS_RAW=${TEST_URLS:-https://grok.com}
    TEST_URLS_LIST=$(printf '%s' "$TEST_URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')

    if [ -n "$TEST_URLS_LIST" ]; then
        check_test_urls
        return $?
    fi

    [ "$IP_RC" -eq 0 ]
}

restart_wg_interface() {
    echo "==> 正在断开并重连 wg0..."
    wg-quick down wg0 > /dev/null 2>&1 || true
    if start_warp_interface; then
        return 0
    fi

    echo "==> [WARN] WG 接口重连失败"
    return 1
}

try_wg_reconnect_recovery() {
    RECONNECT_RETRIES=$(get_wg_reconnect_retries)

    if [ "$RECONNECT_RETRIES" -le 0 ]; then
        echo "==> 已禁用 WG 重连重试，跳过接口重连阶段"
        return 1
    fi

    ATTEMPT=1
    while [ "$ATTEMPT" -le "$RECONNECT_RETRIES" ]; do
        echo "==> 正在执行 WG 重连重试 (${ATTEMPT}/${RECONNECT_RETRIES})..."
        if restart_wg_interface && run_health_checks; then
            echo "==> WG 重连后健康检查已恢复"
            return 0
        fi

        ATTEMPT=$((ATTEMPT + 1))
        [ "$ATTEMPT" -le "$RECONNECT_RETRIES" ] && sleep 3
    done

    echo "==> [WARN] WG 重连重试全部失败"
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

        echo "==> 连通性测试未通过！"
        stop_socks
        record_single_offline_since

        FORCE_NEW=0
        if single_should_force_new_config; then
            FORCE_NEW=1
            FILE=$(get_single_offline_since_file)
            SINCE=$(tr -d '\n' < "$FILE")
            NOW_EPOCH=$(date +%s)
            ELAPSED=$((NOW_EPOCH - SINCE))
            echo "==> 已连续离线 ${ELAPSED}s ≥ $(get_config_stale_offline_seconds)s，判定配置失效，跳过重连并强制换新配置"
        fi

        if [ "$FORCE_NEW" -eq 0 ]; then
            if try_wg_reconnect_recovery; then
                start_socks
                clear_single_offline_since
                return 0
            fi
            echo "==> WG 重连重试后仍未恢复，正在重新注册并重置节点..."
        fi

        if ! restart_warp_with_new_identity; then
            echo "==> 重新注册本轮失败，5s 后继续重试（不退出容器）"
            sleep 5
        fi
    done
}

periodic_test_url_monitor() {
    echo "==> 已启动守护模式，每 ${TEST_URLS_CHECK_INTERVAL} 秒进行一次健康巡检..."
    while true; do
        # 睡眠等待期间能随时响应容器的停止信号
        sleep "$TEST_URLS_CHECK_INTERVAL" & wait $!

        echo "==> 正在执行 TEST_URLS 巡检（间隔 ${TEST_URLS_CHECK_INTERVAL} 秒）..."

        # 巡检时直接发起检测，不干扰正常运行的 SOCKS
        if check_test_urls; then
            print_socks_health_check_success
            clear_single_offline_since
            continue
        fi

        # 只有在确诊不通返回了非零状态，才触发保护机制并切断网络
        echo "==> ❌ 巡检未通过！触发节点重选保护机制..."
        stop_socks
        record_single_offline_since

        # 进入修复死循环，修复成功后内部会重新调用 start_socks
        ensure_network_ready
    done
}

cleanup_on_exit() {
    echo "==> 收到退出信号，正在清理进程和网卡..."
    stop_socks
    wg-quick down wg0 >/dev/null 2>&1 || true
    exit 0
}

# ==========================================
# 多实例（单容器内）: netns + haproxy 健康 LB
# ==========================================
set_instance_status() {
    local INST_ID="$1"
    local STATUS="$2"
    mkdir -p "$INSTANCE_STATE_DIR"
    printf '%s\n' "$STATUS" > "$(get_instance_status_file "$INST_ID")"
}

get_instance_status() {
    local STATUS_FILE
    STATUS_FILE=$(get_instance_status_file "$1")
    if [ -f "$STATUS_FILE" ]; then
        tr -d '\n' < "$STATUS_FILE"
    else
        printf 'down'
    fi
}

collect_instance_status_list() {
    local LIST="" _iid STATUS
    for _iid in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        STATUS=$(get_instance_status "$_iid")
        if [ -n "$LIST" ]; then
            LIST="$LIST ${_iid}:${STATUS}"
        else
            LIST="${_iid}:${STATUS}"
        fi
    done
    printf '%s\n' "$LIST"
}

count_healthy_instances() {
    local COUNT=0 _iid
    for _iid in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        if [ "$(get_instance_status "$_iid")" = "up" ]; then
            COUNT=$((COUNT + 1))
        fi
    done
    printf '%s\n' "$COUNT"
}

# ---- Single-active rotate: primary + last_healthy + admin HTTP ----

get_primary_id() {
    local F
    F=$(get_primary_id_file)
    if [ -f "$F" ]; then
        tr -d ' \n\r\t' < "$F"
    else
        printf ''
    fi
}

set_primary_id() {
    local ID="$1"
    mkdir -p "$INSTANCE_STATE_DIR"
    printf '%s\n' "$ID" > "$(get_primary_id_file)"
}

clear_primary_id() {
    rm -f "$(get_primary_id_file)"
}

record_instance_last_healthy() {
    local INST_ID="$1"
    local F
    F=$(get_instance_last_healthy_file "$INST_ID")
    mkdir -p "$(dirname "$F")"
    date +%s > "$F"
}

get_instance_last_healthy_at() {
    local F VAL
    F=$(get_instance_last_healthy_file "$1")
    if [ -f "$F" ]; then
        VAL=$(tr -d ' \n\r\t' < "$F")
        case "$VAL" in
            ''|*[!0-9]*) printf '0' ;;
            *) printf '%s' "$VAL" ;;
        esac
    else
        printf '0'
    fi
}

clear_instance_last_healthy() {
    rm -f "$(get_instance_last_healthy_file "$1")"
}

# Candidate = status=up, not primary, not recovering.
# Pick max(last_healthy_at); tie-break = smaller inst id.
find_latest_healthy_standby() {
    local PRIMARY BEST_ID="" BEST_TS=-1 CAND TS
    PRIMARY=$(get_primary_id)
    for CAND in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        if [ -n "$PRIMARY" ] && [ "$CAND" = "$PRIMARY" ]; then
            continue
        fi
        if [ "$(get_instance_status "$CAND")" != "up" ]; then
            continue
        fi
        if is_instance_recovering "$CAND"; then
            continue
        fi
        TS=$(get_instance_last_healthy_at "$CAND")
        case "$TS" in
            ''|*[!0-9]*) TS=0 ;;
        esac
        if [ -z "$BEST_ID" ] || [ "$TS" -gt "$BEST_TS" ]; then
            BEST_ID=$CAND
            BEST_TS=$TS
        elif [ "$TS" -eq "$BEST_TS" ] && [ "$CAND" -lt "$BEST_ID" ] 2>/dev/null; then
            BEST_ID=$CAND
        fi
    done
    printf '%s\n' "$BEST_ID"
}

is_rotate_in_progress() {
    local D PID
    D="${INSTANCE_STATE_DIR}/rotate.lock.d"
    if [ ! -d "$D" ]; then
        return 1
    fi
    PID=""
    if [ -f "${D}/pid" ]; then
        PID=$(tr -d ' \n\r\t' < "${D}/pid" 2>/dev/null || true)
    fi
    if is_live_pid "$PID"; then
        return 0
    fi
    # Stale lock dir from crashed process
    rm -rf "$D"
    return 1
}

# Atomic-ish lock via mkdir (portable; better than plain pid file race).
acquire_rotate_lock() {
    local D
    D="${INSTANCE_STATE_DIR}/rotate.lock.d"
    mkdir -p "$INSTANCE_STATE_DIR"
    if is_rotate_in_progress; then
        return 1
    fi
    if mkdir "$D" 2>/dev/null; then
        printf '%s\n' "$$" > "${D}/pid"
        return 0
    fi
    # Lost race or leftover empty dir
    if is_rotate_in_progress; then
        return 1
    fi
    rm -rf "$D" 2>/dev/null || true
    if mkdir "$D" 2>/dev/null; then
        printf '%s\n' "$$" > "${D}/pid"
        return 0
    fi
    return 1
}

release_rotate_lock() {
    rm -rf "${INSTANCE_STATE_DIR}/rotate.lock.d"
}

haproxy_desired_state_for_instance() {
    local INST_ID="$1"
    local STATUS PRIMARY
    STATUS=$(get_instance_status "$INST_ID")
    PRIMARY=$(get_primary_id)
    case "$STATUS" in
        up)
            if [ -n "$PRIMARY" ] && [ "$INST_ID" = "$PRIMARY" ]; then
                printf 'ready\n'
            else
                # No primary yet, or standby: drain (hot standby / wait for promote)
                printf 'drain\n'
            fi
            ;;
        draining)
            printf 'drain\n'
            ;;
        *)
            printf 'maint\n'
            ;;
    esac
}

haproxy_reapply_instance_states() {
    local _iid DESIRED
    for _iid in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        DESIRED=$(haproxy_desired_state_for_instance "$_iid")
        haproxy_set_server_state "$_iid" "$DESIRED" || true
    done
}

promote_primary() {
    local NEW="$1"
    local OLD
    OLD=$(get_primary_id)
    if [ -z "$NEW" ]; then
        return 1
    fi
    if [ "$(get_instance_status "$NEW")" != "up" ]; then
        echo "==> promote_primary: inst${NEW} 不是 up，拒绝" >&2
        return 1
    fi
    set_primary_id "$NEW"
    haproxy_reapply_instance_states
    # Logs on stderr so request_primary_rotate stdout stays machine-readable (OK to=N).
    if [ -n "$OLD" ] && [ "$OLD" != "$NEW" ]; then
        echo "==> primary: inst${OLD} → inst${NEW}" >&2
    else
        echo "==> primary 设为 inst${NEW}" >&2
    fi
    return 0
}

# Publish rotate result for admin HTTP helper ASAP (atomic), independent of stdout pipes.
publish_rotate_result_line() {
    local LINE="$1"
    local RES TMP
    RES="${INSTANCE_STATE_DIR}/admin.rotate.res"
    TMP="${RES}.pub.$$"
    mkdir -p "$INSTANCE_STATE_DIR"
    printf '%s\n' "$LINE" > "$TMP"
    mv -f "$TMP" "$RES"
}

# Prints: OK to=N | ERR no_candidate | ERR in_progress
request_primary_rotate() {
    local OLD NEW
    if ! acquire_rotate_lock; then
        publish_rotate_result_line 'ERR in_progress'
        printf 'ERR in_progress\n'
        return 1
    fi

    OLD=$(get_primary_id)
    NEW=$(find_latest_healthy_standby)
    if [ -z "$NEW" ]; then
        release_rotate_lock || true
        publish_rotate_result_line 'ERR no_candidate'
        printf 'ERR no_candidate\n'
        return 1
    fi

    if ! promote_primary "$NEW"; then
        release_rotate_lock || true
        publish_rotate_result_line 'ERR no_candidate'
        printf 'ERR no_candidate\n'
        return 1
    fi

    # Unlock + publish HTTP result IMMEDIATELY after promote (atomic file).
    # Helper races the result file — must not wait on old-primary reconnect.
    release_rotate_lock || true
    publish_rotate_result_line "OK to=${NEW}"
    printf 'OK to=%s\n' "$NEW"

    # Old primary MUST leave the pool and do full WG reconnect (product lock).
    # request_instance_recovery itself is fast: runtime drain kick + spawn worker.
    # Long drain/WG work runs inside the worker — do NOT wrap in a silenced
    # background subshell (that hid all recovery logs and made "下线重连" look
    # like it never happened after a successful primary switch).
    if [ -n "$OLD" ] && [ "$OLD" != "$NEW" ]; then
        echo "==> rotate: 旧 primary inst${OLD} → force_rotate 下线重连（后台 worker）" >&2
        # Never let recovery abort the thin OK path (set -e); promote already done.
        request_instance_recovery "$OLD" "force_rotate" || true
    fi
    return 0
}

failover_primary_on_health_fail() {
    local FAILED="$1"
    local PRIMARY NEW
    PRIMARY=$(get_primary_id)
    if [ -z "$PRIMARY" ] || [ "$FAILED" != "$PRIMARY" ]; then
        request_instance_recovery "$FAILED"
        return 0
    fi

    # CRITICAL: detach FAILED before selection. clear_primary_id alone is not
    # enough — FAILED is still status=up with the freshest last_healthy, so
    # find_latest_healthy_standby would re-pick it as the new primary.
    detach_instance_from_lb "$FAILED" || true
    clear_primary_id
    NEW=$(find_latest_healthy_standby)
    if [ -n "$NEW" ] && [ "$NEW" != "$FAILED" ]; then
        promote_primary "$NEW" || true
        echo "==> primary 巡检失败 failover: inst${FAILED} → inst${NEW}" >&2
    else
        echo "==> primary 巡检失败且无健康 standby；恢复后首个 up 抢主" >&2
    fi
    # Already draining; request_instance_recovery re-detach is idempotent and
    # spawns the force WG reconnect worker.
    request_instance_recovery "$FAILED"
    return 0
}

# ---- Admin HMAC helpers (HTTP + HMAC-SHA256 + timestamp, skew default ±120s) ----
# Sign payload: METHOD + "\n" + PATH + "\n" + TIMESTAMP
# Headers: X-Timestamp / X-Signature  (also Authorization: HMAC-SHA256 ts=..,sig=..)

get_admin_hmac_skew_seconds() {
    RAW=${ADMIN_HTTP_HMAC_SKEW_SECONDS:-120}
    case "$RAW" in
        ''|*[!0-9]*)
            printf '120\n'
            return 0
            ;;
    esac
    printf '%s\n' "$RAW"
}

admin_hmac_sign_payload() {
    # $1=METHOD $2=PATH $3=TIMESTAMP
    printf '%s\n%s\n%s' "$1" "$2" "$3"
}

admin_hmac_hex() {
    # $1=secret $2=payload  → lowercase hex digest
    local SECRET="$1" PAYLOAD="$2" OUT
    if ! command -v openssl >/dev/null 2>&1; then
        printf ''
        return 1
    fi
    OUT=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" 2>/dev/null | awk '{print $NF}')
    printf '%s' "$OUT" | tr 'A-F' 'a-f'
}

admin_hmac_verify() {
    # $1=secret $2=method $3=path $4=timestamp $5=signature
    # return 0 if valid within skew window
    local SECRET="$1" METHOD="$2" RPATH="$3" TS="$4" SIG="$5"
    local NOW SKEW DELTA EXPECT PAYLOAD
    case "$TS" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$SIG" in
        '') return 1 ;;
    esac
    [ -n "$SECRET" ] || return 1
    NOW=$(date +%s)
    SKEW=$(get_admin_hmac_skew_seconds)
    DELTA=$((NOW - TS))
    if [ "$DELTA" -lt 0 ]; then
        DELTA=$((0 - DELTA))
    fi
    if [ "$DELTA" -gt "$SKEW" ]; then
        return 1
    fi
    PAYLOAD=$(admin_hmac_sign_payload "$METHOD" "$RPATH" "$TS")
    EXPECT=$(admin_hmac_hex "$SECRET" "$PAYLOAD")
    [ -n "$EXPECT" ] || return 1
    SIG=$(printf '%s' "$SIG" | tr 'A-F' 'a-f' | tr -d ' \t\r\n')
    [ "$SIG" = "$EXPECT" ]
}

stop_admin_http_server() {
    local PID_FILE PID WORKER
    PID_FILE=$(get_admin_http_pid_file)
    WORKER="${INSTANCE_STATE_DIR}/admin_cmd.worker.pid"
    if [ -f "$WORKER" ]; then
        PID=$(tr -d ' \n\r\t' < "$WORKER" 2>/dev/null || true)
        if is_live_pid "$PID"; then
            kill "$PID" 2>/dev/null || true
            wait "$PID" 2>/dev/null || true
        fi
        rm -f "$WORKER"
    fi
    if [ -f "$PID_FILE" ]; then
        PID=$(tr -d ' \n\r\t' < "$PID_FILE" 2>/dev/null || true)
        if is_live_pid "$PID"; then
            kill "$PID" 2>/dev/null || true
            wait "$PID" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

build_status_json() {
    local _iid STATUS ROLE PRIMARY LH FIRST=1 PJSON
    PRIMARY=$(get_primary_id)
    if [ -n "$PRIMARY" ]; then
        PJSON=$PRIMARY
    else
        PJSON=null
    fi
    printf '{"ok":true,"primary":%s,"warp_instances":%s,"instances":[' "$PJSON" "$WARP_INSTANCE_COUNT"
    for _iid in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        STATUS=$(get_instance_status "$_iid")
        LH=$(get_instance_last_healthy_at "$_iid")
        if [ -n "$PRIMARY" ] && [ "$_iid" = "$PRIMARY" ]; then
            ROLE=primary
        elif [ "$STATUS" = "up" ]; then
            ROLE=standby
        else
            ROLE=other
        fi
        if [ "$FIRST" -eq 1 ]; then
            FIRST=0
        else
            printf ','
        fi
        printf '{"id":%s,"status":"%s","role":"%s","last_healthy":%s}' "$_iid" "$STATUS" "$ROLE" "$LH"
    done
    printf ']}'
}

admin_cmd_worker() {
    local REQ_FILE RES_FILE STATUS_FILE STATUS_RES TMP
    REQ_FILE="${INSTANCE_STATE_DIR}/admin.rotate.req"
    RES_FILE="${INSTANCE_STATE_DIR}/admin.rotate.res"
    STATUS_FILE="${INSTANCE_STATE_DIR}/admin.status.req"
    STATUS_RES="${INSTANCE_STATE_DIR}/admin.status.res"
    while true; do
        if [ -f "$STATUS_FILE" ]; then
            # Atomic publish: avoid helper reading empty/truncated status file.
            TMP="${STATUS_RES}.tmp.$$"
            build_status_json > "$TMP" 2>/dev/null || printf '{"ok":false}' > "$TMP"
            mv -f "$TMP" "$STATUS_RES"
            rm -f "$STATUS_FILE"
        fi
        if [ -f "$REQ_FILE" ]; then
            # Result file is published atomically inside request_primary_rotate
            # (publish_rotate_result_line) as soon as promote succeeds/fails.
            # Do NOT redirect stdout/stderr of this call: background recovery
            # workers inherit the caller's fds — >/dev/null would silence all
            # "下线重连" progress logs for the old primary after a successful switch.
            # HTTP body stays thin via the res file; container logs stay verbose.
            request_primary_rotate || true
            rm -f "$REQ_FILE"
        fi
        sleep 0.1
    done
}

admin_http_loop() {
    local HELPER
    HELPER="${INSTANCE_STATE_DIR}/admin_http_handler.sh"
    mkdir -p "$INSTANCE_STATE_DIR"
    cat > "$HELPER" <<'HELPER_EOF'
#!/bin/sh
# Admin HTTP auth: HMAC-SHA256 + timestamp (± skew seconds, default 120).
# Payload: METHOD + "\n" + PATH + "\n" + TIMESTAMP
# Headers: X-Timestamp, X-Signature
# Or: Authorization: HMAC-SHA256 ts=<epoch>,sig=<hex>
# socat EXEC may start with a minimal PATH — pin a sane one.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
if command -v openssl >/dev/null 2>&1; then
    OPENSSL_BIN=$(command -v openssl)
else
    OPENSSL_BIN="/usr/bin/openssl"
fi
STATE_DIR="${INSTANCE_STATE_DIR:-/var/run/microwarp}"
# Secret from file (not process argv); empty file => disabled/unauth
if [ -f "${STATE_DIR}/admin_http.secret" ]; then
    SECRET=$(tr -d '\r\n' < "${STATE_DIR}/admin_http.secret")
else
    SECRET="${ADMIN_HTTP_TOKEN:-}"
fi
SKEW="${ADMIN_HTTP_HMAC_SKEW_SECONDS:-120}"
REQ_FILE="${STATE_DIR}/admin.rotate.req"
RES_FILE="${STATE_DIR}/admin.rotate.res"
STATUS_FILE="${STATE_DIR}/admin.status.req"
STATUS_RES="${STATE_DIR}/admin.status.res"

hmac_hex() {
    printf '%s' "$2" | "$OPENSSL_BIN" dgst -sha256 -hmac "$1" 2>/dev/null | awk '{print $NF}' | tr 'A-F' 'a-f'
}

verify_hmac_ts() {
    METHOD="$1"
    RPATH="$2"
    TS="$3"
    SIG="$4"
    case "$TS" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$SIG" in
        '') return 1 ;;
    esac
    [ -n "$SECRET" ] || return 1
    case "$SKEW" in
        ''|*[!0-9]*) SKEW=120 ;;
    esac
    NOW=$(date +%s)
    DELTA=$((NOW - TS))
    if [ "$DELTA" -lt 0 ]; then
        DELTA=$((0 - DELTA))
    fi
    if [ "$DELTA" -gt "$SKEW" ]; then
        return 1
    fi
    # Keep payload formula inlined: helper process has no entrypoint functions.
    PAYLOAD=$(printf '%s\n%s\n%s' "$METHOD" "$RPATH" "$TS")
    EXPECT=$(hmac_hex "$SECRET" "$PAYLOAD")
    [ -n "$EXPECT" ] || return 1
    SIG=$(printf '%s' "$SIG" | tr 'A-F' 'a-f' | tr -d ' \t\r\n')
    [ "$SIG" = "$EXPECT" ]
}

read_request() {
    LINE=""
    IFS= read -r LINE || return 1
    LINE=$(printf '%s' "$LINE" | tr -d '\r')
    METHOD=$(printf '%s' "$LINE" | cut -d' ' -f1)
    PATHQ=$(printf '%s' "$LINE" | cut -d' ' -f2)
    # IMPORTANT: never name this PATH — that clobbers $PATH and breaks awk/openssl lookups.
    REQ_PATH=$(printf '%s' "$PATHQ" | cut -d'?' -f1)
    TS=""
    SIG=""
    while IFS= read -r H; do
        H=$(printf '%s' "$H" | tr -d '\r')
        [ -z "$H" ] && break
        case "$H" in
            [Xx]-[Tt]imestamp:*)
                TS=$(printf '%s' "$H" | cut -d: -f2- | tr -d ' \t')
                ;;
            [Xx]-[Ss]ignature:*)
                SIG=$(printf '%s' "$H" | cut -d: -f2- | tr -d ' \t')
                ;;
            [Aa]uthorization:*[Hh][Mm][Aa][Cc]*)
                AUTH=$(printf '%s' "$H" | cut -d: -f2- | sed 's/^ *//')
                case "$AUTH" in
                    [Hh][Mm][Aa][Cc]*)
                        TS=$(printf '%s' "$AUTH" | sed -n 's/.*[Tt][Ss]=\([^, ]*\).*/\1/p')
                        SIG=$(printf '%s' "$AUTH" | sed -n 's/.*[Ss][Ii][Gg]=\([^, ]*\).*/\1/p')
                        ;;
                esac
                ;;
        esac
    done
    case "$PATHQ" in
        *ts=*)
            if [ -z "$TS" ]; then
                TS=$(printf '%s' "$PATHQ" | sed -n 's/.*[?&]ts=\([^&]*\).*/\1/p')
            fi
            ;;
    esac
    case "$PATHQ" in
        *sig=*)
            if [ -z "$SIG" ]; then
                SIG=$(printf '%s' "$PATHQ" | sed -n 's/.*[?&]sig=\([^&]*\).*/\1/p')
            fi
            ;;
    esac
}

respond() {
    CODE="$1"
    BODY="$2"
    # Portable length: prefer ${#var}; fall back to wc digits only.
    LEN=${#BODY}
    case "$LEN" in
        ''|*[!0-9]*)
            LEN=$(printf '%s' "$BODY" | wc -c 2>/dev/null | tr -cd '0-9')
            ;;
    esac
    case "$LEN" in
        ''|*[!0-9]*) LEN=0 ;;
    esac
    printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
        "$CODE" "$LEN" "$BODY"
}

read_request || { respond '400 Bad Request' '{"ok":false,"error":"bad_request"}'; exit 0; }

if [ -z "$SECRET" ]; then
    respond '401 Unauthorized' '{"ok":false,"error":"unauthorized"}'
    exit 0
fi
if [ ! -x "$OPENSSL_BIN" ] && ! command -v openssl >/dev/null 2>&1; then
    respond '500 Internal Server Error' '{"ok":false,"error":"openssl_missing"}'
    exit 0
fi
if [ ! -x "$OPENSSL_BIN" ]; then
    OPENSSL_BIN=$(command -v openssl)
fi
if ! verify_hmac_ts "$METHOD" "$REQ_PATH" "$TS" "$SIG"; then
    respond '401 Unauthorized' '{"ok":false,"error":"invalid_signature_or_timestamp"}'
    exit 0
fi

case "$METHOD $REQ_PATH" in
    "GET /status"|"GET /status/")
        rm -f "$STATUS_RES"
        : > "$STATUS_FILE"
        I=0
        while [ "$I" -lt 50 ]; do
            if [ -s "$STATUS_RES" ]; then
                BODY=$(cat "$STATUS_RES")
                respond '200 OK' "$BODY"
                rm -f "$STATUS_FILE" "$STATUS_RES"
                exit 0
            fi
            sleep 0.1
            I=$((I + 1))
        done
        respond '504 Gateway Timeout' '{"ok":false,"error":"status_timeout"}'
        rm -f "$STATUS_FILE"
        ;;
    "POST /rotate"|"POST /rotate/")
        rm -f "$RES_FILE" "${RES_FILE}.tmp."*
        : > "$REQ_FILE"
        I=0
        while [ "$I" -lt 200 ]; do
            if [ -s "$RES_FILE" ]; then
                RESP=$(tr -d '\r\n' < "$RES_FILE")
                case "$RESP" in
                    OK\ to=*|ERR\ in_progress|ERR\ no_candidate|ERR\ rotate_failed)
                        rm -f "$REQ_FILE" "$RES_FILE"
                        case "$RESP" in
                            OK\ to=*)
                                TO=$(printf '%s' "$RESP" | sed 's/^OK to=//')
                                respond '200 OK' "$(printf '{"ok":true,"primary":%s}' "$TO")"
                                ;;
                            ERR\ in_progress)
                                respond '409 Conflict' '{"ok":false,"error":"in_progress"}'
                                ;;
                            ERR\ no_candidate)
                                respond '409 Conflict' '{"ok":false,"error":"no_candidate"}'
                                ;;
                            *)
                                respond '500 Internal Server Error' '{"ok":false,"error":"rotate_failed"}'
                                ;;
                        esac
                        exit 0
                        ;;
                    *)
                        # Incomplete/garbage write — keep waiting briefly.
                        ;;
                esac
            fi
            sleep 0.1
            I=$((I + 1))
        done
        respond '504 Gateway Timeout' '{"ok":false,"error":"rotate_timeout"}'
        rm -f "$REQ_FILE"
        ;;
    *)
        respond '404 Not Found' '{"ok":false,"error":"not_found"}'
        ;;
esac
HELPER_EOF
    chmod +x "$HELPER"
    # Secret file: avoid putting token on socat argv /proc cmdline.
    printf '%s' "${ADMIN_HTTP_TOKEN}" > "${INSTANCE_STATE_DIR}/admin_http.secret"
    chmod 600 "${INSTANCE_STATE_DIR}/admin_http.secret" 2>/dev/null || true
    export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
    export INSTANCE_STATE_DIR ADMIN_HTTP_HMAC_SKEW_SECONDS
    # Do not export ADMIN_HTTP_TOKEN into every child if avoidable; helper reads secret file.
    admin_cmd_worker &
    printf '%s\n' "$!" > "${INSTANCE_STATE_DIR}/admin_cmd.worker.pid"
    # Fixed bind: 0.0.0.0:9180 — host does -p 9180:9180
    while true; do
        socat -T30 TCP-LISTEN:9180,bind=0.0.0.0,reuseaddr,fork \
            SYSTEM:"PATH='$PATH'; export PATH; INSTANCE_STATE_DIR='$INSTANCE_STATE_DIR'; export INSTANCE_STATE_DIR; ADMIN_HTTP_HMAC_SKEW_SECONDS='${ADMIN_HTTP_HMAC_SKEW_SECONDS:-120}'; export ADMIN_HTTP_HMAC_SKEW_SECONDS; exec '$HELPER'" \
            2>/dev/null || \
        socat -T30 TCP-LISTEN:9180,bind=0.0.0.0,reuseaddr \
            SYSTEM:"PATH='$PATH'; export PATH; INSTANCE_STATE_DIR='$INSTANCE_STATE_DIR'; export INSTANCE_STATE_DIR; ADMIN_HTTP_HMAC_SKEW_SECONDS='${ADMIN_HTTP_HMAC_SKEW_SECONDS:-120}'; export ADMIN_HTTP_HMAC_SKEW_SECONDS; exec '$HELPER'" \
            2>/dev/null || \
            sleep 1
    done
}

start_admin_http_server() {
    local PID SKEW
    if [ -z "${ADMIN_HTTP_TOKEN:-}" ]; then
        echo "==> admin HTTP 禁用（ADMIN_HTTP_TOKEN/HMAC secret 为空；固定监听本应是 0.0.0.0:9180）"
        return 0
    fi
    if ! command -v socat >/dev/null 2>&1; then
        echo "==> [WARN] 无 socat，无法启动 admin HTTP"
        return 0
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        echo "==> [WARN] 无 openssl，无法做 HMAC 鉴权，admin HTTP 不启动"
        return 0
    fi
    stop_admin_http_server || true
    SKEW=$(get_admin_hmac_skew_seconds)
    echo "==> 启动 admin HTTP: 0.0.0.0:9180 (HMAC-SHA256+时间戳，容差±${SKEW}s；宿主机映射此端口)"
    mkdir -p "$INSTANCE_STATE_DIR"
    admin_http_loop &
    PID=$!
    printf '%s\n' "$PID" > "$(get_admin_http_pid_file)"
    echo "==> admin HTTP PID ${PID}"
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
    local INST_ID="$1"
    local NS_NAME HOST_VETH WG_NAME
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    HOST_VETH=$(get_instance_host_veth "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")

    stop_instance_socks "$INST_ID"

    ip netns exec "$NS_NAME" wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    ip link delete "$HOST_VETH" >/dev/null 2>&1 || true
    ip netns delete "$NS_NAME" >/dev/null 2>&1 || true
}

setup_instance_netns() {
    local INST_ID="$1"
    local NS_NAME HOST_VETH NS_VETH HOST_IP NS_IP
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    HOST_VETH=$(get_instance_host_veth "$INST_ID")
    NS_VETH=$(get_instance_ns_veth "$INST_ID")
    HOST_IP=$(get_instance_host_ip "$INST_ID")
    NS_IP=$(get_instance_ns_ip "$INST_ID")

    destroy_instance_netns "$INST_ID"

    echo "==> [inst${INST_ID}] 创建 netns ${NS_NAME} 与 veth 对"
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
    local INST_ID="$1"
    local CONF_PATH WG_NAME WG_LINK_CONF RUNTIME_CONF RAW_ENDPOINT RESOLVED_IP NEW_ENDPOINT
    CONF_PATH=$(get_instance_conf_path "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")
    WG_LINK_CONF="/etc/wireguard/${WG_NAME}.conf"
    RUNTIME_CONF="/etc/wireguard/${WG_NAME}.runtime.conf"

    mkdir -p /etc/wireguard

    if [ ! -f "$CONF_PATH" ]; then
        echo "==> [inst${INST_ID}] [ERROR] 缺少配置文件: ${CONF_PATH}"
        return 1
    fi

    # Start from the persisted conf (keeps keys/addresses intact).
    cp "$CONF_PATH" "$RUNTIME_CONF"

    RAW_ENDPOINT=$(awk -F ' = ' '/^[[:space:]]*Endpoint[[:space:]]*=/ {print $2; exit}' "$RUNTIME_CONF" | tr -d '\r')
    if [ -n "$RAW_ENDPOINT" ] && parse_endpoint_host_port "$RAW_ENDPOINT"; then
        if RESOLVED_IP=$(resolve_host_to_ip "$ENDPOINT_HOST"); then
            NEW_ENDPOINT=$(format_endpoint_ip_port "$RESOLVED_IP" "$ENDPOINT_PORT")
            if [ "$NEW_ENDPOINT" != "$RAW_ENDPOINT" ]; then
                echo "==> [inst${INST_ID}] Endpoint 预解析: ${RAW_ENDPOINT} -> ${NEW_ENDPOINT}"
            fi
            # Replace only the Endpoint line; keep the on-disk identity conf unchanged.
            sed -i "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = ${NEW_ENDPOINT}|" "$RUNTIME_CONF"
        else
            echo "==> [inst${INST_ID}] [WARN] 无法在默认 netns 解析 Endpoint 主机名: ${ENDPOINT_HOST}（仍尝试原值）"
        fi
    fi

    # wg-quick uses the conf basename as the interface name.
    ln -sfn "$RUNTIME_CONF" "$WG_LINK_CONF"
    return 0
}

start_instance_warp() {
    local INST_ID="$1"
    local NS_NAME WG_NAME HOST_IP NS_VETH WG_LOG UP_OK RAW_ENDPOINT
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

    echo "==> [inst${INST_ID}] 正在 netns 内启动 WireGuard (${WG_NAME})..."
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
        echo "==> [inst${INST_ID}] [WARN] WireGuard 启动失败"
        if [ -s "$WG_LOG" ]; then
            echo "==> [inst${INST_ID}] wg-quick 输出:"
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
    echo "==> [inst${INST_ID}] 隧道已启动"
    return 0
}

stop_instance_socks() {
    local INST_ID="$1"
    local PID_FILE PID
    PID_FILE=$(get_instance_pid_file "$INST_ID")

    if [ -f "$PID_FILE" ]; then
        PID=$(tr -d '\n' < "$PID_FILE")
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "==> [inst${INST_ID}] 停止内部 SOCKS (PID: ${PID})"
            kill "$PID" 2>/dev/null || true
            wait "$PID" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

start_instance_socks() {
    local INST_ID="$1"
    local NS_NAME NS_IP PID_FILE PID
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    NS_IP=$(get_instance_ns_ip "$INST_ID")
    PID_FILE=$(get_instance_pid_file "$INST_ID")

    if [ -f "$PID_FILE" ]; then
        PID=$(tr -d '\n' < "$PID_FILE")
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            return 0
        fi
    fi

    echo "==> [inst${INST_ID}] 启动内部 MicroSOCKS (${NS_IP}:1080)"
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        ip netns exec "$NS_NAME" microsocks -i "$NS_IP" -p 1080 -u "$SOCKS_USER" -P "$SOCKS_PASS" > /dev/null 2>&1 &
    else
        ip netns exec "$NS_NAME" microsocks -i "$NS_IP" -p 1080 > /dev/null 2>&1 &
    fi
    echo $! > "$PID_FILE"
}

ns_ensure_trace_ip() {
    local INST_ID="$1"
    # Delegates to ensure_trace_ip with inst id (streak + multi-source).
    ensure_trace_ip "$INST_ID"
}

ns_check_single_test_url() {
    local INST_ID="$1"
    local TARGET_URL="$2"
    local NS_NAME TEST_HTTP_CODE CURL_EXIT RETRYABLE_FAILURE_RETRIES ATTEMPT RETRY_REASON
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
        echo "==> [inst${INST_ID}] 测速反馈 ${TARGET_URL} HTTP 状态码: ${TEST_HTTP_CODE}"

        if is_retryable_test_url_curl_exit "$CURL_EXIT" && [ "$ATTEMPT" -le "$RETRYABLE_FAILURE_RETRIES" ]; then
            RETRY_REASON=$(get_test_url_retry_reason "$CURL_EXIT")
            echo "==> [inst${INST_ID}] ${TARGET_URL} ${RETRY_REASON}，5 秒后重试 (${ATTEMPT}/${RETRYABLE_FAILURE_RETRIES})..."
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
    local INST_ID="$1"
    local TEST_URLS_RAW TEST_URLS_LIST OLD_IFS TEST_URL
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
    local INST_ID="$1"
    local IP_RC TEST_URLS_RAW TEST_URLS_LIST
    ns_ensure_trace_ip "$INST_ID"
    IP_RC=$?

    if [ "$IP_RC" -eq 2 ]; then
        # This round: N links failed to yield any egress IP → instance WARP-dead.
        return 1
    fi

    TEST_URLS_RAW=${TEST_URLS:-https://grok.com}
    TEST_URLS_LIST=$(printf '%s' "$TEST_URLS_RAW" | tr ',;' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d')

    if [ -n "$TEST_URLS_LIST" ]; then
        ns_check_test_urls "$INST_ID"
        return $?
    fi

    [ "$IP_RC" -eq 0 ]
}

restart_instance_wg() {
    local INST_ID="$1"
    local NS_NAME WG_NAME
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")

    echo "==> [inst${INST_ID}] 正在断开并重连 WireGuard..."
    ip netns exec "$NS_NAME" wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    start_instance_warp "$INST_ID"
}

try_instance_wg_reconnect_recovery() {
    local INST_ID="$1"
    local RECONNECT_RETRIES ATTEMPT
    RECONNECT_RETRIES=$(get_wg_reconnect_retries)

    if [ "$RECONNECT_RETRIES" -le 0 ]; then
        echo "==> [inst${INST_ID}] 已禁用 WG 重连重试"
        return 1
    fi

    ATTEMPT=1
    while [ "$ATTEMPT" -le "$RECONNECT_RETRIES" ]; do
        echo "==> [inst${INST_ID}] WG 重连重试 (${ATTEMPT}/${RECONNECT_RETRIES})..."
        if restart_instance_wg "$INST_ID" && run_instance_health_checks "$INST_ID"; then
            echo "==> [inst${INST_ID}] WG 重连后健康检查已恢复"
            return 0
        fi
        ATTEMPT=$((ATTEMPT + 1))
        [ "$ATTEMPT" -le "$RECONNECT_RETRIES" ] && sleep 3
    done

    echo "==> [inst${INST_ID}] [WARN] WG 重连重试全部失败"
    return 1
}

restart_instance_with_new_identity() {
    local INST_ID="$1"
    local NS_NAME WG_NAME CONF_PATH
    NS_NAME=$(get_instance_netns_name "$INST_ID")
    WG_NAME=$(get_instance_wg_name "$INST_ID")
    CONF_PATH=$(get_instance_conf_path "$INST_ID")

    ip netns exec "$NS_NAME" wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    # Serialize API registration so many background revivers don't stampede the API.
    if ! with_dir_lock "$(get_register_lock_dir)" generate_warp_config "$CONF_PATH"; then
        echo "==> [inst${INST_ID}] 重注册失败，交由配置串行重试队列继续"
        enqueue_instance_config_retry "$INST_ID"
        return 1
    fi
    print_warp_identity_summary "$CONF_PATH" "inst${INST_ID}"
    start_instance_warp "$INST_ID"
}

mark_instance_up() {
    local INST_ID="$1"
    local PRIMARY
    start_instance_socks "$INST_ID"
    set_instance_status "$INST_ID" "up"
    clear_instance_offline_since "$INST_ID"
    record_instance_online_since "$INST_ID"
    record_instance_last_healthy "$INST_ID"
    PRIMARY=$(get_primary_id)
    if [ -z "$PRIMARY" ]; then
        # First healthy instance claims primary.
        set_primary_id "$INST_ID"
        haproxy_set_server_state "$INST_ID" "ready" || true
        echo "==> [inst${INST_ID}] ✅ 已标记健康并抢到 primary（HAProxy ready）"
    elif [ "$INST_ID" = "$PRIMARY" ]; then
        haproxy_set_server_state "$INST_ID" "ready" || true
        echo "==> [inst${INST_ID}] ✅ primary 健康（HAProxy ready）"
    else
        # Standby hot spare: WARP+SOCKS up, no new client traffic.
        haproxy_set_server_state "$INST_ID" "drain" || true
        echo "==> [inst${INST_ID}] ✅ standby 健康（HAProxy drain 热备）"
    fi
}

# Runtime drain only — no config rewrite, no reload.
# New connections stop; existing TCP kept until drain timeout / natural end.
detach_instance_from_lb() {
    local INST_ID="$1"

    set_instance_status "$INST_ID" "draining"
    record_instance_offline_since "$INST_ID"
    clear_instance_online_since "$INST_ID"
    echo "==> [inst${INST_ID}] ⏸️ HAProxy state=drain（官方 drain，无 reload）：停新连接，保已有 TCP"
    if ! haproxy_set_server_state "$INST_ID" "drain"; then
        # Socket unavailable (startup race): fall back to one reload so checks still work;
        # servers stay in cfg either way.
        echo "==> [inst${INST_ID}] [WARN] runtime drain 失败，尝试确保 HAProxy 进程/配置存在"
        reload_haproxy_from_status || true
        haproxy_set_server_state "$INST_ID" "drain" || true
    fi
}

# While SOCKS/WARP is down: maint (no traffic, no checks). Still no server add/remove.
hard_detach_instance_from_lb() {
    local INST_ID="$1"

    set_instance_status "$INST_ID" "down"
    record_instance_offline_since "$INST_ID"
    clear_instance_online_since "$INST_ID"
    echo "==> [inst${INST_ID}] HAProxy state=maint（重启服务期间，无 reload）"
    haproxy_set_server_state "$INST_ID" "maint" || true
}

# Back-compat: soft-detach via runtime drain.
mark_instance_down() {
    detach_instance_from_lb "$1"
}

_reload_haproxy_from_status_unlocked() {
    local STATUS_LIST HEALTHY PID_FILE NEW_CFG
    mkdir -p "$INSTANCE_STATE_DIR"
    PID_FILE=$(get_haproxy_pid_file)
    STATUS_LIST=$(collect_instance_status_list)
    HEALTHY=$(count_healthy_instances)
    NEW_CFG="${HAPROXY_CFG}.new"

    render_haproxy_config "$LISTEN_ADDR" "$LISTEN_PORT" "$STATUS_LIST" > "$NEW_CFG"

    # Skip reload when the static server set is unchanged (normal drain/ready path).
    if [ -f "$HAPROXY_CFG" ] && cmp -s "$NEW_CFG" "$HAPROXY_CFG" 2>/dev/null; then
        rm -f "$NEW_CFG"
        if refresh_haproxy_pid; then
            echo "==> HAProxy 配置未变（健康标记 ${HEALTHY}/${WARP_INSTANCE_COUNT}），跳过 reload"
            return 0
        fi
        echo "==> HAProxy 配置未变但进程不在，冷启动..."
        if haproxy_cold_start "$HAPROXY_CFG"; then
            echo "==> 🚀 HAProxy 已上线 (监听: ${LISTEN_ADDR}:${LISTEN_PORT}, master PID: ${HAPROXY_PID})"
            # Single-active: re-apply ready/drain/maint from primary mapping.
            haproxy_reapply_instance_states
            return 0
        fi
        return 1
    fi

    mv -f "$NEW_CFG" "$HAPROXY_CFG"
    echo "==> 刷新 HAProxy 静态配置（server 列表/监听变化；健康实例标记: ${HEALTHY}/${WARP_INSTANCE_COUNT}）"

    if refresh_haproxy_pid; then
        if haproxy_try_soft_reload "$HAPROXY_CFG"; then
            echo "==> HAProxy soft-reload 完成（master PID: ${HAPROXY_PID}）"
            # Admin states reset on full config replace — single-active reapply.
            haproxy_reapply_instance_states
            return 0
        fi
        echo "==> [WARN] HAProxy soft-reload 失败，尝试冷启动"
        if is_live_pid "$HAPROXY_PID"; then
            kill "$HAPROXY_PID" 2>/dev/null || true
            sleep 0.2 2>/dev/null || true
            kill -9 "$HAPROXY_PID" 2>/dev/null || true
        fi
        HAPROXY_PID=""
        rm -f "$PID_FILE"
    fi

    if haproxy_cold_start "$HAPROXY_CFG"; then
        echo "==> 🚀 HAProxy 已上线 (监听: ${LISTEN_ADDR}:${LISTEN_PORT}, master PID: ${HAPROXY_PID})"
        haproxy_reapply_instance_states
        return 0
    fi

    echo "==> [ERROR] HAProxy 启动失败"
    HAPROXY_PID=""
    return 1
}

reload_haproxy_from_status() {
    with_dir_lock "$(get_haproxy_lock_dir)" _reload_haproxy_from_status_unlocked
}

# Background self-revival loop for ONE instance. Can run forever without blocking others.
# On success: mark up + reload HAProxy, then exit. On failure: keep retrying with backoff.
# If offline continuously for CONFIG_STALE_OFFLINE_SECONDS (default 2h), skip reconnect and
# force a new WARP registration — existing conf is treated as stale/invalid.
# If conf is missing / register fails, hand off to the serial config-retry queue and exit
# so we do not double-stampede the API alongside the queue worker.
instance_recovery_worker() {
    # IMPORTANT: use local INST_ID. Nested helpers (reload_haproxy, status loops)
    # also assign INST_ID; without local, a recovery for inst12 becomes inst20.
    local INST_ID="$1"
    # reason is logged only. Single-active branch NEVER keeps the old WG tunnel via
    # "SOCKS-only shortcut" — every recovery must WG reconnect (or re-register).
    local REASON="${2:-}"
    local PID_FILE BACKOFF MAX_BACKOFF FORCE_NEW SINCE NOW_EPOCH ELAPSED CONF_PATH
    PID_FILE=$(get_instance_recover_pid_file "$INST_ID")
    # Parent (request_instance_recovery) records the real job PID via $!.
    # Do NOT write $$ here: in BusyBox ash a backgrounded function often keeps
    # the main shell's $$ (container PID 1), which corrupts recovery tracking.
    # shellcheck disable=SC2064
    trap 'rm -f "$PID_FILE"' EXIT INT TERM

    BACKOFF=5
    MAX_BACKOFF=60
    if [ -n "$REASON" ]; then
        echo "==> [inst${INST_ID}] 后台复活 worker 启动 (reason=${REASON}；强制 WG 重连/重注册，不保留旧隧道)"
        print_health_summary
    else
        echo "==> [inst${INST_ID}] 后台复活 worker 启动 (强制 WG 重连/重注册，不保留旧隧道)"
        print_health_summary
    fi

    # Parent already kicked this backend out of HAProxy. Finish offline gracefully:
    # wait until not busy (or drain timeout), then stop internal SOCKS before we
    # touch the tunnel / re-register.
    drain_and_stop_instance_socks "$INST_ID"
    echo "==> [inst${INST_ID}] 复活进度: 排空结束，SOCKS 已停 → 开始 WG 重连/重注册"

    while true; do
        CONF_PATH=$(get_instance_conf_path "$INST_ID")
        if [ ! -f "$CONF_PATH" ]; then
            echo "==> [inst${INST_ID}] 无配置文件，交给配置串行重试队列（本 worker 退出）"
            enqueue_instance_config_retry "$INST_ID"
            rm -f "$PID_FILE"
            trap - EXIT INT TERM
            exit 0
        fi

        if is_instance_queued_for_config_retry "$INST_ID"; then
            echo "==> [inst${INST_ID}] 已在配置重试队列，本 worker 让出"
            rm -f "$PID_FILE"
            trap - EXIT INT TERM
            exit 0
        fi

        # No SOCKS-only shortcut: old WG tunnel is never "kept as-is".
        # Always proceed to WG reconnect / re-register below.

        FORCE_NEW=0
        if instance_should_force_new_config "$INST_ID"; then
            FORCE_NEW=1
            SINCE=$(get_instance_offline_since_epoch "$INST_ID")
            NOW_EPOCH=$(date +%s)
            ELAPSED=$((NOW_EPOCH - SINCE))
            echo "==> [inst${INST_ID}] 已连续离线 ${ELAPSED}s ≥ $(get_config_stale_offline_seconds)s，判定配置失效，跳过重连并强制换新配置"
        fi

        if [ "$FORCE_NEW" -eq 0 ]; then
            echo "==> [inst${INST_ID}] 复活进度: WG 重连中..."
            if try_instance_wg_reconnect_recovery "$INST_ID"; then
                mark_instance_up "$INST_ID"
                reload_haproxy_from_status
                echo "==> [inst${INST_ID}] 🎉 WG 重连后后台复活成功"
                print_health_summary
                rm -f "$PID_FILE"
                trap - EXIT INT TERM
                exit 0
            fi
            echo "==> [inst${INST_ID}] 复活进度: 重连失败 → 重注册 WARP 身份..."
        fi

        if ! restart_instance_with_new_identity "$INST_ID"; then
            # restart_instance_with_new_identity already enqueued config retry on register fail.
            echo "==> [inst${INST_ID}] 重注册未完成，已交配置队列；本 worker 退出避免双通道重试"
            rm -f "$PID_FILE"
            trap - EXIT INT TERM
            exit 0
        fi

        if run_instance_health_checks "$INST_ID"; then
            mark_instance_up "$INST_ID"
            reload_haproxy_from_status
            echo "==> [inst${INST_ID}] 🎉 重注册后后台复活成功"
                print_health_summary
            rm -f "$PID_FILE"
            trap - EXIT INT TERM
            exit 0
        fi

        # Stay detached; SOCKS already stopped at worker start. Do NOT drain again
        # (would only delay this worker's next retry; LB kick is already done).
        set_instance_status "$INST_ID" "down"
        stop_instance_socks "$INST_ID"
        echo "==> [inst${INST_ID}] 后台复活本轮失败，${BACKOFF}s 后继续（永不放弃）"
        sleep "$BACKOFF"
        BACKOFF=$((BACKOFF * 2))
        if [ "$BACKOFF" -gt "$MAX_BACKOFF" ]; then
            BACKOFF=$MAX_BACKOFF
        fi
    done
}

# Kick off background revival if not already running.
# Synchronous work is intentionally minimal (status + soft-reload only).
# Drain / stop SOCKS / reconnect / re-register all run inside the background worker
# so the multi-instance monitor and other instances are never blocked by long offline.
# $2 optional reason (e.g. max_conn) — passed through to the worker.
request_instance_recovery() {
    local INST_ID="$1"
    local REASON="${2:-}"
    local _rec_pid _pid_file
    mkdir -p "$INSTANCE_STATE_DIR"

    if [ ! -f "$(get_instance_conf_path "$INST_ID")" ] || is_instance_queued_for_config_retry "$INST_ID"; then
        # Still detach from LB if we had been up with a missing conf edge case.
        detach_instance_from_lb "$INST_ID" || true
        # Best-effort: stop SOCKS in background so we don't block the caller on drain.
        ( drain_and_stop_instance_socks "$INST_ID" ) >/dev/null 2>&1 &
        enqueue_instance_config_retry "$INST_ID"
        return 0
    fi

    if is_instance_recovering "$INST_ID"; then
        echo "==> [inst${INST_ID}] 后台复活已在进行中，跳过重复拉起"
        return 0
    fi

    # 1) Kick LB immediately (fast). SOCKS kept for existing sessions until worker drains.
    detach_instance_from_lb "$INST_ID"

    _pid_file=$(get_instance_recover_pid_file "$INST_ID")
    if [ -n "$REASON" ]; then
        echo "==> [inst${INST_ID}] 拉起后台复活 worker（reason=${REASON}；排空/停 SOCKS/重连均在后台）..."
    else
        echo "==> [inst${INST_ID}] 拉起后台复活 worker（排空连接/停 SOCKS/复活均在后台）..."
    fi
    # Pass id as arg; worker locals it. Record $! from this shell — the real job pid.
    instance_recovery_worker "$INST_ID" "$REASON" &
    _rec_pid=$!
    echo "$_rec_pid" > "$_pid_file"
    echo "==> [inst${INST_ID}] 后台复活 worker 已记录 PID ${_rec_pid}"
}

# Foreground bounded attempt (startup path only). Returns quickly-ish.
ensure_instance_ready() {
    # Startup path: ONE quick health probe. Never block the serial boot loop on
    # multi-attempt WG reconnect (that made inst1→inst2 look "stuck", and any
    # INST_ID leak during long reconnect showed up as the wrong instance).
    # Failures hand off to request_instance_recovery (background, correct id).
    local _eid="$1"
    # second arg kept for API compat; ignored (background worker does full revive)

    if run_instance_health_checks "$_eid"; then
        mark_instance_up "$_eid"
        return 0
    fi

    echo "==> [inst${_eid}] 启动期连通性未通过，不阻塞后续实例；交给后台 worker 复活"
    request_instance_recovery "$_eid"
    return 1
}

stagger_next_instance_start() {
    CURRENT_ID=$1
    TOTAL_COUNT=$2

    # No delay after the last instance.
    [ "$CURRENT_ID" -lt "$TOTAL_COUNT" ] || return 0
    [ "$INSTANCE_START_STAGGER_SECONDS" -gt 0 ] 2>/dev/null || return 0

    echo "==> 启动错峰：inst${CURRENT_ID} 完成，等待 ${INSTANCE_START_STAGGER_SECONDS}s 后再启动下一个实例"
    sleep "$INSTANCE_START_STAGGER_SECONDS"
}

bootstrap_multi_instances() {
    enable_host_forwarding
    mkdir -p "$INSTANCE_STATE_DIR" /etc/wireguard/instances
    echo "==> 多实例串行启动（实例间错开 ${INSTANCE_START_STAGGER_SECONDS}s，避免并发注册/建隧）"
    echo "==> 首个实例就绪后即开放服务并开始测活；配置失败的实例进入后台串行重试队列"

    # Open frontend immediately (may have zero backends). Clients get refuse/reset
    # rather than waiting for all N instances to finish register+tunnel.
    for _bid in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        set_instance_status "$_bid" "down"
        record_instance_offline_since "$_bid"
    done
    clear_primary_id
    reload_haproxy_from_status
    start_admin_http_server

    for _bid in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
        CONF_PATH=$(get_instance_conf_path "$_bid")
        _need_register=0
        _config_ok=0

        if [ ! -f "$CONF_PATH" ]; then
            # migrate legacy single-instance conf to inst1 if present
            if [ "$_bid" = "1" ] && [ -f "$WG_CONF" ] && ! is_enabled "$ROTATE_IP_ON_START"; then
                mkdir -p "$(dirname "$CONF_PATH")"
                cp "$WG_CONF" "$CONF_PATH"
                echo "==> [inst1] 复用已有 ${WG_CONF}"
                _config_ok=1
            else
                echo "==> [inst${_bid}] 未检测到配置，自动注册..."
                _need_register=1
            fi
        elif is_enabled "$ROTATE_IP_ON_START"; then
            echo "==> [inst${_bid}] ROTATE_IP_ON_START 生效，重新注册..."
            _need_register=1
        else
            echo "==> [inst${_bid}] 检测到已有配置，跳过注册"
            _config_ok=1
        fi

        if [ "$_need_register" -eq 1 ]; then
            if generate_warp_config "$CONF_PATH"; then
                _config_ok=1
            else
                echo "==> [inst${_bid}] 启动期配置获取失败（不退出容器），加入后台串行重试队列"
                enqueue_instance_config_retry "$_bid"
                reload_haproxy_from_status
                stagger_next_instance_start "$_bid" "$WARP_INSTANCE_COUNT"
                continue
            fi
        fi

        if [ "$_config_ok" -ne 1 ]; then
            enqueue_instance_config_retry "$_bid"
            reload_haproxy_from_status
            stagger_next_instance_start "$_bid" "$WARP_INSTANCE_COUNT"
            continue
        fi

        print_warp_identity_summary "$CONF_PATH" "inst${_bid}"
        setup_instance_netns "$_bid"
        start_instance_warp "$_bid" || true

        # Progressive open: health-check + join LB as soon as this inst is up —
        # do not wait for remaining instances to finish boot.
        ensure_instance_ready "$_bid" 1 || true
        reload_haproxy_from_status

        stagger_next_instance_start "$_bid" "$WARP_INSTANCE_COUNT"
    done

    HEALTHY=$(count_healthy_instances)
    if [ "$HEALTHY" -le 0 ]; then
        echo "==> [WARN] 启动期尚无健康实例；配置队列/复活 worker 继续后台工作，主流程进入守护"
        for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
            if [ ! -f "$(get_instance_conf_path "$INST_ID")" ]; then
                enqueue_instance_config_retry "$INST_ID"
            else
                request_instance_recovery "$INST_ID"
            fi
        done
        # Wait until at least one is up so first-boot clients aren't stuck forever
        # on an empty pool — but service port is already open above.
        WAIT_ROUNDS=0
        while [ "$(count_healthy_instances)" -le 0 ]; do
            WAIT_ROUNDS=$((WAIT_ROUNDS + 1))
            echo "==> 等待至少一个实例就绪... (${WAIT_ROUNDS})"
            sleep 5
            for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
                if [ "$(get_instance_status "$INST_ID")" = "up" ]; then
                    continue
                fi
                if [ ! -f "$(get_instance_conf_path "$INST_ID")" ]; then
                    enqueue_instance_config_retry "$INST_ID"
                else
                    request_instance_recovery "$INST_ID"
                fi
            done
        done
    fi

    HEALTHY=$(count_healthy_instances)
    echo "==> 多实例就绪：${HEALTHY}/${WARP_INSTANCE_COUNT} 健康，统一入口 ${LISTEN_ADDR}:${LISTEN_PORT}"
    print_health_summary
    echo "==> down 实例由配置队列/后台 worker 独立复活，不阻塞主巡检"
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
    local INST_ID="$1"
    local OLD_STATUS ELAPSED UPTIME_TEXT

    # Config retry queue owns registration for conf-less / register-failed insts.
    if is_instance_queued_for_config_retry "$INST_ID"; then
        echo "==> [inst${INST_ID}] 配置串行重试队列处理中，本轮巡检跳过"
        ensure_config_retry_worker
        return 0
    fi

    if [ ! -f "$(get_instance_conf_path "$INST_ID")" ]; then
        echo "==> [inst${INST_ID}] 无配置 → 入配置串行重试队列"
        enqueue_instance_config_retry "$INST_ID"
        return 0
    fi

    # If a recovery worker is already busy, just skip heavy work.
    if is_instance_recovering "$INST_ID"; then
        # Only count busy while draining; other phases skip ss scan.
        _st=$(get_instance_status "$INST_ID")
        if [ "$_st" = "draining" ]; then
            _busy=$(count_instance_busy_clients "$INST_ID" 2>/dev/null || printf '?')
            echo "==> [inst${INST_ID}] 后台复活进行中（排空中 busy=${_busy}），本轮巡检跳过重活"
        else
            echo "==> [inst${INST_ID}] 后台复活进行中（status=${_st}），本轮巡检跳过重活"
        fi
        return 0
    fi

    print_instance_health_probe_start "$INST_ID"
    if run_instance_health_checks "$INST_ID"; then
        OLD_STATUS=$(get_instance_status "$INST_ID")
        case "$OLD_STATUS" in
            draining)
                # Never cancel an in-progress drain with ready — recovery worker owns this inst.
                echo "==> [inst${INST_ID}] 出口仍通但状态=draining，不覆盖为 ready（等排空/复活）"
                if ! is_instance_recovering "$INST_ID"; then
                    echo "==> [inst${INST_ID}] draining 但无 worker → 补拉后台复活"
                    request_instance_recovery "$INST_ID"
                fi
                return 0
                ;;
            up)
                # Already serving: refresh last_healthy for rotate selection; do NOT mark_up.
                record_instance_last_healthy "$INST_ID"
                ELAPSED=$(get_instance_online_elapsed_seconds "$INST_ID")
                case "$ELAPSED" in
                    ''|*[!0-9]*)
                        echo "==> [inst${INST_ID}] 巡检通过，继续保持在线（已刷新 last_healthy）"
                        ;;
                    *)
                        UPTIME_TEXT=$(format_uptime_duration "$ELAPSED")
                        echo "==> [inst${INST_ID}] 巡检通过，继续保持在线（已在线: ${UPTIME_TEXT}；已刷新 last_healthy）"
                        ;;
                esac
                ;;
            *)
                # down / unknown → bring back into pool (standby drain or primary ready via mark_up)
                mark_instance_up "$INST_ID"
                reload_haproxy_from_status || true
                echo "==> [inst${INST_ID}] 已恢复并按单活规则加入池"
                ;;
        esac
        # Single-active branch: MAX_CONN auto-rotate disabled (env may remain; must not rotate).
        return 0
    fi

    echo "==> [inst${INST_ID}] ❌ 巡检失败 → runtime drain 停新连接，后台排空后复活"
    # Primary fail → failover to latest healthy standby (if any), then recover failed.
    failover_primary_on_health_fail "$INST_ID"
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
    echo "==> 多实例守护模式：巡检总间隔 ${TEST_URLS_CHECK_INTERVAL}s / ${WARP_INSTANCE_COUNT} 实例 → 错峰 ${HEALTH_STAGGER}s"
    echo "==> 主循环只做轻量探活；失败实例在后台独立重连/重注册直到复活"

    while true; do
        for INST_ID in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
            probe_instance_and_schedule_recovery "$INST_ID"

            # Fleet one-liner after each probe (健康 N/M + 复活/排空/busy)
            print_health_summary
            # Per recovering inst: only ss-count busy while draining
            for X in $(get_instance_ids "$WARP_INSTANCE_COUNT"); do
                if is_instance_recovering "$X"; then
                    _st=$(get_instance_status "$X")
                    case "$_st" in
                        draining)
                            _busy=$(count_instance_busy_clients "$X" 2>/dev/null || printf '?')
                            echo "==> [inst${X}] 复活进度: 排空中 status=draining busy=${_busy}"
                            ;;
                        down)
                            echo "==> [inst${X}] 复活进度: 重连/重注册中 status=down"
                            ;;
                        *)
                            echo "==> [inst${X}] 复活进度: 进行中 status=${_st}"
                            ;;
                    esac
                fi
            done

            echo "==> 健康巡检错峰：等待 ${HEALTH_STAGGER}s 后检查下一个实例"
            sleep "$HEALTH_STAGGER" & wait $!
        done
    done
}

multi_cleanup_on_exit() {
    echo "==> 收到退出信号，正在清理多实例资源..."

    stop_admin_http_server || true
    stop_all_instance_recoveries
    release_rotate_lock || true
    # Admin IPC leftovers (req/res/handler) so next boot starts clean
    rm -f \
        "${INSTANCE_STATE_DIR}/admin.rotate.req" \
        "${INSTANCE_STATE_DIR}/admin.rotate.res" \
        "${INSTANCE_STATE_DIR}/admin.status.req" \
        "${INSTANCE_STATE_DIR}/admin.status.res" \
        "${INSTANCE_STATE_DIR}/admin_http_handler.sh" \
        "${INSTANCE_STATE_DIR}/admin_http.secret" \
        "${INSTANCE_STATE_DIR}/admin_cmd.worker.pid" \
        "$(get_admin_http_pid_file)" 2>/dev/null || true

    refresh_haproxy_pid || true
    if is_live_pid "$HAPROXY_PID"; then
        kill "$HAPROXY_PID" 2>/dev/null || true
        wait "$HAPROXY_PID" 2>/dev/null || true
    fi
    HAPROXY_PID=""
    rm -f "$(get_haproxy_pid_file)" 2>/dev/null || true

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
echo "==> WARP 实例数: ${WARP_INSTANCE_COUNT} (WARP_INSTANCES=${WARP_INSTANCES:-2}；单活分支下限 2)"

if [ "$WARP_STACK_MODE" = "ipv6-preferred" ]; then
    echo "precedence ::ffff:0:0/96  10" > /etc/gai.conf
    echo "==> 已启用 IPv6 优先地址选择策略"
fi

prepare_wg_quick_compat

if [ "$WARP_INSTANCE_COUNT" -le 1 ]; then
    # 单实例：保持原有路径与 volume 兼容
    if [ ! -f "$WG_CONF" ]; then
        echo "==> 未检测到配置，正在全自动初始化 Cloudflare WARP..."
        if ! generate_warp_config; then
            echo "==> [FATAL] 单实例首次注册连续失败，无法启动"
            exit 1
        fi
    elif is_enabled "$ROTATE_IP_ON_START"; then
        echo "==> 检测到 ROTATE_IP_ON_START=${ROTATE_IP_ON_START}，正在重新注册 WARP 设备以刷新出口 IP..."
        if ! generate_warp_config; then
            echo "==> [FATAL] ROTATE_IP_ON_START 注册失败，无法启动"
            exit 1
        fi
    else
        echo "==> 检测到已有持久化配置，跳过注册。"
    fi

    print_warp_identity_summary
    trap cleanup_on_exit INT TERM
    start_warp_interface
    ensure_network_ready
    periodic_test_url_monitor
else
    # 多实例：单容器内多条 WARP 隧道 + 统一 SOCKS 入口 + 健康 LB
    echo "==> 多实例模式：容器内并行 ${WARP_INSTANCE_COUNT} 条 WARP，仅暴露 ${LISTEN_ADDR}:${LISTEN_PORT}"
    echo "==> 提示：多实例需要 netns，建议 cap_add: [NET_ADMIN, SYS_ADMIN, SYS_MODULE]"
    trap multi_cleanup_on_exit INT TERM
    bootstrap_multi_instances
    multi_periodic_monitor
fi
