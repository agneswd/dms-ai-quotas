#!/bin/sh
# Claude usage: source selection, reset rollover, adaptive polling, and backoff.
#
# Ways this can fail, each checked below:
# - A window that reset long ago still shows its old percentage.
# - Fresh Claude Code data in .claude.json is ignored, or data of another account is used.
# - An older source hides a newer one, or the status line drops a model-scoped limit.
# - The plugin polls the usage API while nothing changed, or polls again too soon.
# - The plugin does not poll after Claude Code was used and the data is old.
# - A 429 or 401 does not back off, or a 429 without Retry-After backs off for an hour.
# - A Claude-only refresh drops other providers or resets the cache age.
# - The plan comes from the login-time credentials after the subscription changed.
# - The status line capture leaves a world-readable file.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
config="$test_dir/claude"
mkdir -p "$test_dir/bin" "$config/projects/p"
account=11111111-2222-3333-4444-555555555555

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
count=0
[ ! -f "$CURL_COUNT_FILE" ] || count=$(cat "$CURL_COUNT_FILE")
printf '%s\n' $((count + 1)) > "$CURL_COUNT_FILE"
while [ "$#" -gt 0 ]; do
    case "$1" in *test-token*) exit 1 ;; esac
    if [ "$1" = "-D" ]; then
        shift
        headers=$1
    fi
    shift
done
case "${CURL_MODE:-success}" in
    401)
        printf 'HTTP/2 401\r\n\r\n' > "$headers"
        printf '\n401\n'
        ;;
    429)
        printf 'HTTP/2 429\r\nRetry-After: 900\r\n\r\n' > "$headers"
        printf '\n429\n'
        ;;
    429-bare)
        printf 'HTTP/2 429\r\n\r\n' > "$headers"
        printf '\n429\n'
        ;;
    *)
        printf 'HTTP/2 200\r\n\r\n' > "$headers"
        printf '%s\n200\n' '{"five_hour":{"utilization":41,"resets_at":"2030-01-01T00:00:00.123+00:00"},"seven_day":{"utilization":9,"resets_at":"2030-01-02T00:00:00Z"},"limits":[{"kind":"session","percent":41,"resets_at":"2030-01-01T00:00:00.123+00:00"},{"kind":"weekly_all","percent":9,"resets_at":"2030-01-02T00:00:00Z"},{"kind":"weekly_scoped","percent":3,"resets_at":"2030-01-02T00:00:00Z","scope":{"model":{"display_name":"Fable"}}}]}'
        ;;
esac
EOF
chmod +x "$test_dir/bin/curl"

run_fetch() {
    env PATH="$test_dir/bin:$PATH" \
        AIQ_PROVIDERS="${AIQ_PROVIDERS:-}" \
        AIQ_CODEX_ENABLED=0 AIQ_COPILOT_ENABLED=0 AIQ_OPENCODE_ENABLED=0 AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 AIQ_MISTRAL_ENABLED=0 AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_CACHE_TTL="${AIQ_CACHE_TTL:-0}" \
        CLAUDE_CONFIG_DIR="$config" \
        CLAUDE_USAGE_FILE="$test_dir/native.json" \
        CLAUDE_FALLBACK_STATE_FILE="$test_dir/poll.json" \
        CACHE_FILE="$test_dir/usage.json" \
        CURL_COUNT_FILE="$test_dir/curl-count" \
        CURL_MODE="${CURL_MODE:-success}" \
        sh "$repo/fetch-usage.sh"
}

curl_count() { cat "$test_dir/curl-count" 2>/dev/null || printf 0; }
reset_state() { rm -f "$test_dir"/native.json "$test_dir"/poll.json "$config/.claude.json" "$test_dir/curl-count"; }
login() {
    printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}' \
        > "$config/.credentials.json"
}
# Claude Code's own cache. Usage: claude_code_cache FETCHED_AT [ACCOUNT]
claude_code_cache() {
    jq -n --argjson at "$1" --arg acc "${2:-$account}" --arg me "$account" '{
        oauthAccount: {accountUuid: $me},
        cachedUsageUtilization: {fetchedAtMs: ($at * 1000), accountUuid: $acc, utilization: {
            five_hour: {utilization: 30, resets_at: "2030-01-01T00:00:00Z"},
            limits: [
                {kind: "session", percent: 30, resets_at: "2030-01-01T00:00:00.5+00:00"},
                {kind: "weekly_all", percent: 50, resets_at: "2030-01-02T00:00:00Z"},
                {kind: "weekly_scoped", percent: 7, resets_at: "2030-01-02T00:00:00Z",
                 scope: {model: {display_name: "Fable"}}}
            ]}}}' > "$config/.claude.json"
}
# A transcript write, the signal that Claude Code was used. Usage: activity AT
activity() { touch -d "@$1" "$config/projects/p/session.jsonl"; }

now=$(date +%s)
login
activity $((now - 86400))

# A window that reset long ago shows as unused, without a reset time.
jq -n --argjson at $((now - 120)) --argjson past $((now - 60)) \
    '{captured_at: $at, entries: [
        {name: "5h", percentUsed: 100, resetAt: $past},
        {name: "Weekly", percentUsed: 20, resetAt: 1893456000}]}' > "$test_dir/native.json"
run_fetch | jq -e '.claude.entries == [
    {name: "5h", percentUsed: 0, resetAt: 0},
    {name: "Weekly", percentUsed: 20, resetAt: 1893456000}]
    and .claude.source == "native" and .claude.stale == false and .claude.plan == "Max 5x"' >/dev/null
[ "$(curl_count)" = 0 ]

# Claude Code's cache is newer, so it wins with its model-scoped limit. No request.
reset_state
jq -n --argjson at $((now - 600)) '{captured_at: $at, entries: [{name: "5h", percentUsed: 90, resetAt: 1893456000}]}' \
    > "$test_dir/native.json"
claude_code_cache $((now - 30))
run_fetch | jq -e --argjson at $((now - 30)) '.claude.entries == [
    {name: "5h", percentUsed: 30, resetAt: 1893456000},
    {name: "Weekly", percentUsed: 50, resetAt: 1893542400},
    {name: "Weekly Fable", percentUsed: 7, resetAt: 1893542400}]
    and .claude.source == "claude-code" and .claude.capturedAt == $at' >/dev/null
[ "$(curl_count)" = 0 ]

# The cache of another account is ignored.
claude_code_cache $((now - 30)) 99999999-0000-0000-0000-000000000000
run_fetch | jq -e '.claude.source == "native" and .claude.entries[0].percentUsed == 90' >/dev/null

# A newer status line overrides its windows and keeps the model-scoped limit.
claude_code_cache $((now - 200))
jq -n --argjson at $((now - 10)) '{captured_at: $at, entries: [
    {name: "5h", percentUsed: 35, resetAt: 1893456000},
    {name: "Weekly", percentUsed: 51, resetAt: 1893542400}]}' > "$test_dir/native.json"
run_fetch | jq -e '.claude.source == "native" and .claude.entries == [
    {name: "5h", percentUsed: 35, resetAt: 1893456000},
    {name: "Weekly", percentUsed: 51, resetAt: 1893542400},
    {name: "Weekly Fable", percentUsed: 7, resetAt: 1893542400}]' >/dev/null
[ "$(curl_count)" = 0 ]

# Idle: no Claude Code use since the data, and the data is under 15 minutes old. No request.
reset_state
claude_code_cache $((now - 800))
run_fetch | jq -e '.claude.source == "claude-code" and .claude.stale == false' >/dev/null
[ "$(curl_count)" = 0 ]

# Idle for 15 minutes: one request to catch use from other devices.
claude_code_cache $((now - 900))
run_fetch | jq -e '.claude.source == "oauth" and .claude.entries[0].percentUsed == 41' >/dev/null
[ "$(curl_count)" = 1 ]

# Claude Code was used after the data and the data is a minute old: one request, then none for a minute.
reset_state
claude_code_cache $((now - 70))
activity $((now - 5))
run_fetch | jq -e --argjson now "$now" '.claude.source == "oauth" and .claude.capturedAt >= $now
    and (.claude.entries | map(.name)) == ["5h", "Weekly", "Weekly Fable"]' >/dev/null
[ "$(curl_count)" = 1 ]
activity $((now + 5))
run_fetch >/dev/null
[ "$(curl_count)" = 1 ]

# Use under a minute after the data does not poll.
reset_state
claude_code_cache $((now - 40))
activity $((now - 5))
run_fetch >/dev/null
[ "$(curl_count)" = 0 ]

# 429 with Retry-After: keep the old data, mark it stale, and wait the given time.
reset_state
claude_code_cache $((now - 400))
activity $((now - 5))
CURL_MODE=429 run_fetch | jq -e '.claude.status == "ok" and .claude.stale == true and .claude.source == "claude-code"' >/dev/null
jq -e --argjson now "$now" '.retry_at >= $now + 900' "$test_dir/poll.json" >/dev/null
jq '.checked_at = 0' "$test_dir/poll.json" > "$test_dir/poll.tmp" && mv "$test_dir/poll.tmp" "$test_dir/poll.json"
CURL_MODE=429 run_fetch >/dev/null
[ "$(curl_count)" = 1 ]

# 429 without Retry-After backs off for minutes, not an hour.
rm -f "$test_dir/poll.json"
CURL_MODE=429-bare run_fetch >/dev/null
jq -e --argjson now "$now" '.retry_at > $now + 60 and .retry_at <= $now + 900' "$test_dir/poll.json" >/dev/null

# 401 without data: the login expired. It backs off too.
reset_state
activity $((now - 5))
CURL_MODE=401 run_fetch | jq -e '.claude.reason == "auth_expired"' >/dev/null
jq '.checked_at = 0' "$test_dir/poll.json" > "$test_dir/poll.tmp" && mv "$test_dir/poll.tmp" "$test_dir/poll.json"
CURL_MODE=401 run_fetch >/dev/null
[ "$(curl_count)" = 1 ]

# Not logged in and no data.
reset_state
rm -f "$config/.credentials.json"
run_fetch | jq -e '.claude.reason == "not_authenticated"' >/dev/null
[ "$(curl_count)" = 0 ]

# A Claude-only refresh updates Claude in the cache and keeps the rest, with its age.
reset_state
login
claude_code_cache $((now - 30))
printf '%s' '{"captured_at":1700000000,"codex":{"status":"ok","entries":[]},"claude":{"status":"error"}}' \
    > "$test_dir/usage.json"
AIQ_PROVIDERS=claude AIQ_CACHE_TTL=999999999 run_fetch | jq -e \
    '.captured_at == 1700000000 and .codex.status == "ok" and .claude.source == "claude-code"' >/dev/null
jq -e '.claude.source == "claude-code" and .codex.status == "ok"' "$test_dir/usage.json" >/dev/null

# The plan comes from Claude Code's current profile, not the login-time credentials.
jq '.oauthAccount += {organizationType: "claude_pro", organizationRateLimitTier: "default_claude_ai"}' \
    "$config/.claude.json" > "$config/claude.tmp" && mv "$config/claude.tmp" "$config/.claude.json"
AIQ_PROVIDERS=claude run_fetch | jq -e '.claude.plan == "Pro"' >/dev/null
jq '.oauthAccount += {organizationType: "claude_max", organizationRateLimitTier: "default_claude_max_20x"}' \
    "$config/.claude.json" > "$config/claude.tmp" && mv "$config/claude.tmp" "$config/.claude.json"
AIQ_PROVIDERS=claude run_fetch | jq -e '.claude.plan == "Max 20x"' >/dev/null

# The status line capture writes a private snapshot.
printf '%s\n' '{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1800000000}}}' | \
    CLAUDE_USAGE_FILE="$test_dir/captured.json" sh "$repo/claude-statusline.sh"
jq -e '.entries == [{"name":"5h","percentUsed":12,"resetAt":1800000000}]' \
    "$test_dir/captured.json" >/dev/null
[ "$(stat -c %a "$test_dir/captured.json")" = "600" ]
