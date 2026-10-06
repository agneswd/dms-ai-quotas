#!/bin/sh
set -eu

# Exercise every provider with fixture credentials before changing transport.
# Failures: secrets in arguments, incorrect headers, public temp files, stale
# credential files, and missing credentials after a provider changes transport.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/claude" "$test_dir/codex" "$test_dir/grok" "$test_dir/tmp"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"fixture-secret-claude"}}' > "$test_dir/claude/.credentials.json"
printf '%s\n' '{"tokens":{"access_token":"fixture-secret-codex","account_id":"fixture-account"}}' > "$test_dir/codex/auth.json"
printf '%s\n' '{"account":{"key":"fixture-secret-grok"}}' > "$test_dir/grok/auth.json"

cat > "$test_dir/bin/secret-tool" <<'EOF'
#!/bin/sh
printf '%s\n' '{"token":{"access_token":"fixture-secret-antigravity","expiry":"2030-01-01T00:00:00Z"}}'
EOF
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$@" >> "$AIQ_TEST_REQUESTS"
if printf '%s\n' "$@" | grep -Eq 'fixture-secret-|fixture-account'; then
    exit 99
fi
header_file=""
for arg in "$@"; do
    case "$arg" in
        @*) header_file=${arg#@} ;;
    esac
done
test -n "$header_file"
test "$(stat -c %a "$header_file")" = 600
for arg in "$@"; do
    case "$arg" in
        *api.anthropic.com*) provider=claude; body='{"five_hour":{"utilization":10}}' ;;
        *chatgpt.com*) provider=codex; body='{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":10,"reset_at":1893456000}}}'; grep -Fq 'ChatGPT-Account-Id: fixture-account' "$header_file" ;;
        *opencode.ai*) provider=opencode; body='{"usage":{"rolling":{"percent":10}}}' ;;
        *api.deepseek.com*) provider=deepseek; body='{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"10","granted_balance":"0","topped_up_balance":"10"}]}' ;;
        *openrouter.ai*) provider=openrouter; body='{"data":{"total_credits":20,"total_usage":10}}' ;;
        *cli-chat-proxy.grok.com*) provider=grok; body='{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2030-01-01T00:00:00Z"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0}}}' ;;
        *v1internal:loadCodeAssist*) provider=antigravity; body='{"cloudaicompanionProject":"fixture-project"}' ;;
        *v1internal:retrieveUserQuotaSummary*) provider=antigravity; body='{"groups":[]}' ;;
    esac
done
grep -Fqx "Authorization: Bearer fixture-secret-$provider" "$header_file"
printf '%s\n' "$provider" >> "$AIQ_TEST_PROVIDERS"
printf '%s' "$body"
printf '\n200\n'
EOF
chmod +x "$test_dir/bin/curl" "$test_dir/bin/secret-tool"

env PATH="$test_dir/bin:$PATH" TMPDIR="$test_dir/tmp" \
    XDG_CACHE_HOME="$test_dir/cache" CLAUDE_CONFIG_DIR="$test_dir/claude" \
    CODEX_HOME="$test_dir/codex" GROK_HOME="$test_dir/grok" \
    AIQ_TEST_REQUESTS="$test_dir/requests.txt" AIQ_TEST_PROVIDERS="$test_dir/providers.txt" \
    AIQ_CLAUDE_ENABLED=1 AIQ_CODEX_ENABLED=1 AIQ_OPENCODE_ENABLED=1 \
    AIQ_DEEPSEEK_ENABLED=1 AIQ_OPENROUTER_ENABLED=1 AIQ_GROK_ENABLED=1 \
    AIQ_ANTIGRAVITY_ENABLED=1 AIQ_FORCE_REFRESH=1 \
    OPENCODE_GO_API_KEY=fixture-secret-opencode DEEPSEEK_API_KEY=fixture-secret-deepseek \
    OPENROUTER_API_KEY=fixture-secret-openrouter \
    sh "$repo/fetch-usage.sh" > "$test_dir/result.json"

jq -e '[.claude,.codex,.opencode,.deepseek,.openrouter,.grok,.antigravity] | all(.status == "ok")' "$test_dir/result.json" >/dev/null
test "$(sort -u "$test_dir/providers.txt" | wc -l)" -eq 7
test -z "$(find "$test_dir/tmp" -mindepth 1 -print -quit)"
if grep -rEq 'fixture-secret-|fixture-account' "$test_dir/cache"; then
    printf '%s\n' 'Credentials were written to the cache.' >&2
    exit 1
fi
if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    cp "$test_dir/result.json" "$AIQ_TEST_ARTIFACT_DIR/credentials-result.json"
    cp "$test_dir/requests.txt" "$AIQ_TEST_ARTIFACT_DIR/credentials-requests.txt"
fi
printf '%s\n' 'Provider credential transport checks passed.'
