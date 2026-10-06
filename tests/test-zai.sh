#!/bin/sh
set -eu

# Run the full fetch command against fake Z.ai responses.
# Failures: wrong window names or order, percentages that ignore credit counts,
# millisecond resets, HTTP 200 error envelopes, unknown hosts receiving the key,
# and requests sent without a key.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin"
requests="$test_dir/requests.txt"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$AIQ_TEST_REQUESTS"
printf '%s\n%s\n' "$ZAI_RESPONSE" "${ZAI_HTTP_CODE:-200}"
EOF
chmod +x "$test_dir/bin/curl"

run_fetch() {
    : > "$requests"
    env PATH="$test_dir/bin:$PATH" \
        AIQ_TEST_REQUESTS="$requests" \
        ZAI_RESPONSE="$1" \
        ZAI_HTTP_CODE="${2:-200}" \
        ZAI_API_KEY="${ZAI_API_KEY-zai-test}" \
        ZAI_API_HOST="${ZAI_API_HOST:-}" \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_KIMI_ENABLED=0 AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 \
        AIQ_GROK_ENABLED=0 AIQ_ANTIGRAVITY_ENABLED=0 AIQ_ZAI_ENABLED=1 \
        AIQ_CACHE_TTL=0 \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

# Credit plan: counts win over the rounded percentage, MCP sorts last.
credit_body='{"code":200,"success":true,"data":{"level":"pro","limits":[
    {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":50,"percentage":5,"nextResetTime":1896134400000},
    {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":"60000","remaining":"48000","percentage":20,"nextResetTime":"1893542400000"},
    {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":3001,"percentage":25,"nextResetTime":1893456000123},
    {"type":"SOMETHING_NEW","unit":3,"number":1,"percentage":99}
]}}'
run_fetch "$credit_body" | jq -e '
    .zai == {
        "status": "ok",
        "plan": "pro",
        "entries": [
            {"name": "5h", "percentUsed": 25.01, "resetAt": 1893456000},
            {"name": "Weekly", "percentUsed": 20, "resetAt": 1893542400},
            {"name": "MCP", "percentUsed": 5, "resetAt": 1896134400}
        ]
    }' >/dev/null
grep -Fqx 'https://api.z.ai/api/monitor/usage/quota/limit' "$requests"

# Legacy token plan: percentages only, clamped to 0-100.
run_fetch '{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":120,"nextResetTime":1893456000000},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":-5}]}}' | jq -e '
    .zai.entries == [
        {"name": "5h", "percentUsed": 100, "resetAt": 1893456000},
        {"name": "MCP", "percentUsed": 0, "resetAt": 0}
    ]' >/dev/null

run_fetch '{"code":200,"data":{"limits":[{"type":"SOMETHING_NEW","percentage":10}]}}' | jq -e \
    '.zai.status == "unavailable" and .zai.reason == "no_quota"' >/dev/null

# Z.ai reports a bad key as HTTP 200 with an error envelope.
run_fetch '{"code":1001,"success":false,"msg":"Authorization Token Missing"}' | jq -e '
    .zai.status == "error" and .zai.reason == "auth_expired"
    and (.zai.error | contains("Authorization Token Missing"))' >/dev/null
run_fetch '{"code":500,"success":false,"msg":"busy"}' | jq -e '.zai.reason == "api_error"' >/dev/null
run_fetch '{"data":{}}' | jq -e '.zai.status == "error"' >/dev/null

run_fetch '{}' 401 | jq -e '.zai.reason == "auth_expired"' >/dev/null
run_fetch '{}' 429 | jq -e '.zai.reason == "rate_limited"' >/dev/null
run_fetch '{}' 000 | jq -e '.zai.reason == "network"' >/dev/null
run_fetch '{}' 502 | jq -e '.zai.reason == "http_error"' >/dev/null

ZAI_API_HOST=open.bigmodel.cn run_fetch "$credit_body" | jq -e '.zai.status == "ok"' >/dev/null
grep -Fqx 'https://open.bigmodel.cn/api/monitor/usage/quota/limit' "$requests"

# The key must never go to another host, and no request goes out without a key.
ZAI_API_HOST=evil.example run_fetch "$credit_body" | jq -e '.zai.reason == "invalid_config"' >/dev/null
[ ! -s "$requests" ]
ZAI_API_KEY= run_fetch "$credit_body" | jq -e '.zai.reason == "not_authenticated"' >/dev/null
[ ! -s "$requests" ]

if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    run_fetch "$credit_body" > "$AIQ_TEST_ARTIFACT_DIR/zai-result.json"
fi
printf '%s\n' 'Z.ai fetch checks passed.'
