#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n%s\n' "$ZAI_RESPONSE" "${ZAI_HTTP_CODE:-200}"
EOF
chmod +x "$test_dir/bin/curl"

run_fetch() {
    env PATH="$test_dir/bin:$PATH" \
        ZAI_RESPONSE="$1" \
        ZAI_HTTP_CODE="${2:-200}" \
        ZAI_API_KEY="${3-zai-test}" \
        ANTHROPIC_AUTH_TOKEN= \
        AIQ_CLAUDE_ENABLED=0 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_OPENROUTER_ENABLED=0 \
        AIQ_ZAI_ENABLED=1 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_CACHE_TTL=0 \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

run_fetch '{"code":200,"success":true,"data":{"level":"pro","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":3000,"remaining":9000,"percentage":25,"nextResetTime":1893456000123},{"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":"60000","currentValue":"12000","remaining":"48000","nextResetTime":"1893542400000"}]}}' | jq -e '
    .zai.status == "ok"
    and .zai.plan == "pro"
    and .zai.entries[0] == {"name":"5h","percentUsed":25,"resetAt":1893456000,"limit":12000,"used":3000,"remaining":9000}
    and .zai.entries[1] == {"name":"Weekly","percentUsed":20,"resetAt":1893542400,"limit":60000,"used":12000,"remaining":48000}' >/dev/null

run_fetch '{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":120,"nextResetTime":1893456000},{"type":"TIME_LIMIT","percentage":-5,"nextResetTime":1893542400}]}}' | jq -e '
    .zai.entries[0].name == "5h" and .zai.entries[0].percentUsed == 100
    and .zai.entries[1].name == "MCP" and .zai.entries[1].percentUsed == 0' >/dev/null

run_fetch '{"code":1000,"success":false,"msg":"invalid token"}' | jq -e \
    '.zai.status == "error" and .zai.reason == "auth_expired"' >/dev/null

run_fetch '{}' 401 | jq -e '.zai.reason == "auth_expired"' >/dev/null
run_fetch '{}' 403 | jq -e '.zai.reason == "access_denied"' >/dev/null
run_fetch '{}' 429 | jq -e '.zai.reason == "rate_limited"' >/dev/null
run_fetch '{}' 000 | jq -e '.zai.reason == "network"' >/dev/null
run_fetch '{}' 500 | jq -e '.zai.reason == "http_error"' >/dev/null

run_fetch '{}' 200 '' | jq -e \
    '.zai.status == "unavailable" and .zai.reason == "not_authenticated"' >/dev/null
