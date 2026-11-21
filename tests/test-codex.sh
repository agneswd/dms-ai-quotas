#!/bin/sh
set -eu

# Exercise the complete fetch command with an isolated CODEX_HOME and a stub API.
# Failures: a 30-day window named "Weekly", an API call on every refresh, a forced
# refresh that skips the API, an older session file winning over a newer API answer,
# a model-specific limit or a malformed line hiding the main limit, an expired
# window shown as used, another account's state reused, and the account ID or
# token written to the cache.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
codex_home="$test_dir/codex"
sessions="$codex_home/sessions/2030/01/01"
mkdir -p "$test_dir/bin" "$sessions"
requests="$test_dir/requests.txt"
: > "$requests"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AIQ_TEST_REQUESTS"
printf '%s\n%s\n' "$WHAM_BODY" "${WHAM_HTTP:-200}"
EOF
chmod +x "$test_dir/bin/curl"

set_account() {
    jq -n --arg id "$1" '{tokens: {access_token: "fixture-codex-token", account_id: $id}}' > "$codex_home/auth.json"
}
calls() { wc -l < "$requests" | tr -d ' '; }
run_fetch() {
    env PATH="$test_dir/bin:$PATH" CODEX_HOME="$codex_home" XDG_CACHE_HOME="$test_dir/cache" \
        AIQ_TEST_REQUESTS="$requests" WHAM_BODY="$WHAM_BODY" WHAM_HTTP="${WHAM_HTTP:-200}" \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=1 AIQ_COPILOT_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=0 \
        AIQ_CACHE_TTL=0 AIQ_FORCE_REFRESH="${1:-0}" sh "$repo/fetch-usage.sh" > "$test_dir/result.json"
    cat "$test_dir/result.json"
}
# One token_count event line as Codex writes it.
event() {
    jq -cn --arg ts "$1" --argjson limits "$2" \
        '{timestamp: $ts, type: "event_msg", payload: {type: "token_count", rate_limits: $limits}}'
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z; }
now=$(date +%s)

# Free plan: one 30-day window.
set_account fixture-account
WHAM_BODY='{"plan_type":"free","rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":2592000,"reset_at":1893456000},"secondary_window":null},"credits":null}'
run_fetch | jq -e '.codex.status == "ok" and .codex.plan == "free" and .codex.source == "api"
    and .codex.entries == [{name: "Monthly", percentUsed: 3, resetAt: 1893456000}]' >/dev/null
test "$(calls)" = 1

# Paid plan, with a code review window and a monthly credit limit.
WHAM_BODY='{"plan_type":"pro","rate_limit":{
    "primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":600},
    "secondary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_at":1893456000}},
    "code_review_rate_limit":{"primary_window":{"used_percent":7,"reset_at":1893456000}},
    "spend_control":{"individual_limit":{"remaining_percent":75,"resets_at":1893456000}},
    "credits":{"has_credits":true,"unlimited":false,"balance":"12"}}'
run_fetch 1 | jq -e --argjson now "$now" '.codex.entries[0].name == "5h" and .codex.entries[0].percentUsed == 20
    and (.codex.entries[0].resetAt - $now - 600 | fabs) < 5
    and .codex.entries[1:] == [
        {name: "Weekly", percentUsed: 5, resetAt: 1893456000},
        {name: "Code Review", percentUsed: 7, resetAt: 1893456000},
        {name: "Credits", percentUsed: 25, resetAt: 1893456000}]
    and .codex.credits.balance == "12"' >/dev/null
test "$(calls)" = 2

# Within a minute, an unforced refresh reuses the stored answer.
run_fetch | jq -e '.codex.status == "ok" and .codex.source == "api" and .codex.entries[1].percentUsed == 5' >/dev/null
test "$(calls)" = 2

# A newer session file replaces the API windows by name and keeps the others. The newest
# rate_limits line is model-specific and the one before it is malformed; both are skipped.
api_at=$(jq '.captured_at' "$test_dir/cache/dms-ai-quotas/codex-api.json")
session="$sessions/rollout-2030-01-01T00-00-00-test.jsonl"
{
    event "$(iso "$api_at")" '{"limit_id":"codex","primary":{"used_percent":40,"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":10,"window_minutes":10080,"resets_at":1893456000},"plan_type":"pro"}'
    printf '%s\n' '{"timestamp":"broken","payload":{"rate_limits":{'
    event "$(iso "$api_at")" '{"limit_id":"codex-mini","primary":{"used_percent":99,"window_minutes":300,"resets_at":1893456000}}'
    event "$(iso "$api_at")" 'null'
} > "$session"
# The event time must be after the API answer to win.
sed -i "s/$(iso "$api_at")/$(iso $((api_at + 5)))/g" "$session"
touch -d "@$((api_at + 5))" "$session"
run_fetch | jq -e '.codex.source == "local" and .codex.plan == "pro" and .codex.credits.balance == "12"
    and [.codex.entries[] | {name, percentUsed}] == [
        {name: "5h", percentUsed: 40}, {name: "Weekly", percentUsed: 10},
        {name: "Code Review", percentUsed: 7}, {name: "Credits", percentUsed: 25}]' >/dev/null
test "$(calls)" = 2

# A local window whose reset passed shows as unused.
event "$(iso $((api_at + 6)))" "{\"primary\":{\"used_percent\":90,\"window_minutes\":300,\"resets_at\":$((now - 10))}}" >> "$session"
touch -d "@$((api_at + 6))" "$session"
run_fetch | jq -e '.codex.entries[0] == {name: "5h", percentUsed: 0, resetAt: 0}' >/dev/null

# A session file older than the API answer is ignored.
touch -d "@$((api_at - 100))" "$session"
run_fetch 1 | jq -e '.codex.source == "api" and .codex.entries[0].percentUsed == 20' >/dev/null
test "$(calls)" = 3

# Another account does not reuse the stored answer, even within a minute.
set_account other-account
run_fetch >/dev/null
test "$(calls)" = 4

# A failed request keeps the last good result, marked stale.
WHAM_HTTP=500 run_fetch 1 | jq -e '.codex.status == "ok" and .codex.stale == true' >/dev/null
WHAM_HTTP=401 run_fetch 1 | jq -e '.codex.status == "error" and .codex.reason == "auth_expired"' >/dev/null

rm "$codex_home/auth.json"
run_fetch | jq -e '.codex.status == "unavailable" and .codex.reason == "not_authenticated"' >/dev/null

if grep -rEq 'fixture-codex-token|fixture-account|other-account' "$test_dir/cache"; then
    printf '%s\n' 'Codex credentials were written to the cache.' >&2
    exit 1
fi
if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    cp "$test_dir/result.json" "$AIQ_TEST_ARTIFACT_DIR/codex-result.json"
fi
printf '%s\n' 'Codex fetch checks passed.'
