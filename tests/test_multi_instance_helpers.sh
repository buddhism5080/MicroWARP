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

test_haproxy_config_only_includes_healthy_servers() {
    local cfg
    cfg=$(render_haproxy_config '0.0.0.0' '1080' '1:down 2:up 3:up')

    assert_contains "$cfg" 'bind 0.0.0.0:1080' 'frontend bind'
    assert_contains "$cfg" 'mode tcp' 'tcp mode'
    assert_contains "$cfg" 'balance roundrobin' 'round robin'
    assert_contains "$cfg" 'server inst2 10.66.2.2:1080 check' 'healthy instance 2'
    assert_contains "$cfg" 'server inst3 10.66.3.2:1080 check' 'healthy instance 3'

    if [[ "$cfg" == *'server inst1 '* ]]; then
        echo 'unhealthy instance 1 must not appear as an active server' >&2
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

test_default_instance_count_is_one
test_explicit_instance_count
test_invalid_instance_count_falls_back
test_instance_count_is_capped
test_instance_ids_list
test_instance_paths_and_addresses
test_haproxy_config_only_includes_healthy_servers
test_haproxy_config_with_no_healthy_backends_still_binds
test_stagger_skips_after_last_instance
test_health_check_stagger_is_interval_div_count
test_config_stale_offline_threshold

printf 'PASS test_multi_instance_helpers\n'
