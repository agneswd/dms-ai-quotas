#!/bin/sh
set -eu

# Exercise the complete fetch command with an isolated HOME, keyring, and stub hosts.
# Failures: a request without the agy User-Agent, the prod host's untouched value
# winning over the daily host, a bucket only one host has dropped, a disabled bucket
# shown, a rolling reset on an untouched bucket shown as real, unclear names, an
# expired keyring token sent, a T3 Code sign-in not renewed or its project left out,
# an API call on every refresh, a forced refresh that skips the API, one failed host
# failing the result, a stale snapshot winning over a newer API answer, and tokens
# or client secrets in process arguments or the cache.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
home="$test_dir/home"
mkdir -p "$test_dir/bin" "$home"
requests="$test_dir/requests.txt"
: > "$requests"

cat > "$test_dir/bin/secret-tool" <<'EOF'
#!/bin/sh
cat "$AIQ_TEST_KEYRING" 2>/dev/null
EOF
# Logs each request: its arguments, then the header and body files it reads.
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf 'ARGS %s\n' "$*" >> "$AIQ_TEST_REQUESTS"
for arg in "$@"; do
    case "$arg" in @*) printf 'FILE %s\n' "$(tr '\n' ' ' < "${arg#@}")" >> "$AIQ_TEST_REQUESTS" ;; esac
done
case "$*" in
    *oauth2.googleapis.com/token*) printf '%s\n%s\n' '{"access_token":"fixture-renewed-token","expires_in":3600}' "${REFRESH_HTTP:-200}" ;;
    *daily-cloudcode-pa*) printf '%s\n%s\n' "$DAILY_BODY" "${DAILY_HTTP:-200}" ;;
    *cloudcode-pa*) printf '%s\n%s\n' "$PROD_BODY" "${PROD_HTTP:-200}" ;;
    *) exit 99 ;;
esac
EOF
chmod +x "$test_dir/bin/secret-tool" "$test_dir/bin/curl"

now=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
keyring="$test_dir/keyring.json"
set_keyring() {
    jq -n --arg expiry "$1" '{auth_method: "consumer", token: {access_token: "fixture-keyring-token", refresh_token: "fixture-keyring-refresh", expiry: $expiry}}' > "$keyring"
}
calls() { grep -c '^ARGS' "$requests" || true; }
run_fetch() {
    env PATH="$test_dir/bin:$PATH" HOME="$home" XDG_CACHE_HOME="$home/.cache" \
        AIQ_TEST_REQUESTS="$requests" AIQ_TEST_KEYRING="$keyring" \
        DAILY_BODY="$DAILY_BODY" PROD_BODY="$PROD_BODY" \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_COPILOT_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 AIQ_MISTRAL_ENABLED=0 AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=1 AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=0 \
        AIQ_CACHE_TTL=0 AIQ_FORCE_REFRESH="${1:-0}" sh "$repo/fetch-usage.sh" > "$test_dir/result.json"
    cat "$test_dir/result.json"
}

# The daily host meters the account. The prod host reports the same buckets untouched,
# with a rolling reset one window ahead, and has one bucket the daily host lacks.
DAILY_BODY=$(jq -cn --arg r5 "$(iso 1893456000)" --arg rw "$(iso 1894060800)" '{groups: [
    {displayName: "Gemini Models", buckets: [
        {bucketId: "gemini-weekly", window: "weekly", remainingFraction: 0.97, resetTime: $rw, description: "used some"},
        {bucketId: "gemini-5h", window: "5h", remainingFraction: 0.9, resetTime: $r5, description: "used some"}]},
    {displayName: "Gemini 4 Argon", buckets: [
        {bucketId: "gemini-argon-wtu-weekly", window: "weekly", remainingFraction: 0.5, resetTime: $rw}]},
    {displayName: "Hidden", buckets: [{bucketId: "x-5h", window: "5h", remainingFraction: 0.1, disabled: true}]}]}')
PROD_BODY=$(jq -cn --arg r5 "$(iso $((now + 18000)))" --arg rw "$(iso $((now + 604800)))" '{groups: [
    {displayName: "Gemini Models", buckets: [
        {bucketId: "gemini-5h", window: "5h", remainingFraction: 1, resetTime: $r5}]},
    {displayName: "Claude and GPT models", buckets: [
        {bucketId: "3p-weekly", window: "weekly", remainingFraction: 1, resetTime: $rw},
        {bucketId: "3p-5h", window: "5h", remainingFraction: 1, resetTime: $r5}]}]}')

# No sign-in at all.
run_fetch | jq -e '.antigravity.status == "unavailable" and .antigravity.reason == "not_authenticated"' >/dev/null

# A valid keyring token: both hosts, the agy User-Agent, daily values first.
set_keyring "$(iso $((now + 3000)))"
run_fetch 1 | jq -e '.antigravity.status == "ok" and .antigravity.source == "api"
    and .antigravity.entries == [
        {name: "Gemini - 5 hour limit", percentUsed: 10, resetAt: 1893456000},
        {name: "Gemini - Weekly limit", percentUsed: 3, resetAt: 1894060800},
        {name: "Gemini Argon - Weekly limit", percentUsed: 50, resetAt: 1894060800},
        {name: "Claude & GPT - 5 hour limit", percentUsed: 0, resetAt: 0},
        {name: "Claude & GPT - Weekly limit", percentUsed: 0, resetAt: 0}]' >/dev/null
test "$(calls)" = 2
test "$(grep -c 'User-Agent: antigravity/hub/' "$requests")" = 2
grep -q 'FILE Authorization: Bearer fixture-keyring-token' "$requests"
grep '^ARGS.*cloudcode-pa' "$requests" | grep -q -- '--data {}'

# Within a minute, an unforced refresh reuses the stored answer.
run_fetch | jq -e '.antigravity.status == "ok" and (.antigravity.entries | length) == 5' >/dev/null
test "$(calls)" = 2

# One failed host still gives a result.
DAILY_HTTP=503 run_fetch 1 | jq -e '.antigravity.status == "ok" and .antigravity.entries[0].name == "Gemini - 5 hour limit"' >/dev/null

# An expired keyring token is not sent. A T3 Code sign-in is renewed and its project sent.
set_keyring "$(iso $((now - 60)))"
t3_dir="$home/.t3/userdata/providers/antigravity/abc/antigravity-acp"
mkdir -p "$t3_dir"
printf '%s\n' '{"client_id":"fixture-client","client_secret":"fixture-client-secret","refresh_token":"fixture-t3-refresh","project_id":"fixture-project"}' > "$t3_dir/acp_token.json"
: > "$requests"
run_fetch 1 | jq -e '.antigravity.status == "ok"' >/dev/null
grep -q 'FILE client_id=fixture-client&client_secret=fixture-client-secret&refresh_token=fixture-t3-refresh&grant_type=refresh_token' "$requests"
test "$(grep -c 'FILE Authorization: Bearer fixture-renewed-token' "$requests")" = 2
if grep -q 'fixture-keyring-token' "$requests"; then exit 1; fi
grep -q -- '--data {"project":"fixture-project"}' "$requests"

# Login and access errors show.
REFRESH_HTTP=400 run_fetch 1 | jq -e '.antigravity.reason == "not_authenticated"' >/dev/null
DAILY_HTTP=401 PROD_HTTP=401 run_fetch 1 | jq -e '.antigravity.reason == "auth_expired"' >/dev/null
DAILY_HTTP=403 PROD_HTTP=403 run_fetch 1 | jq -e '.antigravity.reason == "access_denied"' >/dev/null
run_fetch 1 >/dev/null

# Status line capture writes a private snapshot with empty stdout and skips disabled buckets.
native_file="$home/.cache/dms-ai-quotas/antigravity-native.json"
capture() { ANTIGRAVITY_USAGE_FILE="$native_file" sh "$repo/antigravity-statusline.sh"; }
stdout_capture=$(printf '%s\n' '{
    "email": "developer@example.invalid",
    "plan_tier": "Pro",
    "quota": {
        "3p-5h": {"remaining_fraction": 0.45, "reset_time": "2030-01-01T00:00:00Z"},
        "gemini-weekly": {"remaining_fraction": "0.9378", "reset_time": "2030-01-02T00:00:00.5+00:00"},
        "gemini-5h": {"remaining_fraction": 0.8, "reset_in_seconds": 3600},
        "disabled-5h": {"remaining_fraction": 0.1, "disabled": true},
        "credits-only": {"remaining_amount": 50}
    }
}' | capture)
[ -z "$stdout_capture" ]
[ "$(stat -c %a "$native_file")" = "600" ]
jq -e '(.buckets | length) == 3 and .plan == "Pro"' "$native_file" >/dev/null

# Empty or malformed status line input keeps the previous snapshot.
printf '%s\n' '{"agent_state":"idle"}' | capture
printf '%s\n' 'not-json' | capture
jq -e '(.buckets | length) == 3' "$native_file" >/dev/null

# A snapshot newer than the API answer wins, with the same names. An expired window shows as unused.
jq --argjson t $((now + 5)) '.captured_at = $t | .buckets[0].resetAt = 1' "$native_file" > "$native_file.tmp" && mv "$native_file.tmp" "$native_file"
run_fetch | jq -e --argjson now "$now" '.antigravity.source == "native" and .antigravity.stale == false
    and .antigravity.plan == "Pro" and .antigravity.email == "developer@example.invalid"
    and [.antigravity.entries[] | {name, percentUsed}] == [
        {name: "Gemini - 5 hour limit", percentUsed: 20},
        {name: "Gemini - Weekly limit", percentUsed: 6},
        {name: "Claude & GPT - 5 hour limit", percentUsed: 0}]
    and .antigravity.entries[2].resetAt == 0' >/dev/null

# An older snapshot loses to the API answer.
jq --argjson t $((now - 600)) '.captured_at = $t' "$native_file" > "$native_file.tmp" && mv "$native_file.tmp" "$native_file"
run_fetch 1 | jq -e '.antigravity.source == "api"' >/dev/null

# Without any sign-in, an old snapshot is still shown, marked stale.
rm -f "$keyring" "$t3_dir/acp_token.json"
jq --argjson t $((now - 7200)) '.captured_at = $t' "$native_file" > "$native_file.tmp" && mv "$native_file.tmp" "$native_file"
rm -f "$home/.cache/dms-ai-quotas/antigravity-api.json"
run_fetch | jq -e '.antigravity.status == "ok" and .antigravity.source == "native" and .antigravity.stale == true' >/dev/null

if grep '^ARGS' "$requests" | grep -Eq 'fixture-(keyring|renewed|t3|client)'; then
    printf '%s\n' 'Antigravity credentials were passed as process arguments.' >&2
    exit 1
fi
if grep -rEq 'fixture-(keyring|renewed|t3|client)' "$home/.cache"; then
    printf '%s\n' 'Antigravity credentials were written to the cache.' >&2
    exit 1
fi
if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    cp "$test_dir/result.json" "$AIQ_TEST_ARTIFACT_DIR/antigravity-result.json"
fi
printf '%s\n' 'Antigravity fetch checks passed.'
