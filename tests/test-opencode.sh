#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/opencode"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n%s\n' "$OPENCODE_RESPONSE" "${OPENCODE_HTTP_CODE:-200}"
EOF
chmod +x "$test_dir/bin/curl"

run_fetch() {
    env PATH="$test_dir/bin:$PATH" \
        OPENCODE_GO_API_KEY="${1-open-code-test}" \
        OPENCODE_API_KEY= \
        OPENCODE_RESPONSE="$2" \
        OPENCODE_HTTP_CODE="${3:-200}" \
        OPENCODE_DATA_DIR="$test_dir/opencode" \
        AIQ_CLAUDE_ENABLED=0 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=1 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_OPENROUTER_ENABLED=0 \
        AIQ_ZAI_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_CACHE_TTL=0 \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

run_fetch 'sk-test' '{"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-09-19T18:57:53.281Z"},"weekly":{"status":"ok","percent":47,"resetsAt":"2026-09-21T00:00:00.000Z"},"monthly":{"status":"ok","percent":23,"resetsAt":"2026-10-17T15:35:37.000Z"}}}' | jq -e '
    .opencode.status == "ok"
    and .opencode.entries[0] == {"name":"Rolling","percentUsed":4,"resetAt":1789844273}
    and .opencode.entries[1] == {"name":"Weekly","percentUsed":47,"resetAt":1789948800}
    and .opencode.entries[2] == {"name":"Monthly","percentUsed":23,"resetAt":1792251337}' >/dev/null

run_fetch 'sk-test' '{"usage":{"rolling":{"status":"ok","percent":120,"resetsAt":"2026-09-19T18:57:53Z"},"weekly":{"status":"ok","percent":-5,"resetsAt":"2026-09-21T00:00:00Z"},"monthly":{"status":"ok","percent":0,"resetsInSeconds":3600}}}' | jq -e '
    .opencode.entries[0].percentUsed == 100
    and .opencode.entries[1].percentUsed == 0
    and (.opencode.entries[2].resetAt > 0)' >/dev/null

run_fetch 'sk-test' '{"usage":{"rolling":{"status":"limit_reached"}}}' | jq -e '
    .opencode.status == "error"' >/dev/null

run_fetch 'sk-test' 'not json' | jq -e '
    .opencode.status == "error"
    and (.opencode.error | test("parse"))' >/dev/null

run_fetch 'sk-test' '{}' 401 | jq -e '.opencode.reason == "auth_expired"' >/dev/null
run_fetch 'sk-test' '{}' 403 | jq -e '.opencode.reason == "no_subscription"' >/dev/null
run_fetch 'sk-test' '{}' 429 | jq -e '.opencode.reason == "rate_limited"' >/dev/null
run_fetch 'sk-test' '{}' 000 | jq -e '.opencode.reason == "network"' >/dev/null
run_fetch 'sk-test' '{}' 500 | jq -e '.opencode.reason == "http_error"' >/dev/null

env PATH="$test_dir/bin:$PATH" \
    OPENCODE_GO_API_KEY= \
    OPENCODE_API_KEY= \
    OPENCODE_DATA_DIR="$test_dir/opencode" \
    AIQ_CLAUDE_ENABLED=0 \
    AIQ_CODEX_ENABLED=0 \
    AIQ_OPENCODE_ENABLED=1 \
    AIQ_DEEPSEEK_ENABLED=0 \
    AIQ_OPENROUTER_ENABLED=0 \
    AIQ_ZAI_ENABLED=0 \
    AIQ_GROK_ENABLED=0 \
    AIQ_ANTIGRAVITY_ENABLED=0 \
    AIQ_CACHE_TTL=0 \
    CACHE_FILE="$test_dir/usage.json" \
    sh "$repo/fetch-usage.sh" | jq -e \
    '.opencode.status == "unavailable" and .opencode.reason == "not_authenticated"' >/dev/null

printf '%s' '{"opencode-go":{"type":"api","key":"sk-local-login"}}' > "$test_dir/opencode/auth.json"
OPENCODE_RESPONSE='{"usage":{"rolling":{"status":"ok","percent":1,"resetsAt":"2026-09-19T18:57:53Z"}}}'
export OPENCODE_RESPONSE
run_fetch '' "$OPENCODE_RESPONSE" | jq -e '
    .opencode.status == "ok" and .opencode.entries[0].percentUsed == 1' >/dev/null
