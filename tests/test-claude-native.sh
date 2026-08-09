#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/claude"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test","subscriptionType":"pro"}}' \
    > "$test_dir/claude/.credentials.json"

run_fetch() {
    env \
        AIQ_CLAUDE_ENABLED=1 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_CACHE_TTL=0 \
        CLAUDE_CONFIG_DIR="$test_dir/claude" \
        CLAUDE_USAGE_FILE="$test_dir/claude-usage.json" \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

now=$(date +%s)
jq -n --argjson now "$now" \
    '{captured_at:$now,entries:[{name:"5h",percentUsed:10,resetAt:1800000000}]}' \
    > "$test_dir/claude-usage.json"
run_fetch | jq -e \
    '.claude.source == "native" and .claude.stale == false and .claude.capturedAt == $now' \
    --argjson now "$now" >/dev/null

stale=$((now - 601))
jq -n --argjson stale "$stale" \
    '{captured_at:$stale,entries:[{name:"Weekly",percentUsed:20,resetAt:1800000000}]}' \
    > "$test_dir/claude-usage.json"
run_fetch | jq -e '.claude.stale == true and .claude.capturedAt == $stale' \
    --argjson stale "$stale" >/dev/null

rm -f "$test_dir/claude-usage.json"
run_fetch | jq -e '.claude.reason == "usage_pending"' >/dev/null
rm -f "$test_dir/claude/.credentials.json"
run_fetch | jq -e '.claude.reason == "not_authenticated"' >/dev/null

printf '%s\n' '{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1800000000}}}' | \
    CLAUDE_USAGE_FILE="$test_dir/captured.json" sh "$repo/claude-statusline.sh"
jq -e '.entries == [{"name":"5h","percentUsed":12,"resetAt":1800000000}]' \
    "$test_dir/captured.json" >/dev/null
