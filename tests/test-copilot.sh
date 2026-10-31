#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/tmp"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
for arg in "$@"; do
    case "$arg" in
        @*)
            cp "${arg#@}" "$COPILOT_SENT_HEADERS"
            stat -c %a "${arg#@}" > "$COPILOT_HEADER_MODE"
            ;;
        *api.github.com/copilot_internal/user*) : ;;
    esac
done
printf '%s\n%s\n' "$COPILOT_RESPONSE" "${COPILOT_HTTP_CODE:-200}"
EOF
cat > "$test_dir/bin/gh" <<'EOF'
#!/bin/sh
test "$1 $2" = "auth token"
printf '%s' "${COPILOT_GH_TOKEN:-}"
EOF
chmod +x "$test_dir/bin/curl" "$test_dir/bin/gh"

run_fetch() {
    env PATH="$test_dir/bin:$PATH" TMPDIR="$test_dir/tmp" \
        COPILOT_RESPONSE="$1" COPILOT_HTTP_CODE="${2:-200}" \
        COPILOT_SENT_HEADERS="$test_dir/headers" COPILOT_HEADER_MODE="$test_dir/header-mode" \
        COPILOT_GITHUB_TOKEN="${COPILOT_GITHUB_TOKEN:-}" COPILOT_GH_TOKEN="${COPILOT_GH_TOKEN:-}" \
        GH_TOKEN= GITHUB_TOKEN= \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_COPILOT_ENABLED=1 \
        AIQ_OPENCODE_ENABLED=0 AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 AIQ_CACHE_TTL=0 AIQ_FORCE_REFRESH=1 \
        CACHE_FILE="$test_dir/usage.json" sh "$repo/fetch-usage.sh"
}

body='{"copilot_plan":"individual","quota_reset_date":"2030-01-01","quota_snapshots":{"premium_interactions":{"percent_remaining":85},"chat":{"entitlement":100,"remaining":50},"completions":{"has_quota":false}}}'
COPILOT_GITHUB_TOKEN=fixture-copilot-token run_fetch "$body" | jq -e \
    '.copilot.status == "ok"
     and .copilot.plan == "individual"
     and .copilot.entries == [
       {"name":"Premium Requests","percentUsed":15,"resetAt":1893456000},
       {"name":"Chat","percentUsed":50,"resetAt":1893456000}
     ]' >/dev/null
grep -Fqx 'Authorization: token fixture-copilot-token' "$test_dir/headers"
grep -Fqx 'Editor-Version: vscode/1.96.2' "$test_dir/headers"
test "$(cat "$test_dir/header-mode")" = 600

# `gh auth token` is used when no explicit Copilot/GitHub token was provided.
COPILOT_GH_TOKEN=fixture-gh-token run_fetch '{"quota_snapshots":{"premium_interactions":{"percent_remaining":0}}}' \
    | jq -e '.copilot.status == "ok" and .copilot.entries[0].percentUsed == 100' >/dev/null
grep -Fqx 'Authorization: token fixture-gh-token' "$test_dir/headers"

COPILOT_GITHUB_TOKEN=fixture-copilot-token run_fetch '{}' 401 | jq -e '.copilot.status == "error" and .copilot.reason == "auth_expired"' >/dev/null
COPILOT_GITHUB_TOKEN=fixture-copilot-token run_fetch '{}' 403 | jq -e '.copilot.status == "error" and .copilot.reason == "access_denied"' >/dev/null
COPILOT_GITHUB_TOKEN=fixture-copilot-token run_fetch '{"quota_snapshots":{"premium_interactions":{"has_quota":false}}}' \
    | jq -e '.copilot.status == "unavailable" and .copilot.reason == "no_quota"' >/dev/null
run_fetch '{}' | jq -e '.copilot.status == "unavailable" and .copilot.reason == "not_authenticated"' >/dev/null

printf '%s\n' 'GitHub Copilot fetch checks passed.'
