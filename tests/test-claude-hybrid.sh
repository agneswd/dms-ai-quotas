#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/claude"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test","subscriptionType":"pro"}}' \
    > "$test_dir/claude/.credentials.json"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
count=0
[ ! -f "$CURL_COUNT_FILE" ] || count=$(cat "$CURL_COUNT_FILE")
printf '%s\n' $((count + 1)) > "$CURL_COUNT_FILE"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-D" ]; then
        shift
        headers=$1
    fi
    shift
done
if [ "${CURL_MODE:-success}" = "429" ]; then
    printf 'HTTP/2 429\r\nRetry-After: 600\r\n\r\n' > "$headers"
    printf '\n429\n'
else
    printf 'HTTP/2 200\r\n\r\n' > "$headers"
    printf '%s\n200\n' '{"limits":[{"kind":"session","percent":41,"resets_at":"2030-01-01T00:00:00Z"},{"kind":"weekly_all","percent":9,"resets_at":"2030-01-02T00:00:00Z"}]}'
fi
EOF
chmod +x "$test_dir/bin/curl"

run_fetch() {
    env PATH="$test_dir/bin:$PATH" \
        AIQ_CLAUDE_ENABLED=1 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_CACHE_TTL=0 \
        CLAUDE_CONFIG_DIR="$test_dir/claude" \
        CLAUDE_USAGE_FILE="$test_dir/claude-usage.json" \
        CLAUDE_FALLBACK_STATE_FILE="$test_dir/claude-fallback.json" \
        CACHE_FILE="$test_dir/usage.json" \
        CURL_COUNT_FILE="$test_dir/curl-count" \
        CURL_MODE="${CURL_MODE:-success}" \
        sh "$repo/fetch-usage.sh"
}

now=$(date +%s)
jq -n --argjson now "$now" \
    '{captured_at:$now,entries:[{name:"5h",percentUsed:10,resetAt:1800000000}]}' \
    > "$test_dir/claude-usage.json"
run_fetch | jq -e '.claude.entries[0].percentUsed == 10' >/dev/null
[ ! -f "$test_dir/curl-count" ]

jq -n '{captured_at:1,entries:[{name:"5h",percentUsed:10,resetAt:1800000000}]}' \
    > "$test_dir/claude-usage.json"
run_fetch | jq -e '.claude.entries[0].percentUsed == 41' >/dev/null
[ "$(cat "$test_dir/curl-count")" = "1" ]
run_fetch >/dev/null
[ "$(cat "$test_dir/curl-count")" = "1" ]

jq -n '{captured_at:1,entries:[{name:"5h",percentUsed:41,resetAt:1800000000}]}' \
    > "$test_dir/claude-usage.json"
rm -f "$test_dir/claude-fallback.json"
CURL_MODE=429 run_fetch | jq -e '.claude.status == "ok"' >/dev/null
[ "$(cat "$test_dir/curl-count")" = "2" ]
CURL_MODE=429 run_fetch >/dev/null
[ "$(cat "$test_dir/curl-count")" = "2" ]
jq -e --argjson now "$now" '.retry_at > $now' "$test_dir/claude-fallback.json" >/dev/null
