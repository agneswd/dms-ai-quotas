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
        AIQ_COPILOT_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=0 \
        AIQ_FORCE_REFRESH="${1:-0}" \
        CACHE_FILE="$cache" \
        sh "$repo/fetch-usage.sh"
}

run_fetch 0 | jq -e '.marker == "cached"' >/dev/null
run_fetch 1 | jq -e 'has("marker") | not' >/dev/null
[ "$(stat -c %a "$cache")" = "600" ]

# A transient failure keeps the last good result, marked stale with its capture
# time. Failures: a 5xx, a network error, or a parse failure blanks the provider;
# a login error hides behind old data; data older than a day is kept; a window
# whose reset passed still shows its old use.
mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n%s\n' "$KIMI_RESPONSE" "$KIMI_HTTP_CODE"
EOF
chmod +x "$test_dir/bin/curl"
kimi_ok='{"usages":{"limit_5h":{"used_ratio":0.3,"reset_time":"2030-01-01T00:00:00Z"}}}'
run_kimi() {
    env PATH="$test_dir/bin:$PATH" KIMI_RESPONSE="$1" KIMI_HTTP_CODE="$2" KIMI_API_KEY=sk-kimi-test \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_COPILOT_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=1 \
        AIQ_FORCE_REFRESH=1 CACHE_FILE="$cache" sh "$repo/fetch-usage.sh"
}

run_kimi "$kimi_ok" 200 | jq -e '.kimi.status == "ok" and .kimi.stale == null' >/dev/null
good_at=$(jq '.captured_at' "$cache")
for failure in '{} 500' '{} 429' '{} 000' 'not-json 200'; do
    set -- $failure
    run_kimi "$1" "$2" | jq -e --argjson at "$good_at" '
        .kimi.status == "ok" and .kimi.stale == true and .kimi.capturedAt == $at
        and .kimi.entries[0].percentUsed == 30' >/dev/null
done

run_kimi '{}' 401 | jq -e '.kimi.status == "error" and .kimi.reason == "auth_expired"' >/dev/null
run_kimi '{}' 500 | jq -e '.kimi.status == "error"' >/dev/null

run_kimi "$kimi_ok" 200 >/dev/null
jq --argjson old $((now - 90000)) '.captured_at = $old' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
run_kimi '{}' 500 | jq -e '.kimi.status == "error"' >/dev/null

run_kimi "$kimi_ok" 200 >/dev/null
jq --argjson past $((now - 10)) '.kimi.entries[0].resetAt = $past' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
run_kimi '{}' 500 | jq -e '.kimi.stale == true and .kimi.entries[0] == {name: "5h", percentUsed: 0, resetAt: 0}' >/dev/null
printf '%s\n' 'Cache checks passed.'
