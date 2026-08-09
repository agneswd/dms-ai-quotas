#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cache="$test_dir/usage.json"
now=$(date +%s)
printf '{"captured_at":%s,"marker":"cached"}\n' "$now" > "$cache"

run_fetch() {
    env \
        AIQ_CLAUDE_ENABLED=0 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_FORCE_REFRESH="${1:-0}" \
        CACHE_FILE="$cache" \
        sh "$repo/fetch-usage.sh"
}

run_fetch 0 | jq -e '.marker == "cached"' >/dev/null
run_fetch 1 | jq -e 'has("marker") | not' >/dev/null
[ "$(stat -c %a "$cache")" = "600" ]
