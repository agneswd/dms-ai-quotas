#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/opencode"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
case "$OPENCODE_HTTP_CODE" in
    '')
        printf '%s\n200\n' "$OPENCODE_RESPONSE" ;;
    *)
        printf '%s\n%s\n' "$OPENCODE_RESPONSE" "$OPENCODE_HTTP_CODE" ;;
esac
EOF
chmod +x "$test_dir/bin/curl"

ok_body='{"usage":{"rolling":{"status":"ok","percent":11,"resetsAt":"2030-01-01T00:00:00.000Z"},"weekly":{"status":"ok","percent":22,"resetsAt":"2030-01-08T00:00:00Z"},"monthly":{"status":"ok","percent":33,"resetsAt":"2030-02-01T00:00:00.510Z"}}}'

run_fetch() {
    env PATH="$test_dir/bin:$PATH" \
        OPENCODE_RESPONSE="${1:-}" \
        OPENCODE_HTTP_CODE="${2:-}" \
        AIQ_CLAUDE_ENABLED=0 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=1 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_OPENROUTER_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        OPENCODE_GO_API_KEY="${OPENCODE_GO_API_KEY-sk-test}" \
        OPENCODE_DATA_DIR="$test_dir/opencode" \
        AIQ_CACHE_TTL=0 \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

run_fetch "$ok_body" | jq -e \
    '.opencode.status == "ok"
     and .opencode.entries == [
       {"name":"Rolling","percentUsed":11,"resetAt":1893456000},
       {"name":"Weekly","percentUsed":22,"resetAt":1894060800},
       {"name":"Monthly","percentUsed":33,"resetAt":1896134400}
     ]' >/dev/null

run_fetch '{"usage":{"rolling":{"status":"limited","percent":90,"resetsAt":"2030-01-01T00:00:00Z"},"weekly":{"status":"ok","percent":5,"resetsAt":"2030-01-08T00:00:00Z"},"monthly":{"percent":7,"resetsAt":"2030-02-01T00:00:00Z"}}}' | jq -e \
    '.opencode.status == "ok"
     and (.opencode.entries | length) == 2
     and .opencode.entries[0].name == "Weekly"
     and .opencode.entries[1].name == "Monthly"' >/dev/null

run_fetch '{}' 401 | jq -e \
    '.opencode.status == "error" and .opencode.reason == "auth_expired"' >/dev/null

run_fetch '{}' 403 | jq -e \
    '.opencode.status == "error" and .opencode.reason == "access_denied"' >/dev/null

run_fetch '{}' 000 | jq -e \
    '.opencode.status == "error" and .opencode.reason == "network"' >/dev/null

run_fetch '{"error":"bad shape"}' | jq -e \
    '.opencode.status == "error"
     and .opencode.error == "Could not parse OpenCode usage"' >/dev/null

OPENCODE_GO_API_KEY= run_fetch "$ok_body" | jq -e \
    '.opencode.status == "unavailable"
     and .opencode.reason == "not_authenticated"' >/dev/null

printf '%s\n' '{"opencode-go":{"type":"api","key":"sk-from-file"}}' > "$test_dir/opencode/auth.json"
OPENCODE_GO_API_KEY= run_fetch "$ok_body" | jq -e \
    '.opencode.status == "ok" and .opencode.entries[0].name == "Rolling"' >/dev/null
