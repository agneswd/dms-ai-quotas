#!/bin/sh
set -eu

# Exercise the complete fetch command with isolated keyring and provider responses.
# Failures: missing/expired tokens, denied requests, network errors, malformed data,
# token disclosure in arguments or cache files, and requests to refresh credentials.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/cache"

cat > "$test_dir/bin/secret-tool" <<'EOF'
#!/bin/sh
cat "$AIQ_TEST_KEYRING"
EOF
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$AIQ_TEST_REQUESTS"
project_body='{"cloudaicompanionProject":"test-project","paidTier":{"name":"Pro"}}'
quota_body='{"groups":[{"displayName":"Claude","buckets":[{"displayName":"Usage","remainingFraction":0.75,"resetTime":"2030-01-01T00:00:00Z"}]}]}'
case "$*" in
    *oauth2.googleapis.com*) exit 99 ;;
    *v1internal:loadCodeAssist*)
        printf '%s\n%s\n' "${AIQ_TEST_PROJECT_BODY:-$project_body}" "${AIQ_TEST_PROJECT_HTTP:-200}"
        ;;
    *v1internal:retrieveUserQuotaSummary*)
        printf '%s\n%s\n' "${AIQ_TEST_QUOTA_BODY:-$quota_body}" "${AIQ_TEST_QUOTA_HTTP:-200}"
        ;;
    *) exit 99 ;;
esac
EOF
chmod +x "$test_dir/bin/secret-tool" "$test_dir/bin/curl"

keyring="$test_dir/keyring.json"
requests="$test_dir/requests.txt"
set_token() {
    jq -n --arg expiry "$1" '{account:"test@example.invalid",token:{access_token:"fixture-access-token",refresh_token:"fixture-refresh-token",expiry:$expiry}}' > "$keyring"
}
run_fetch() {
    : > "$requests"
    env PATH="$test_dir/bin:$PATH" \
        XDG_CACHE_HOME="$test_dir/cache" \
        AIQ_TEST_KEYRING="$keyring" AIQ_TEST_REQUESTS="$requests" \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_COPILOT_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=1 AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=0 AIQ_FORCE_REFRESH=1 \
        sh "$repo/fetch-usage.sh" > "$test_dir/result.json"
    cat "$test_dir/result.json"
}

for expiry in 2030-01-01T00:00:00Z 1893456000 1893456000000; do
    set_token "$expiry"
    run_fetch | jq -e '.antigravity.status == "ok" and .antigravity.plan == "Pro" and .antigravity.entries == [{name:"Claude - Usage",percentUsed:25,resetAt:1893456000}]' >/dev/null
    if grep -Eq 'fixture-access-token|fixture-refresh-token|antigravity/cli|oauth2.googleapis.com' "$requests"; then
        printf '%s\n' 'Unexpected credential handling in Antigravity requests.' >&2
        exit 1
    fi
    if grep -rEq 'fixture-access-token|fixture-refresh-token' "$test_dir/cache"; then
        printf '%s\n' 'Antigravity credentials were written to the cache.' >&2
        exit 1
    fi
done

for expiry in 2000-01-01T00:00:00Z invalid ''; do
    set_token "$expiry"
    run_fetch | jq -e '.antigravity.reason == "auth_expired"' >/dev/null
    [ ! -s "$requests" ]
done

printf '%s\n' '{}' > "$keyring"
run_fetch | jq -e '.antigravity.reason == "not_authenticated"' >/dev/null
[ ! -s "$requests" ]

set_token 2030-01-01T00:00:00Z
AIQ_TEST_PROJECT_HTTP=401 run_fetch | jq -e '.antigravity.reason == "auth_expired"' >/dev/null
AIQ_TEST_QUOTA_HTTP=403 run_fetch | jq -e '.antigravity.reason == "access_denied"' >/dev/null
AIQ_TEST_QUOTA_HTTP=000 run_fetch | jq -e '.antigravity.reason == "network"' >/dev/null
AIQ_TEST_PROJECT_BODY=invalid run_fetch | jq -e '.antigravity.status == "error"' >/dev/null
AIQ_TEST_QUOTA_BODY=invalid run_fetch | jq -e '.antigravity.status == "error"' >/dev/null

AIQ_TEST_PROJECT_BODY='{"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}' \
    run_fetch | jq -e '.antigravity.status == "error" and .antigravity.reason == "unsupported_client" and (.antigravity.error | contains("antigravity-statusline.sh"))' >/dev/null

# Status line capture writes a private snapshot with empty stdout and skips disabled buckets.
native_file="$test_dir/antigravity-native.json"
now=$(date +%s)
stdout_capture=$(printf '%s\n' '{
    "email": "developer@example.invalid",
    "plan_tier": "Pro",
    "quota": {
        "claude-5h": {"remaining_fraction": 0.45, "reset_time": "2030-01-01T00:00:00Z"},
        "gemini-weekly": {"remaining_fraction": 0.9378, "reset_time": "2030-01-02T00:00:00.5+00:00"},
        "gemini-5h": {"remaining_fraction": 0.8, "reset_in_seconds": 3600},
        "disabled-bucket": {"remaining_fraction": 0.1, "disabled": true},
        "credits-only": {"remaining_amount": 50}
    }
}' | ANTIGRAVITY_USAGE_FILE="$native_file" sh "$repo/antigravity-statusline.sh")
[ -z "$stdout_capture" ]
[ "$(stat -c %a "$native_file")" = "600" ]
jq -e --argjson now "$now" '
    .email == "developer@example.invalid"
    and .plan == "Pro"
    and (.entries | length) == 3
    and .entries[0].name == "Gemini Models - 5 hour usage limit"
    and .entries[0].percentUsed == 20
    and .entries[0].resetAt >= ($now + 3595)
    and .entries[1] == {name: "Gemini Models - Weekly usage limit", percentUsed: 6.22, resetAt: 1893542400}
    and .entries[2] == {name: "Claude Models - 5 hour usage limit", percentUsed: 55, resetAt: 1893456000}
' "$native_file" >/dev/null

# Empty or malformed statusLine input exits 0 and preserves the previous snapshot.
printf '%s\n' '{"agent_state":"idle"}' | ANTIGRAVITY_USAGE_FILE="$native_file" sh "$repo/antigravity-statusline.sh"
printf '%s\n' 'not-json' | ANTIGRAVITY_USAGE_FILE="$native_file" sh "$repo/antigravity-statusline.sh"
jq -e '(.entries | length) == 3' "$native_file" >/dev/null

# Native snapshot takes precedence without calling curl, and expired windows roll over to 0%.
printf '%s\n' '{}' > "$keyring"
jq --argjson past $((now - 60)) '.entries[0].resetAt = $past' "$native_file" > "$native_file.tmp" && mv "$native_file.tmp" "$native_file"
ANTIGRAVITY_USAGE_FILE="$native_file" run_fetch | jq -e '
    .antigravity.status == "ok"
    and .antigravity.source == "native"
    and .antigravity.plan == "Pro"
    and .antigravity.email == "developer@example.invalid"
    and .antigravity.entries[0] == {name: "Gemini Models - 5 hour usage limit", percentUsed: 0, resetAt: 0}
    and .antigravity.entries[1] == {name: "Gemini Models - Weekly usage limit", percentUsed: 6.22, resetAt: 1893542400}
' >/dev/null
[ ! -s "$requests" ]

set_token 2030-01-01T00:00:00Z
run_fetch >/dev/null
if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    cp "$test_dir/result.json" "$AIQ_TEST_ARTIFACT_DIR/antigravity-result.json"
    cp "$requests" "$AIQ_TEST_ARTIFACT_DIR/antigravity-requests.txt"
fi
printf '%s\n' 'Antigravity fetch checks passed.'
