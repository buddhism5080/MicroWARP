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

reset_mocks() {
    CURL_LOG_FILE=/tmp/microwarp-curl-calls.log
    : > "$CURL_LOG_FILE"
    SLEEP_CALLS=0
    SLEPT_SECONDS=''
    CURL_MODE=''
}

sleep() {
    SLEEP_CALLS=$((SLEEP_CALLS + 1))
    SLEPT_SECONDS="${SLEPT_SECONDS}${1},"
}

curl() {
    local url="${@: -1}"
    printf '%s\n' "$url" >> "$CURL_LOG_FILE"
    local curl_calls
    curl_calls=$(wc -l < "$CURL_LOG_FILE" | tr -d ' ')

    case "$CURL_MODE:$url:$curl_calls" in
        timeout_then_success:https://timeout.example:1|timeout_then_success:https://timeout.example:2)
            printf '000'
            return 28
            ;;
        timeout_then_success:https://timeout.example:3)
            printf '204'
            return 0
            ;;
        dns_then_success:https://dns.example:1|dns_then_success:https://dns.example:2)
            printf '000'
            return 6
            ;;
        dns_then_success:https://dns.example:3)
            printf '204'
            return 0
            ;;
        network_then_success:https://network.example:1|network_then_success:https://network.example:2)
            printf '000'
            return 7
            ;;
        network_then_success:https://network.example:3)
            printf '204'
            return 0
            ;;
        non_retryable_failure:https://fail.example:1)
            printf '000'
            return 35
            ;;
        *)
            printf 'unexpected curl invocation: %s:%s:%s\n' "$CURL_MODE" "$url" "$curl_calls" >&2
            return 99
            ;;
    esac
}

test_timeout_retries_before_success() {
    reset_mocks
    CURL_MODE='timeout_then_success'
    TEST_URLS='https://timeout.example'

    if ! check_test_urls >/tmp/microwarp-timeout-retry.log 2>&1; then
        cat /tmp/microwarp-timeout-retry.log >&2
        echo 'expected check_test_urls to succeed after timeout retries' >&2
        exit 1
    fi

    local curl_calls
    curl_calls=$(wc -l < "$CURL_LOG_FILE" | tr -d ' ')

    assert_eq "$curl_calls" '3' 'timeout should trigger 2 retries for a total of 3 attempts'
    assert_eq "$SLEEP_CALLS" '2' 'timeout retries should sleep twice'
    assert_eq "$SLEPT_SECONDS" '5,5,' 'timeout retries should wait 5 seconds between attempts'
}

test_dns_retries_before_success() {
    reset_mocks
    CURL_MODE='dns_then_success'
    TEST_URLS='https://dns.example'

    if ! check_test_urls >/tmp/microwarp-dns-retry.log 2>&1; then
        cat /tmp/microwarp-dns-retry.log >&2
        echo 'expected DNS failures to succeed after retries' >&2
        exit 1
    fi

    local curl_calls
    curl_calls=$(wc -l < "$CURL_LOG_FILE" | tr -d ' ')

    assert_eq "$curl_calls" '3' 'DNS failures should trigger 2 retries for a total of 3 attempts'
    assert_eq "$SLEEP_CALLS" '2' 'DNS retries should sleep twice'
    assert_eq "$SLEPT_SECONDS" '5,5,' 'DNS retries should wait 5 seconds between attempts'
}

test_network_retries_before_success() {
    reset_mocks
    CURL_MODE='network_then_success'
    TEST_URLS='https://network.example'

    if ! check_test_urls >/tmp/microwarp-network-retry.log 2>&1; then
        cat /tmp/microwarp-network-retry.log >&2
        echo 'expected local network failures to succeed after retries' >&2
        exit 1
    fi

    local curl_calls
    curl_calls=$(wc -l < "$CURL_LOG_FILE" | tr -d ' ')

    assert_eq "$curl_calls" '3' 'local network failures should trigger 2 retries for a total of 3 attempts'
    assert_eq "$SLEEP_CALLS" '2' 'local network retries should sleep twice'
    assert_eq "$SLEPT_SECONDS" '5,5,' 'local network retries should wait 5 seconds between attempts'
}

test_non_retryable_errors_fail_without_retry() {
    reset_mocks
    CURL_MODE='non_retryable_failure'
    TEST_URLS='https://fail.example'

    if check_test_urls >/tmp/microwarp-non-timeout.log 2>&1; then
        cat /tmp/microwarp-non-timeout.log >&2
        echo 'expected non-retryable curl failures to fail immediately' >&2
        exit 1
    fi

    local curl_calls
    curl_calls=$(wc -l < "$CURL_LOG_FILE" | tr -d ' ')

    assert_eq "$curl_calls" '1' 'non-retryable errors should not retry'
    assert_eq "$SLEEP_CALLS" '0' 'non-retryable errors should not sleep'
}

test_timeout_retries_before_success
test_dns_retries_before_success
test_network_retries_before_success
test_non_retryable_errors_fail_without_retry

printf 'PASS test_test_url_timeout_retries\n'
