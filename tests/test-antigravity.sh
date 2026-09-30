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
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=1 AIQ_FORCE_REFRESH=1 \
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

run_fetch >/dev/null
if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    cp "$test_dir/result.json" "$AIQ_TEST_ARTIFACT_DIR/antigravity-result.json"
    cp "$requests" "$AIQ_TEST_ARTIFACT_DIR/antigravity-requests.txt"
fi
printf '%s\n' 'Antigravity fetch checks passed.'
