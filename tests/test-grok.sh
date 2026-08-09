#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/grok"
printf '%s\n' '{"account":{"key":"test","email":"test@example.com"}}' > "$test_dir/grok/auth.json"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n200\n' "$GROK_RESPONSE"
EOF
chmod +x "$test_dir/bin/curl"

env PATH="$test_dir/bin:$PATH" \
    GROK_RESPONSE='{"config":{"currentPeriod":{"end":"2030-01-01T00:00:00Z"},"isUnifiedBillingUser":true,"onDemandCap":{"val":100},"onDemandUsed":{"val":25}}}' \
    AIQ_CLAUDE_ENABLED=0 \
    AIQ_CODEX_ENABLED=0 \
    AIQ_OPENCODE_ENABLED=0 \
    AIQ_DEEPSEEK_ENABLED=0 \
    AIQ_GROK_ENABLED=1 \
    AIQ_ANTIGRAVITY_ENABLED=0 \
    AIQ_CACHE_TTL=0 \
    GROK_HOME="$test_dir/grok" \
    CACHE_FILE="$test_dir/usage.json" \
    sh "$repo/fetch-usage.sh" | jq -e \
        '.grok.status == "ok"
         and .grok.entries == [{"name":"Billing","kind":"on_demand","percentUsed":25,"resetAt":1893456000}]' \
        >/dev/null

env PATH="$test_dir/bin:$PATH" \
    GROK_RESPONSE='{"config":{"billingPeriodEnd":"2030-01-01T00:00:00Z","isUnifiedBillingUser":true,"onDemandCap":{"val":0},"onDemandUsed":{"val":0}}}' \
    AIQ_CLAUDE_ENABLED=0 \
    AIQ_CODEX_ENABLED=0 \
    AIQ_OPENCODE_ENABLED=0 \
    AIQ_DEEPSEEK_ENABLED=0 \
    AIQ_GROK_ENABLED=1 \
    AIQ_ANTIGRAVITY_ENABLED=0 \
    AIQ_CACHE_TTL=0 \
    GROK_HOME="$test_dir/grok" \
    CACHE_FILE="$test_dir/usage.json" \
    sh "$repo/fetch-usage.sh" | jq -e \
        '.grok.status == "unavailable"
         and .grok.reason == "no_quota"' \
        >/dev/null
