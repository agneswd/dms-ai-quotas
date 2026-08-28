#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
case "$OPENROUTER_HTTP_CODE" in
    '')
        printf '%s\n200\n' "$OPENROUTER_RESPONSE" ;;
    *)
        printf '%s\n%s\n' "$OPENROUTER_RESPONSE" "$OPENROUTER_HTTP_CODE" ;;
esac
EOF
chmod +x "$test_dir/bin/curl"

run_fetch() {
    env PATH="$test_dir/bin:$PATH" \
        OPENROUTER_RESPONSE="$1" \
        OPENROUTER_HTTP_CODE="${2:-200}" \
        AIQ_CLAUDE_ENABLED=0 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_OPENROUTER_ENABLED=1 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        OPENROUTER_API_KEY=sk-or-test \
        AIQ_CACHE_TTL=0 \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

run_fetch '{"data":{"total_credits":100.5,"total_usage":25.75}}' | jq -e \
    '.openrouter.status == "ok"
     and .openrouter.balances == [{"currency":"USD","total":"74.75","purchased":"100.5","used":"25.75"}]' \
    >/dev/null

run_fetch '{}' 401 | jq -e \
    '.openrouter.status == "error" and .openrouter.reason == "auth_expired"' \
    >/dev/null

run_fetch '{}' 403 | jq -e \
    '.openrouter.status == "error" and .openrouter.reason == "access_denied"' \
    >/dev/null

run_fetch '{"message":"management key required"}' 500 | jq -e \
    '.openrouter.status == "error" and .openrouter.reason == "http_error"' \
    >/dev/null

run_fetch '{}' 000 | jq -e \
    '.openrouter.status == "error" and .openrouter.reason == "network"' \
    >/dev/null

run_fetch '{"error":"bad shape"}' | jq -e \
    '.openrouter.status == "error"
     and .openrouter.error == "Could not parse OpenRouter credits response"' \
    >/dev/null
