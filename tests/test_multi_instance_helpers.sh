#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

mkdir() {
    return 0
}

source <(python3 - <<'PY'
from pathlib import Path
text = Path('entrypoint.sh').read_text()
# Prefer the multi-instance entrypoint marker; fall back to the legacy single-instance marker.
for marker in (
    "# ==========================================\n# 1. 初始化\n# ==========================================\n",
    "# ==========================================\n# 1. 账号全自动申请与配置生成\n# ==========================================\n",
):
    if marker in text:
        print(text.split(marker)[0], end='')
        break
else:
    raise SystemExit('entrypoint marker not found')
PY
)

assert_eq() {
    local actual=$1
    local expected=$2
    local message=$3

    if [[ "$actual" != "$expected" ]]; then
        printf 'assert_eq failed: %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local message=$3

    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'assert_contains failed: %s\nmissing: %s\nactual:\n%s\n' "$message" "$needle" "$haystack" >&2
        exit 1
    fi
}

test_default_instance_count_is_one() {
    WARP_INSTANCES=''
    assert_eq "$(get_warp_instance_count)" '1' 'blank WARP_INSTANCES should default to 1'
}

test_explicit_instance_count() {
    WARP_INSTANCES='3'
    assert_eq "$(get_warp_instance_count)" '3' 'explicit positive count should be honored'
}

test_invalid_instance_count_falls_back() {
    WARP_INSTANCES='abc'
    assert_eq "$(get_warp_instance_count)" '1' 'non-numeric should fall back to 1'

    WARP_INSTANCES='0'
    assert_eq "$(get_warp_instance_count)" '1' 'zero should fall back to 1'

    WARP_INSTANCES='-2'
    assert_eq "$(get_warp_instance_count)" '1' 'negative should fall back to 1'
}

test_instance_count_is_capped() {
    WARP_INSTANCES='99'
    assert_eq "$(get_warp_instance_count)" '99' 'values within max should be honored'

    WARP_INSTANCES='100'
    assert_eq "$(get_warp_instance_count)" '100' 'max 100 should be allowed'

    WARP_INSTANCES='250'
    assert_eq "$(get_warp_instance_count)" '100' 'very large values should cap at 100'
}

test_instance_ids_list() {
    assert_eq "$(get_instance_ids 1)" '1' 'single instance id list'
    assert_eq "$(get_instance_ids 3)" '1 2 3' 'multi instance id list'
}

test_instance_paths_and_addresses() {
    assert_eq "$(get_instance_netns_name 2)" 'mw2' 'netns name'
    assert_eq "$(get_instance_conf_path 2)" '/etc/wireguard/instances/2/wg0.conf' 'conf path'
    assert_eq "$(get_instance_host_veth 2)" 'mw-h2' 'host veth'
    assert_eq "$(get_instance_ns_veth 2)" 'mw-n2' 'ns veth'
    assert_eq "$(get_instance_host_ip 2)" '10.66.2.1' 'host ip'
    assert_eq "$(get_instance_ns_ip 2)" '10.66.2.2' 'ns ip'
    assert_eq "$(get_instance_socks_endpoint 2)" '10.66.2.2:1080' 'socks endpoint'
}

test_parse_endpoint_host_port() {
    parse_endpoint_host_port 'engage.cloudflareclient.com:2408'
    assert_eq "$ENDPOINT_HOST" 'engage.cloudflareclient.com' 'hostname host'
    assert_eq "$ENDPOINT_PORT" '2408' 'hostname port'

    parse_endpoint_host_port '162.159.193.10:2408'
    assert_eq "$ENDPOINT_HOST" '162.159.193.10' 'ipv4 host'
    assert_eq "$ENDPOINT_PORT" '2408' 'ipv4 port'

    parse_endpoint_host_port '[2606:4700:4700::1111]:2408'
    assert_eq "$ENDPOINT_HOST" '2606:4700:4700::1111' 'ipv6 bracket host'
    assert_eq "$ENDPOINT_PORT" '2408' 'ipv6 bracket port'

    assert_eq "$(format_endpoint_ip_port '1.2.3.4' '2408')" '1.2.3.4:2408' 'format ipv4'
    assert_eq "$(format_endpoint_ip_port '2606:4700::1' '2408')" '[2606:4700::1]:2408' 'format ipv6'

    # IP literals should pass through resolve_host_to_ip unchanged.
    assert_eq "$(resolve_host_to_ip '162.159.193.10')" '162.159.193.10' 'ipv4 literal resolve passthrough'
}

test_haproxy_config_only_includes_healthy_servers() {
    local cfg
    # All instances stay in cfg regardless of status; runtime drain/ready toggles traffic.
    cfg=$(render_haproxy_config '0.0.0.0' '1080' '1:down 2:up 3:up 4:draining')

    assert_contains "$cfg" 'bind 0.0.0.0:1080' 'frontend bind'
    assert_contains "$cfg" 'mode tcp' 'tcp mode'
    assert_contains "$cfg" 'balance roundrobin' 'round robin'
    assert_contains "$cfg" 'stats socket' 'runtime admin socket'
    assert_contains "$cfg" 'server inst1 10.66.1.2:1080 check' 'down instance still listed'
    assert_contains "$cfg" 'server inst2 10.66.2.2:1080 check' 'healthy instance 2'
    assert_contains "$cfg" 'server inst3 10.66.3.2:1080 check' 'healthy instance 3'
    assert_contains "$cfg" 'server inst4 10.66.4.2:1080 check' 'draining instance still listed'
    if [[ "$cfg" == *' disabled'* ]]; then
        echo 'config must not use disabled keyword anymore (use runtime drain)' >&2
        exit 1
    fi
}

test_haproxy_config_with_no_healthy_backends_still_binds() {
    local cfg
    cfg=$(render_haproxy_config '127.0.0.1' '2080' '1:down 2:down')
    assert_contains "$cfg" 'bind 127.0.0.1:2080' 'frontend should still bind with zero healthy backends'
    assert_contains "$cfg" 'backend warp_pool' 'backend section remains'
}

test_stagger_skips_after_last_instance() {
    local calls=0
    sleep() {
        calls=$((calls + 1))
    }

    INSTANCE_START_STAGGER_SECONDS=1
    stagger_next_instance_start 3 3
    assert_eq "$calls" '0' 'last instance should not sleep'

    stagger_next_instance_start 2 3
    assert_eq "$calls" '1' 'non-last instance should sleep once'
}

test_health_check_stagger_is_interval_div_count() {
    TEST_URLS_CHECK_INTERVAL=900
    assert_eq "$(get_health_check_stagger_seconds 3)" '300' '900/3 should be 300'
    assert_eq "$(get_health_check_stagger_seconds 1)" '900' 'single instance keeps full interval'
    assert_eq "$(get_health_check_stagger_seconds 10)" '90' '900/10 should be 90'

    TEST_URLS_CHECK_INTERVAL=5
    assert_eq "$(get_health_check_stagger_seconds 10)" '1' 'stagger should floor to at least 1 second'

    TEST_URLS_CHECK_INTERVAL=0
    assert_eq "$(get_health_check_stagger_seconds 4)" '1' 'non-positive interval should still stagger by 1s'
}

test_config_stale_offline_threshold() {
    CONFIG_STALE_OFFLINE_SECONDS=7200
    assert_eq "$(get_config_stale_offline_seconds)" '7200' 'default stale threshold is 2 hours'

    CONFIG_STALE_OFFLINE_SECONDS=0
    assert_eq "$(get_config_stale_offline_seconds)" '0' '0 disables stale force-reregister'

    CONFIG_STALE_OFFLINE_SECONDS=abc
    assert_eq "$(get_config_stale_offline_seconds)" '7200' 'invalid value falls back to 7200'

    CONFIG_STALE_OFFLINE_SECONDS=7200
    NOW=$(date +%s)
    OLD=$((NOW - 7201))
    if ! is_offline_long_enough_for_stale_config "$OLD"; then
        echo 'expected 7201s offline to be stale at 7200 threshold' >&2
        exit 1
    fi
    RECENT=$((NOW - 100))
    if is_offline_long_enough_for_stale_config "$RECENT"; then
        echo 'expected 100s offline NOT to be stale at 7200 threshold' >&2
        exit 1
    fi

    CONFIG_STALE_OFFLINE_SECONDS=0
    if is_offline_long_enough_for_stale_config "$OLD"; then
        echo 'threshold 0 should disable stale detection' >&2
        exit 1
    fi
}


test_extract_ip_from_probe_body() {
    assert_eq "$(extract_ip_from_probe_body $'fl=x\nip=1.2.3.4\nugo=1' v4)" '1.2.3.4' 'cloudflare trace v4'
    assert_eq "$(extract_ip_from_probe_body $'ip=2a09:bac1::1' v6)" '2a09:bac1::1' 'cloudflare trace v6'
    assert_eq "$(extract_ip_from_probe_body '8.8.8.8' v4)" '8.8.8.8' 'plain v4'
    assert_eq "$(extract_ip_from_probe_body '{"ip":"9.9.9.9"}' v4)" '9.9.9.9' 'json ip field'
    if extract_ip_from_probe_body '1.2.3.4' v6 >/dev/null 2>&1; then
        echo 'v4 body must not parse as v6' >&2
        exit 1
    fi
}

test_egress_ip_defaults_interleave_vendors() {
    local v4 v6
    v4=$(get_egress_ip_v4_urls)
    v6=$(get_egress_ip_v6_urls)
    # 1.1.1.1 should appear before 1.0.0.1, and not be adjacent
    case "$v4" in
        *'1.1.1.1/cdn-cgi/trace,https://1.0.0.1'* )
            echo "CF v4 endpoints must not be adjacent: $v4" >&2
            exit 1
            ;;
    esac
    assert_contains "$v4" '1.1.1.1/cdn-cgi/trace' 'has 1.1.1.1'
    assert_contains "$v4" '1.0.0.1/cdn-cgi/trace' 'has 1.0.0.1'
    assert_contains "$v4" 'api4.ipify.org' 'has ipify between CF endpoints ideally'
    case "$v6" in
        *'2606:4700:4700::1111]/cdn-cgi/trace,https://[2606:4700:4700::1001]'* )
            echo "CF v6 endpoints must not be adjacent: $v6" >&2
            exit 1
            ;;
    esac
}

test_run_health_checks_prefers_test_urls_when_ip_soft_disabled() {
    # threshold 0 => ensure_trace_ip returns 1 soft; TEST_URLS pass => healthy
    ensure_trace_ip() { return 1; }
    check_test_urls() { return 0; }
    TEST_URLS='https://example.com'
    if ! run_health_checks; then
        echo 'expected TEST_URLS success when IP hard-fail disabled (soft rc)' >&2
        exit 1
    fi
}

test_run_health_checks_fails_when_test_urls_fail_even_if_ip_ok() {
    ensure_trace_ip() { return 0; }
    check_test_urls() { return 1; }
    TEST_URLS='https://example.com'
    if run_health_checks; then
        echo 'expected TEST_URLS failure to fail health even when IP ok' >&2
        exit 1
    fi
}

test_run_health_checks_hard_fails_when_round_gets_no_ip() {
    # rc 2 = this round's link budget exhausted with no IP => WARP down
    ensure_trace_ip() { return 2; }
    stop_socks() { :; }
    check_test_urls() { return 0; }
    TEST_URLS='https://example.com'
    if run_health_checks; then
        echo 'expected no-IP-in-round hard fail to fail health' >&2
        exit 1
    fi
}

test_probe_family_stops_after_threshold_links() {
    EGRESS_IP_FAIL_THRESHOLD=4
    EGRESS_IP_V4_URLS='https://a.example/1,https://a.example/2,https://a.example/3,https://a.example/4,https://a.example/5'
    EGRESS_IP_CURL_MAX_TIME=1
    # curl runs in $(...); use a file counter so parent can observe attempts
    CURL_LOG=/tmp/microwarp-egress-curl-$$.log
    : > "$CURL_LOG"
    curl() {
        printf '%s\n' "${@: -1}" >> "$CURL_LOG"
        return 22
    }
    PROBE_URL_ATTEMPTS=0
    if probe_egress_ip_family v4; then
        echo 'expected all links to fail' >&2
        exit 1
    fi
    assert_eq "$PROBE_URL_ATTEMPTS" '4' 'should try exactly 4 links then stop'
    assert_eq "$(wc -l < "$CURL_LOG" | tr -d " ")" '4' 'curl should be invoked 4 times'
    rm -f "$CURL_LOG"
}

test_probe_family_stops_early_on_success() {
    EGRESS_IP_FAIL_THRESHOLD=4
    EGRESS_IP_V4_URLS='https://a.example/1,https://a.example/2,https://a.example/3'
    CURL_LOG=/tmp/microwarp-egress-curl-ok-$$.log
    : > "$CURL_LOG"
    curl() {
        printf '%s\n' "${@: -1}" >> "$CURL_LOG"
        local n
        n=$(wc -l < "$CURL_LOG" | tr -d " ")
        if [ "$n" -eq 2 ]; then
            printf '9.9.9.9\n'
            return 0
        fi
        return 22
    }
    if ! probe_egress_ip_family v4; then
        echo 'expected success on 2nd link' >&2
        exit 1
    fi
    assert_eq "$PROBED_IP" '9.9.9.9' 'parsed ip'
    assert_eq "$PROBE_URL_ATTEMPTS" '2' 'stop after first success'
    assert_eq "$(wc -l < "$CURL_LOG" | tr -d " ")" '2' 'only two curls'
    rm -f "$CURL_LOG"
}

test_haproxy_config_only_includes_healthy_servers() {
    local cfg
    cfg=$(render_haproxy_config '0.0.0.0' '1080' '1:down 2:up 3:up')

    assert_contains "$cfg" 'bind 0.0.0.0:1080' 'frontend bind'
    assert_contains "$cfg" 'mode tcp' 'tcp mode'
    assert_contains "$cfg" 'balance roundrobin' 'round robin'
    assert_contains "$cfg" 'master-worker' 'master-worker mode for stable soft-reload'
    assert_contains "$cfg" 'user root' 'explicit root to silence HAProxy 3 warn'
    assert_contains "$cfg" 'chroot /' 'explicit chroot to silence HAProxy 3 warn'
    assert_contains "$cfg" 'stats socket' 'runtime admin socket for drain/ready'
    assert_contains "$cfg" 'server inst1 10.66.1.2:1080 check' 'down instance stays in cfg'
    assert_contains "$cfg" 'server inst2 10.66.2.2:1080 check' 'healthy instance 2'
    assert_contains "$cfg" 'server inst3 10.66.3.2:1080 check' 'healthy instance 3'
    if [[ "$cfg" == *' disabled'* ]]; then
        echo 'must not use config disabled; use runtime drain' >&2
        exit 1
    fi
}

test_haproxy_config_with_no_healthy_backends_still_binds() {
    local cfg
    cfg=$(render_haproxy_config '127.0.0.1' '2080' '1:down 2:down')
    assert_contains "$cfg" 'bind 127.0.0.1:2080' 'frontend should still bind with zero healthy backends'
    assert_contains "$cfg" 'backend warp_pool' 'backend section remains'
}

test_refresh_haproxy_pid_prefers_live_pidfile_over_stale_shell() {
    # Reproduces: background worker inherits HAPROXY_PID=dead, while pidfile has
    # the real live master. Old code trusted dead shell pid → cold start every revive.
    INSTANCE_STATE_DIR=/tmp/microwarp-haproxy-pid-$$
    command mkdir -p "$INSTANCE_STATE_DIR"
    mkdir() { command mkdir "$@"; }

    sleep 60 &
    LIVE_PID=$!
    printf '%s\n' "$LIVE_PID" > "$INSTANCE_STATE_DIR/haproxy.pid"

    HAPROXY_PID=999999
    refresh_haproxy_pid
    assert_eq "$HAPROXY_PID" "$LIVE_PID" 'must adopt live pidfile, not stale shell pid'

    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
    refresh_haproxy_pid || true
    assert_eq "$HAPROXY_PID" '' 'dead pidfile/shell must clear HAPROXY_PID'

    unset -f mkdir 2>/dev/null || true
    mkdir() { return 0; }
    rm -rf "$INSTANCE_STATE_DIR"
}

test_reload_uses_soft_path_when_pidfile_live() {
    # When pidfile points at a live process, reload must soft-reload — not cold-start
    # (must not log 已上线).
    INSTANCE_STATE_DIR=/tmp/microwarp-haproxy-reload-$$
    command mkdir -p "$INSTANCE_STATE_DIR"
    mkdir() { command mkdir "$@"; }
    HAPROXY_CFG="$INSTANCE_STATE_DIR/haproxy.cfg"
    LISTEN_ADDR=0.0.0.0
    LISTEN_PORT=1080
    WARP_INSTANCE_COUNT=2
    SOFT_LOG="$INSTANCE_STATE_DIR/soft.count"
    COLD_LOG="$INSTANCE_STATE_DIR/cold.count"
    OUT_LOG="$INSTANCE_STATE_DIR/reload.out"
    : > "$SOFT_LOG"
    : > "$COLD_LOG"

    sleep 60 &
    LIVE_PID=$!
    printf '%s\n' "$LIVE_PID" > "$INSTANCE_STATE_DIR/haproxy.pid"
    # Stale shell pid (the bug): non-empty but dead → old code cold-started.
    HAPROXY_PID=999999

    collect_instance_status_list() { printf '1:up 2:down\n'; }
    count_healthy_instances() { printf '1\n'; }
    render_haproxy_config() { printf 'ok\n'; }
    with_dir_lock() { shift; "$@"; }

    # Count via files: command substitution would put counters in a subshell.
    haproxy_try_soft_reload() {
        echo 1 >> "$SOFT_LOG"
        HAPROXY_PID=$LIVE_PID
        return 0
    }
    haproxy_cold_start() {
        echo 1 >> "$COLD_LOG"
        return 0
    }
    record_socks_online_started_at() { :; }

    _reload_haproxy_from_status_unlocked >"$OUT_LOG" 2>&1
    soft_calls=$(wc -l < "$SOFT_LOG" | tr -d ' ')
    cold_calls=$(wc -l < "$COLD_LOG" | tr -d ' ')
    out=$(cat "$OUT_LOG")
    assert_eq "$soft_calls" '1' 'should soft-reload once'
    assert_eq "$cold_calls" '0' 'must not cold-start when soft-reload works'
    assert_contains "$out" 'soft-reload 完成' 'log soft-reload not cold start'
    if [[ "$out" == *'已上线'* ]]; then
        echo "unexpected cold-start log: $out" >&2
        exit 1
    fi
    assert_eq "$HAPROXY_PID" "$LIVE_PID" 'master pid stays the live one'

    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
    unset -f collect_instance_status_list count_healthy_instances render_haproxy_config \
        with_dir_lock haproxy_try_soft_reload haproxy_cold_start record_socks_online_started_at mkdir 2>/dev/null || true
    mkdir() { return 0; }
    rm -rf "$INSTANCE_STATE_DIR"
}

test_stagger_skips_after_last_instance() {
    local calls=0
    sleep() {
        calls=$((calls + 1))
    }

    INSTANCE_START_STAGGER_SECONDS=1
    stagger_next_instance_start 3 3
    assert_eq "$calls" '0' 'last instance should not sleep'

    stagger_next_instance_start 2 3
    assert_eq "$calls" '1' 'non-last instance should sleep once'
}

test_health_check_stagger_is_interval_div_count() {
    TEST_URLS_CHECK_INTERVAL=900
    assert_eq "$(get_health_check_stagger_seconds 3)" '300' '900/3 should be 300'
    assert_eq "$(get_health_check_stagger_seconds 1)" '900' 'single instance keeps full interval'
    assert_eq "$(get_health_check_stagger_seconds 10)" '90' '900/10 should be 90'

    TEST_URLS_CHECK_INTERVAL=5
    assert_eq "$(get_health_check_stagger_seconds 10)" '1' 'stagger should floor to at least 1 second'

    TEST_URLS_CHECK_INTERVAL=0
    assert_eq "$(get_health_check_stagger_seconds 4)" '1' 'non-positive interval should still stagger by 1s'
}

test_config_stale_offline_threshold() {
    CONFIG_STALE_OFFLINE_SECONDS=7200
    assert_eq "$(get_config_stale_offline_seconds)" '7200' 'default stale threshold is 2 hours'

    CONFIG_STALE_OFFLINE_SECONDS=0
    assert_eq "$(get_config_stale_offline_seconds)" '0' '0 disables stale force-reregister'

    CONFIG_STALE_OFFLINE_SECONDS=abc
    assert_eq "$(get_config_stale_offline_seconds)" '7200' 'invalid value falls back to 7200'

    CONFIG_STALE_OFFLINE_SECONDS=7200
    NOW=$(date +%s)
    OLD=$((NOW - 7201))
    if ! is_offline_long_enough_for_stale_config "$OLD"; then
        echo 'expected 7201s offline to be stale at 7200 threshold' >&2
        exit 1
    fi
    RECENT=$((NOW - 100))
    if is_offline_long_enough_for_stale_config "$RECENT"; then
        echo 'expected 100s offline NOT to be stale at 7200 threshold' >&2
        exit 1
    fi

    CONFIG_STALE_OFFLINE_SECONDS=0
    if is_offline_long_enough_for_stale_config "$OLD"; then
        echo 'threshold 0 should disable stale detection' >&2
        exit 1
    fi
}


test_extract_ip_from_probe_body() {
    assert_eq "$(extract_ip_from_probe_body $'fl=x\nip=1.2.3.4\nugo=1' v4)" '1.2.3.4' 'cloudflare trace v4'
    assert_eq "$(extract_ip_from_probe_body $'ip=2a09:bac1::1' v6)" '2a09:bac1::1' 'cloudflare trace v6'
    assert_eq "$(extract_ip_from_probe_body '8.8.8.8' v4)" '8.8.8.8' 'plain v4'
    assert_eq "$(extract_ip_from_probe_body '{"ip":"9.9.9.9"}' v4)" '9.9.9.9' 'json ip field'
    if extract_ip_from_probe_body '1.2.3.4' v6 >/dev/null 2>&1; then
        echo 'v4 body must not parse as v6' >&2
        exit 1
    fi
}

test_egress_ip_defaults_interleave_vendors() {
    local v4 v6
    v4=$(get_egress_ip_v4_urls)
    v6=$(get_egress_ip_v6_urls)
    # 1.1.1.1 should appear before 1.0.0.1, and not be adjacent
    case "$v4" in
        *'1.1.1.1/cdn-cgi/trace,https://1.0.0.1'* )
            echo "CF v4 endpoints must not be adjacent: $v4" >&2
            exit 1
            ;;
    esac
    assert_contains "$v4" '1.1.1.1/cdn-cgi/trace' 'has 1.1.1.1'
    assert_contains "$v4" '1.0.0.1/cdn-cgi/trace' 'has 1.0.0.1'
    assert_contains "$v4" 'api4.ipify.org' 'has ipify between CF endpoints ideally'
    case "$v6" in
        *'2606:4700:4700::1111]/cdn-cgi/trace,https://[2606:4700:4700::1001]'* )
            echo "CF v6 endpoints must not be adjacent: $v6" >&2
            exit 1
            ;;
    esac
}

test_run_health_checks_prefers_test_urls_over_soft_ip_failure() {
    # Soft IP fail (streak below threshold) + TEST_URLS pass => healthy
    EGRESS_IP_FAIL_STREAK=0
    EGRESS_IP_FAIL_THRESHOLD=4
    ensure_trace_ip() {
        # simulate soft fail once without bumping past threshold via real note_* 
        # directly return 1 like ensure_trace_ip soft path
        return 1
    }
    check_test_urls() { return 0; }
    TEST_URLS='https://example.com'
    if ! run_health_checks; then
        echo 'expected TEST_URLS success to override soft IP failure' >&2
        exit 1
    fi
}

test_run_health_checks_fails_when_test_urls_fail_even_if_ip_ok() {
    ensure_trace_ip() { return 0; }
    check_test_urls() { return 1; }
    TEST_URLS='https://example.com'
    if run_health_checks; then
        echo 'expected TEST_URLS failure to fail health even when IP ok' >&2
        exit 1
    fi
}

test_run_health_checks_hard_fails_after_ip_streak_threshold() {
    # return code 2 from ensure_trace_ip => hard fail regardless of TEST_URLS
    ensure_trace_ip() { return 2; }
    stop_socks() { :; }
    check_test_urls() { return 0; }
    TEST_URLS='https://example.com'
    if run_health_checks; then
        echo 'expected hard IP streak failure to fail health' >&2
        exit 1
    fi
}

test_note_egress_ip_failure_hits_threshold_at_four() {
    EGRESS_IP_FAIL_STREAK=0
    EGRESS_IP_FAIL_THRESHOLD=4
    INSTANCE_STATE_DIR=/tmp/microwarp-test-state-$$
    mkdir -p "$INSTANCE_STATE_DIR" 2>/dev/null || true
    # override mkdir no-op from test harness for this path using write directly
    write_egress_ip_fail_streak() {
        INST_ID=${1:-}
        VAL=${2:-0}
        if [ -z "$INST_ID" ]; then
            EGRESS_IP_FAIL_STREAK=$VAL
        fi
    }
    read_egress_ip_fail_streak() {
        INST_ID=${1:-}
        if [ -z "$INST_ID" ]; then
            printf '%s\n' "${EGRESS_IP_FAIL_STREAK:-0}"
        else
            printf '0\n'
        fi
    }
    note_egress_ip_failure ''
    assert_eq "$EGRESS_IP_STREAK_NOW" '1' 'streak 1'
    assert_eq "$EGRESS_IP_STREAK_HARDFAIL" '0' 'not hard yet'
    note_egress_ip_failure ''
    note_egress_ip_failure ''
    note_egress_ip_failure ''
    assert_eq "$EGRESS_IP_STREAK_NOW" '4' 'streak 4'
    assert_eq "$EGRESS_IP_STREAK_HARDFAIL" '1' 'hard at 4'
    note_egress_ip_success ''
    assert_eq "$(read_egress_ip_fail_streak '')" '0' 'success resets streak'
}


test_inst_id_not_clobbered_by_status_loops() {
    # Simulate the production bug: nested status loops used INST_ID and overwrote
    # the caller's inst id (e.g. 12 -> 20). After the fix, collect/count use _iid
    # and recovery helpers local their INST_ID.
    WARP_INSTANCES=3
    WARP_INSTANCE_COUNT=3
    INSTANCE_STATE_DIR=/tmp/microwarp-instid-$$
    command mkdir -p "$INSTANCE_STATE_DIR" 2>/dev/null || true
    # real mkdir may be mocked; write status files directly
    printf 'up\n' > "$INSTANCE_STATE_DIR/inst1.status"
    printf 'down\n' > "$INSTANCE_STATE_DIR/inst2.status"
    printf 'up\n' > "$INSTANCE_STATE_DIR/inst3.status"

    # un-mock mkdir for this test if needed - get_instance_status_file only prints path
    outer_id=12
    # call collect which previously looped INST_ID=1..N
    collect_instance_status_list >/dev/null
    # If collect polluted a global INST_ID, it would be last id (3 with WARP_INSTANCES=3 / max capped)
    # Ensure our outer variable is untouched and collect works.
    assert_eq "$outer_id" '12' 'outer id must remain 12'
    LIST=$(collect_instance_status_list)
    assert_contains "$LIST" '1:up' 'inst1 up'
    assert_contains "$LIST" '2:down' 'inst2 down'
    assert_eq "$(count_healthy_instances)" '2' 'two healthy'
}

test_generate_warp_config_returns_not_exits_on_failure() {
    # Critical: multi-instance must not die when one inst fails register 3x.
    local status
    WARP_API_URL='https://127.0.0.1:9/does-not-exist'
    WARP_API_PROXY=''
    # Make fetch fail fast without real network dependency.
    fetch_warp_config() { return 1; }
    # Avoid long sleeps in the 3-attempt loop.
    sleep() { :; }
    set +e
    generate_warp_config "/tmp/microwarp-gen-fail-$$.conf" >/tmp/microwarp-gen-fail-$$.log 2>&1
    status=$?
    set -e
    unset -f fetch_warp_config sleep 2>/dev/null || true
    assert_eq "$status" '1' 'generate_warp_config must return 1 on failure'
    if ! grep -q '连续 3 次失败' /tmp/microwarp-gen-fail-$$.log; then
        cat /tmp/microwarp-gen-fail-$$.log >&2
        echo 'expected failure log' >&2
        exit 1
    fi
    rm -f /tmp/microwarp-gen-fail-$$.conf /tmp/microwarp-gen-fail-$$.log
}

test_config_retry_queue_fifo_and_dedupe() {
    INSTANCE_STATE_DIR=/tmp/microwarp-cfgq-$$
    command mkdir -p "$INSTANCE_STATE_DIR" 2>/dev/null || true
    # Use real mkdir for queue dir
    mkdir() { command mkdir "$@"; }
    # Stub worker start so enqueue does not background anything in unit test.
    ensure_config_retry_worker() { :; }
    set_instance_status() { :; }
    record_instance_offline_since() { :; }

    enqueue_instance_config_retry 3 >/dev/null
    enqueue_instance_config_retry 1 >/dev/null
    enqueue_instance_config_retry 2 >/dev/null
    # Force deterministic FIFO order via mtime (same-second enqueue is otherwise racy).
    QDIR=$(get_config_retry_queue_dir)
    touch -t 202001010001.00 "${QDIR}/3"
    touch -t 202001010002.00 "${QDIR}/1"
    touch -t 202001010003.00 "${QDIR}/2"
    # dedupe
    out=$(enqueue_instance_config_retry 3 2>&1 || true)
    assert_contains "$out" '已在配置重试队列' 'dedupe message'

    ids=$(list_config_retry_queue_ids | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    # FIFO by mtime: 3 then 1 then 2
    assert_eq "$ids" '3 1 2' 'FIFO enqueue order by mtime'
    assert_eq "$(is_instance_queued_for_config_retry 1 && echo yes || echo no)" 'yes' 'inst1 queued'
    assert_eq "$(is_instance_queued_for_config_retry 9 && echo yes || echo no)" 'no' 'inst9 not queued'

    # cleanup stubs + dir so later tests see real helpers again
    unset -f ensure_config_retry_worker set_instance_status record_instance_offline_since 2>/dev/null || true
    mkdir() { return 0; }
    rm -rf "$INSTANCE_STATE_DIR"
}

test_config_retry_paths() {
    INSTANCE_STATE_DIR=/var/run/microwarp
    assert_eq "$(get_config_retry_queue_dir)" '/var/run/microwarp/config_retry.queue' 'queue dir'
    assert_eq "$(get_config_retry_worker_pid_file)" '/var/run/microwarp/config_retry.worker.pid' 'worker pid file'
}

test_effective_warp_api_proxy_rules() {
    LISTEN_PORT=1080

    # Explicit proxy always wins.
    WARP_API_PROXY='socks5://10.0.0.1:9050'
    WARP_INSTANCE_COUNT=10
    count_healthy_instances() { printf '5\n'; }
    assert_eq "$(get_effective_warp_api_proxy)" 'socks5://10.0.0.1:9050' 'explicit WARP_API_PROXY wins'

    # No explicit proxy + single instance → direct.
    WARP_API_PROXY=''
    WARP_INSTANCE_COUNT=1
    count_healthy_instances() { printf '99\n'; }
    assert_eq "$(get_effective_warp_api_proxy)" '' 'single instance stays direct'

    # Multi + 0 healthy → direct (bootstrap).
    WARP_INSTANCE_COUNT=5
    count_healthy_instances() { printf '0\n'; }
    assert_eq "$(get_effective_warp_api_proxy)" '' '0 healthy → direct'

    # Multi + 1 healthy → still direct (need >1).
    count_healthy_instances() { printf '1\n'; }
    assert_eq "$(get_effective_warp_api_proxy)" '' '1 healthy → direct'

    # Multi + >1 healthy → local HAProxy socks5h on loopback:BIND_PORT.
    count_healthy_instances() { printf '2\n'; }
    assert_eq "$(get_effective_warp_api_proxy)" 'socks5h://127.0.0.1:1080' '2 healthy → haproxy socks'

    LISTEN_PORT=2080
    count_healthy_instances() { printf '3\n'; }
    assert_eq "$(get_effective_warp_api_proxy)" 'socks5h://127.0.0.1:2080' 'uses LISTEN_PORT'

    unset -f count_healthy_instances 2>/dev/null || true
    WARP_API_PROXY=''
    WARP_INSTANCE_COUNT=1
    LISTEN_PORT=1080
}

test_max_conn_duration_helpers() {
    local SAVED_STATE_DIR="$INSTANCE_STATE_DIR"
    local SAVED_WARP_COUNT="${WARP_INSTANCE_COUNT:-1}"
    MAX_CONN_DURATION=''
    assert_eq "$(get_max_conn_duration)" '0' 'blank MAX_CONN_DURATION defaults to 0 (disabled)'

    MAX_CONN_DURATION=0
    assert_eq "$(get_max_conn_duration)" '0' '0 disables max-conn rotation'

    MAX_CONN_DURATION=3600
    assert_eq "$(get_max_conn_duration)" '3600' 'explicit positive duration honored'

    MAX_CONN_DURATION=abc
    assert_eq "$(get_max_conn_duration)" '0' 'invalid falls back to 0'

    INSTANCE_STATE_DIR='/var/run/microwarp'
    assert_eq "$(get_instance_online_since_file 3)" '/var/run/microwarp/inst3.online_since' 'online_since path'

    # half-pool helper: healthy * 2 < total
    WARP_INSTANCE_COUNT=4
    count_healthy_instances() { printf '1\n'; }
    if ! healthy_instances_below_half; then
        echo '1/4 should be below half' >&2
        exit 1
    fi
    count_healthy_instances() { printf '2\n'; }
    if healthy_instances_below_half; then
        echo '2/4 is exactly half — must NOT be below half' >&2
        exit 1
    fi
    WARP_INSTANCE_COUNT=3
    count_healthy_instances() { printf '1\n'; }
    if ! healthy_instances_below_half; then
        echo '1/3 should be below half' >&2
        exit 1
    fi
    count_healthy_instances() { printf '2\n'; }
    if healthy_instances_below_half; then
        echo '2/3 is above half — must NOT be below half' >&2
        exit 1
    fi

    # Disabled threshold must never force rotate.
    MAX_CONN_DURATION=0
    WARP_INSTANCE_COUNT=4
    count_healthy_instances() { printf '4\n'; }
    INSTANCE_STATE_DIR=$(mktemp -d)
    printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$(get_instance_online_since_file 1)"
    is_instance_idle() { return 0; }
    if instance_should_force_rotate_for_max_conn 1; then
        echo 'MAX_CONN_DURATION=0 must not force rotate' >&2
        exit 1
    fi

    # Below threshold + idle → no rotate.
    MAX_CONN_DURATION=3600
    printf '%s\n' "$(( $(date +%s) - 10 ))" > "$(get_instance_online_since_file 1)"
    if instance_should_force_rotate_for_max_conn 1; then
        echo 'uptime below threshold must not force rotate' >&2
        exit 1
    fi

    # Over threshold + busy → still rotate (drain will wait idle or INSTANCE_DRAIN_TIMEOUT).
    printf '%s\n' "$(( $(date +%s) - 4000 ))" > "$(get_instance_online_since_file 1)"
    is_instance_idle() { return 1; }
    count_instance_busy_clients() { printf '3\n'; }
    if ! instance_should_force_rotate_for_max_conn 1; then
        echo 'busy instance over threshold must still enter drain/rotate' >&2
        exit 1
    fi

    # Over threshold + idle + healthy below half → no rotate (capacity guard).
    is_instance_idle() { return 0; }
    count_instance_busy_clients() { printf '0\n'; }
    count_healthy_instances() { printf '1\n'; }
    WARP_INSTANCE_COUNT=4
    if instance_should_force_rotate_for_max_conn 1; then
        echo 'healthy below half must not force rotate' >&2
        exit 1
    fi

    # Over threshold + idle + healthy >= half → force rotate.
    count_healthy_instances() { printf '3\n'; }
    if ! instance_should_force_rotate_for_max_conn 1; then
        echo 'idle + over threshold + healthy>=half must force rotate' >&2
        exit 1
    fi

    # Single-instance (N<=1) must never force-rotate even when idle + over threshold.
    WARP_INSTANCE_COUNT=1
    count_healthy_instances() { printf '1\n'; }
    if instance_should_force_rotate_for_max_conn 1; then
        echo 'single-instance must never force-rotate via MAX_CONN_DURATION' >&2
        exit 1
    fi

    unset -f is_instance_idle count_healthy_instances 2>/dev/null || true
    rm -rf "$INSTANCE_STATE_DIR"
    INSTANCE_STATE_DIR="$SAVED_STATE_DIR"
    WARP_INSTANCE_COUNT="$SAVED_WARP_COUNT"
    MAX_CONN_DURATION=0
}

test_instance_online_duration_probe_log() {
    local SAVED_STATE_DIR="$INSTANCE_STATE_DIR"
    local out elapsed

    INSTANCE_STATE_DIR=$(mktemp -d)

    # No stamp → generic start line, no duration.
    out=$(print_instance_health_probe_start 2 2>&1)
    assert_contains "$out" '[inst2] 执行健康巡检...' 'missing stamp still probes'
    if [[ "$out" == *'已在线'* ]]; then
        echo "unexpected duration without online_since: $out" >&2
        exit 1
    fi

    # Stamp 3661s ago → 01h 01m 01s
    printf '%s\n' "$(( $(date +%s) - 3661 ))" > "$(get_instance_online_since_file 2)"
    elapsed=$(get_instance_online_elapsed_seconds 2)
    # Allow 0-2s skew from slow CI.
    if [ "$elapsed" -lt 3661 ] || [ "$elapsed" -gt 3665 ]; then
        echo "elapsed out of expected window: $elapsed" >&2
        exit 1
    fi
    out=$(print_instance_health_probe_start 2 2>&1)
    assert_contains "$out" '[inst2] 执行健康巡检' 'probe start still logs'
    assert_contains "$out" '已在线:' 'probe start includes online duration'
    assert_contains "$out" '上线时间:' 'probe start includes online-at text'
    assert_contains "$out" '01h 01m' 'formatted duration near 1h1m'

    rm -rf "$INSTANCE_STATE_DIR"
    INSTANCE_STATE_DIR="$SAVED_STATE_DIR"
}

test_instance_drain_helpers() {
    local out calls

    INSTANCE_DRAIN_TIMEOUT=''
    assert_eq "$(get_instance_drain_timeout)" '' 'blank drain timeout = infinite (no cap)'

    INSTANCE_DRAIN_TIMEOUT=0
    assert_eq "$(get_instance_drain_timeout)" '0' '0 disables drain wait'

    INSTANCE_DRAIN_TIMEOUT=45
    assert_eq "$(get_instance_drain_timeout)" '45' 'explicit drain timeout honored'

    INSTANCE_DRAIN_TIMEOUT=abc
    assert_eq "$(get_instance_drain_timeout)" '' 'invalid drain timeout = infinite (IM-safe)'

    # timeout=0 → skip wait
    INSTANCE_DRAIN_TIMEOUT=0
    out=$(wait_instance_drain 1 2>&1) || true
    assert_contains "$out" 'INSTANCE_DRAIN_TIMEOUT=0' 'timeout 0 logs skip'

    # already idle → immediate success
    INSTANCE_DRAIN_TIMEOUT=5
    count_instance_busy_clients() { printf '0\n'; }
    out=$(wait_instance_drain 3 2>&1)
    assert_contains "$out" '已无 busy 连接' 'idle skips wait loop'
    unset -f count_instance_busy_clients 2>/dev/null || true

    # busy then idle after one sleep
    local BUSY_STATE
    BUSY_STATE=$(mktemp)
    echo 1 > "$BUSY_STATE"
    count_instance_busy_clients() {
        if [ "$(cat "$BUSY_STATE")" = 1 ]; then
            echo 0 > "$BUSY_STATE"
            printf '2\n'
        else
            printf '0\n'
        fi
    }
    sleep() { :; }
    out=$(wait_instance_drain 4 2>&1)
    assert_contains "$out" '连接已排空' 'drains after busy clears'
    unset -f count_instance_busy_clients sleep 2>/dev/null || true
    rm -f "$BUSY_STATE"

    # unset timeout = infinite: busy then idle still drains (no force timeout path)
    INSTANCE_DRAIN_TIMEOUT=
    BUSY_STATE=$(mktemp)
    echo 1 > "$BUSY_STATE"
    count_instance_busy_clients() {
        if [ "$(cat "$BUSY_STATE")" = 1 ]; then
            echo 0 > "$BUSY_STATE"
            printf '1\n'
        else
            printf '0\n'
        fi
    }
    sleep() { :; }
    out=$(wait_instance_drain 9 2>&1)
    assert_contains "$out" '无限期等待' 'unset timeout logs infinite wait'
    assert_contains "$out" '连接已排空' 'infinite mode still ends when idle'
    if [[ "$out" == *排空超时* ]]; then
        echo "unset INSTANCE_DRAIN_TIMEOUT must not force-timeout: $out" >&2
        exit 1
    fi
    unset -f count_instance_busy_clients sleep 2>/dev/null || true
    rm -f "$BUSY_STATE"

    # busy until timeout → force path (sleep mocked; SLEPT-based timeout must still fire)
    INSTANCE_DRAIN_TIMEOUT=2
    count_instance_busy_clients() { printf '3\n'; }
    sleep() { :; }
    out=$(wait_instance_drain 5 2>&1) || true
    assert_contains "$out" '排空超时' 'timeout forces stop path'
    unset -f count_instance_busy_clients sleep 2>/dev/null || true

    # mark_instance_down / detach: runtime drain only — must NOT wait/stop (non-blocking).
    local SAVED_STATE_DIR="$INSTANCE_STATE_DIR"
    INSTANCE_STATE_DIR=$(mktemp -d)
    ORDER_LOG="$INSTANCE_STATE_DIR/order.log"
    : > "$ORDER_LOG"
    set_instance_status() { echo "status:$2" >> "$ORDER_LOG"; }
    record_instance_offline_since() { echo "offline" >> "$ORDER_LOG"; }
    clear_instance_online_since() { echo "clear_online" >> "$ORDER_LOG"; }
    reload_haproxy_from_status() { echo "reload" >> "$ORDER_LOG"; }
    haproxy_set_server_state() { echo "state:$2" >> "$ORDER_LOG"; return 0; }
    wait_instance_drain() { echo "drain_wait" >> "$ORDER_LOG"; return 0; }
    stop_instance_socks() { echo "stop_socks" >> "$ORDER_LOG"; }

    mark_instance_down 7 >/dev/null 2>&1
    out=$(tr '\n' ' ' < "$ORDER_LOG")
    assert_contains "$out" 'status:draining' 'marks draining'
    assert_contains "$out" 'state:drain' 'runtime drain (no cfg rewrite)'
    if [[ "$out" == *reload* ]]; then
        echo "mark_instance_down must not reload when runtime drain works: $out" >&2
        exit 1
    fi
    if [[ "$out" == *stop_socks* ]] || [[ "$out" == *drain_wait* ]]; then
        echo "mark_instance_down must not drain-wait/stop: $out" >&2
        exit 1
    fi

    # drain_and_stop (real): wait + stop socks + maint (no reload)
    : > "$ORDER_LOG"
    get_instance_status() { printf 'draining\n'; }
    drain_and_stop_instance_socks 7
    out=$(tr '\n' ' ' < "$ORDER_LOG")
    assert_contains "$out" 'drain_wait' 'background helper waits drain'
    assert_contains "$out" 'stop_socks' 'background helper stops socks'
    assert_contains "$out" 'status:down' 'status down while restarting'
    assert_contains "$out" 'state:maint' 'runtime maint while restarting'
    if [[ "$out" == *reload* ]]; then
        echo "drain_and_stop must not reload haproxy: $out" >&2
        exit 1
    fi

    unset -f set_instance_status record_instance_offline_since clear_instance_online_since \
        reload_haproxy_from_status wait_instance_drain stop_instance_socks \
        get_instance_status haproxy_set_server_state 2>/dev/null || true
    rm -rf "$INSTANCE_STATE_DIR"
    INSTANCE_STATE_DIR="$SAVED_STATE_DIR"
    INSTANCE_DRAIN_TIMEOUT=30
}

test_default_instance_count_is_one
test_explicit_instance_count
test_invalid_instance_count_falls_back
test_instance_count_is_capped
test_instance_ids_list
test_instance_paths_and_addresses
test_parse_endpoint_host_port
test_extract_ip_from_probe_body
test_egress_ip_defaults_interleave_vendors
test_inst_id_not_clobbered_by_status_loops
test_generate_warp_config_returns_not_exits_on_failure
test_config_retry_paths
test_config_retry_queue_fifo_and_dedupe
test_effective_warp_api_proxy_rules
test_run_health_checks_prefers_test_urls_when_ip_soft_disabled
test_run_health_checks_fails_when_test_urls_fail_even_if_ip_ok
test_run_health_checks_hard_fails_when_round_gets_no_ip
test_probe_family_stops_after_threshold_links
test_probe_family_stops_early_on_success
test_haproxy_config_only_includes_healthy_servers
test_haproxy_config_with_no_healthy_backends_still_binds
test_refresh_haproxy_pid_prefers_live_pidfile_over_stale_shell
test_reload_uses_soft_path_when_pidfile_live
test_stagger_skips_after_last_instance
test_health_check_stagger_is_interval_div_count
test_config_stale_offline_threshold
test_max_conn_duration_helpers
test_instance_online_duration_probe_log
test_instance_drain_helpers

printf 'PASS test_multi_instance_helpers\n'
