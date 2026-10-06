#!/bin/sh
set -eu

# Run the full fetch command against fake Kimi Code responses.
# Failures: wrong windows from current or older response shapes, ratios not
# turned into percentages, expired or missing CLI tokens still sent, the API key
# not taking precedence, and keys sent to unknown hosts.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/home/.kimi-code/credentials"
requests="$test_dir/requests.txt"
creds="$test_dir/home/.kimi-code/credentials/kimi-code.json"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$AIQ_TEST_REQUESTS"
for arg in "$@"; do
    case "$arg" in @*) sed -n 's/^Authorization: Bearer //p' "${arg#@}" >> "$AIQ_TEST_REQUESTS" ;; esac
done
printf '%s\n%s\n' "$KIMI_RESPONSE" "${KIMI_HTTP_CODE:-200}"
EOF
chmod +x "$test_dir/bin/curl"

run_fetch() {
    : > "$requests"
    env PATH="$test_dir/bin:$PATH" HOME="$test_dir/home" \
        AIQ_TEST_REQUESTS="$requests" \
        KIMI_RESPONSE="$1" \
        KIMI_HTTP_CODE="${2:-200}" \
        KIMI_API_KEY="${KIMI_API_KEY-sk-kimi-test}" \
        KIMI_CODE_BASE_URL="${KIMI_CODE_BASE_URL:-}" \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_ZAI_ENABLED=0 AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 \
        AIQ_GROK_ENABLED=0 AIQ_ANTIGRAVITY_ENABLED=0 AIQ_KIMI_ENABLED=1 \
        AIQ_CACHE_TTL=0 \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

current_body='{"user":{"membership":{"level":"LEVEL_INTERMEDIATE"}},"usages":{
    "limit_5h":{"used_ratio":0.3,"reset_time":"2030-01-01T00:00:00.716839300Z"},
    "limit_7d":{"used_ratio":"0.2","reset_time":"2030-01-08T00:00:00Z"},
    "limit_month_total":{"used_ratio":1.4,"reset_time":"2030-02-01T00:00:00Z"},
    "limit_month_code":{"reset_time":"2030-02-01T00:00:00Z"}
}}'
run_fetch "$current_body" | jq -e '
    .kimi == {
        "status": "ok",
        "plan": "intermediate",
        "entries": [
            {"name": "5h", "percentUsed": 30, "resetAt": 1893456000},
            {"name": "Weekly", "percentUsed": 20, "resetAt": 1894060800},
            {"name": "Monthly", "percentUsed": 100, "resetAt": 1896134400}
        ]
    }' >/dev/null
grep -Fqx 'https://api.kimi.com/coding/v1/usages' "$requests"
grep -Fqx 'sk-kimi-test' "$requests"

# Older responses: count windows plus a weekly usage summary.
run_fetch '{"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2030-01-08T00:00:00Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","remaining":"50","resetTime":"2030-01-01T00:00:00Z"}}]}' | jq -e '
    .kimi.entries == [
        {"name": "5h", "percentUsed": 75, "resetAt": 1893456000},
        {"name": "Weekly", "percentUsed": 10.45, "resetAt": 1894060800}
    ]' >/dev/null

run_fetch '{"usages":{}}' | jq -e '.kimi.status == "unavailable" and .kimi.reason == "no_quota"' >/dev/null
run_fetch '[]' | jq -e '.kimi.status == "error"' >/dev/null
run_fetch '{}' 401 | jq -e '.kimi.reason == "auth_expired" and (.kimi.error | contains("API key"))' >/dev/null
run_fetch '{}' 404 | jq -e '.kimi.reason == "access_denied"' >/dev/null
run_fetch '{}' 000 | jq -e '.kimi.reason == "network"' >/dev/null

# Without an API key, use the kimi CLI token while it is valid.
now=$(date +%s)
jq -n --argjson exp $((now + 600)) '{access_token: "cli-token", refresh_token: "never-sent", expires_at: $exp}' > "$creds"
KIMI_API_KEY= run_fetch "$current_body" | jq -e '.kimi.status == "ok"' >/dev/null
grep -Fqx 'cli-token' "$requests"
if grep -q 'never-sent' "$requests"; then exit 1; fi
KIMI_API_KEY= run_fetch '{}' 401 | jq -e '.kimi.error | contains("kimi login token")' >/dev/null

# The API key wins over the CLI token.
run_fetch "$current_body" >/dev/null
grep -Fqx 'sk-kimi-test' "$requests"
if grep -q 'cli-token' "$requests"; then exit 1; fi

jq -n --argjson exp $((now + 30)) '{access_token: "cli-token", expires_at: $exp}' > "$creds"
KIMI_API_KEY= run_fetch "$current_body" | jq -e '.kimi.reason == "auth_expired"' >/dev/null
[ ! -s "$requests" ]

rm "$creds"
KIMI_API_KEY= run_fetch "$current_body" | jq -e '.kimi.reason == "not_authenticated"' >/dev/null
[ ! -s "$requests" ]

# The key goes only to the official hosts.
KIMI_CODE_BASE_URL=https://api.kimi.ai/coding/v1/ run_fetch "$current_body" >/dev/null
grep -Fqx 'https://api.kimi.ai/coding/v1/usages' "$requests"
KIMI_CODE_BASE_URL=https://api.kimi.com.evil.example/v1 run_fetch "$current_body" | jq -e '.kimi.reason == "invalid_config"' >/dev/null
[ ! -s "$requests" ]

if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    run_fetch "$current_body" > "$AIQ_TEST_ARTIFACT_DIR/kimi-result.json"
fi
printf '%s\n' 'Kimi Code fetch checks passed.'
