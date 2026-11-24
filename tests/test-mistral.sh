#!/bin/sh
set -eu

# Run the full fetch command against fake Mistral billing responses.
# Failures: wrong budget parsing or clamping, zero-budget pools shown, plan
# mapping wrong, subscription failure breaking the budget result, Vibe .env or
# keyring fallback broken, OIDC marker sent as a key, or credentials leaked.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/home"
requests="$test_dir/requests.txt"
lookups="$test_dir/lookups.txt"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$AIQ_TEST_REQUESTS"
for arg in "$@"; do
    case "$arg" in @*) sed -n 's/^Authorization: Bearer //p' "${arg#@}" >> "$AIQ_TEST_REQUESTS" ;; esac
done
case "$*" in
    *api.mistral.ai/v1/billing/budget*)
        printf '%s\n%s\n' "$MISTRAL_BUDGET_BODY" "${MISTRAL_BUDGET_HTTP:-200}"
        ;;
    *api.mistral.ai/v1/billing/subscription*)
        printf '%s\n%s\n' "$MISTRAL_SUB_BODY" "${MISTRAL_SUB_HTTP:-200}"
        ;;
    *)
        exit 99
        ;;
esac
EOF

cat > "$test_dir/bin/secret-tool" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AIQ_TEST_LOOKUPS"
if [ "$1" = "lookup" ] && [ "$2" = "service" ] && [ "$3" = "${MISTRAL_KEYRING_SVC:-ai.mistral.vibe}" ] && [ "$4" = "username" ] && [ "$5" = "MISTRAL_API_KEY" ]; then
    printf '%s' "${MISTRAL_KEYRING_VAL:-}"
fi
EOF
chmod +x "$test_dir/bin/curl" "$test_dir/bin/secret-tool"

default_sub='{"plan_name":"INDIVIDUAL","payg_enabled":false,"vibe_payg_enabled":false,"enterprise":false}'

run_fetch() {
    : > "$requests"
    : > "$lookups"
    env -u AIQ_VAULT_MISTRAL \
        PATH="$test_dir/bin:$PATH" HOME="$test_dir/home" \
        VIBE_HOME="${VIBE_HOME:-$test_dir/home/.vibe}" \
        AIQ_TEST_REQUESTS="$requests" AIQ_TEST_LOOKUPS="$lookups" \
        MISTRAL_BUDGET_BODY="$1" \
        MISTRAL_BUDGET_HTTP="${2:-200}" \
        MISTRAL_SUB_BODY="${MISTRAL_SUB_BODY-$default_sub}" \
        MISTRAL_SUB_HTTP="${MISTRAL_SUB_HTTP:-200}" \
        MISTRAL_API_KEY="${MISTRAL_API_KEY-mistral-test-key}" \
        MISTRAL_KEYRING_SVC="${MISTRAL_KEYRING_SVC:-ai.mistral.vibe}" \
        MISTRAL_KEYRING_VAL="${MISTRAL_KEYRING_VAL:-}" \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_COPILOT_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=0 AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 \
        AIQ_MISTRAL_ENABLED=1 AIQ_GROK_ENABLED=0 AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_CACHE_TTL=0 CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

both_budgets='{
    "api_budget": {"usage_percentage": 12.345, "initial_budget": 30.0, "currency": "EUR", "reset_at": "2030-01-01T00:00:00Z", "payg_enabled": false},
    "vibe_budget": {"usage_percentage": 105.0, "initial_budget": 300.0, "currency": "EUR", "reset_at": "2030-01-01T00:00:00Z", "payg_enabled": true}
}'

# 1. Both budgets + INDIVIDUAL subscription mapped to Pro.
run_fetch "$both_budgets" | jq -e '
    .mistral == {
        "status": "ok",
        "plan": "Pro",
        "entries": [
            {"name": "API", "percentUsed": 12.35, "resetAt": 1893456000, "initialBudget": 30, "currency": "EUR", "paygEnabled": false},
            {"name": "Vibe", "percentUsed": 100, "resetAt": 1893456000, "initialBudget": 300, "currency": "EUR", "paygEnabled": true}
        ]
    }' >/dev/null
grep -Fqx 'https://api.mistral.ai/v1/billing/budget' "$requests"
grep -Fqx 'https://api.mistral.ai/v1/billing/subscription' "$requests"
grep -Fqx 'mistral-test-key' "$requests"

# 2. Plan title mappings: Enterprise, Team, Student, Free, and subscription PAYG fallback.
MISTRAL_SUB_BODY='{"plan_name":"TEAM","payg_enabled":true,"vibe_payg_enabled":true,"enterprise":false}' \
    run_fetch '{"api_budget":{"usage_percentage":5,"initial_budget":50,"currency":"USD","reset_at":"2030-01-01T00:00:00Z"},"vibe_budget":{"usage_percentage":10,"initial_budget":100,"currency":"USD","reset_at":"2030-01-01T00:00:00Z","payg_enabled":false}}' | jq -e '
    .mistral == {
        "status": "ok",
        "plan": "Team",
        "entries": [
            {"name": "API", "percentUsed": 5, "resetAt": 1893456000, "initialBudget": 50, "currency": "USD", "paygEnabled": true},
            {"name": "Vibe", "percentUsed": 10, "resetAt": 1893456000, "initialBudget": 100, "currency": "USD", "paygEnabled": false}
        ]
    }' >/dev/null

# Single active budget (zero initial_budget bucket is omitted).
run_fetch '{"api_budget":{"usage_percentage":5,"initial_budget":50,"currency":"USD","reset_at":"2030-01-01T00:00:00Z"},"vibe_budget":{"usage_percentage":0,"initial_budget":0,"currency":null,"reset_at":"2030-01-01T00:00:00Z"}}' | jq -e '
    .mistral.status == "ok" and [.mistral.entries[].name] == ["API"]' >/dev/null

MISTRAL_SUB_BODY='{"plan_name":"EDU","payg_enabled":false,"vibe_payg_enabled":false,"enterprise":false}' \
    run_fetch "$both_budgets" | jq -e '.mistral.plan == "Student"' >/dev/null
MISTRAL_SUB_BODY='{"plan_name":"FREE","payg_enabled":false,"vibe_payg_enabled":false,"enterprise":false}' \
    run_fetch "$both_budgets" | jq -e '.mistral.plan == "Free"' >/dev/null
MISTRAL_SUB_BODY='{"plan_name":"TEAM","payg_enabled":false,"vibe_payg_enabled":false,"enterprise":true}' \
    run_fetch "$both_budgets" | jq -e '.mistral.plan == "Enterprise"' >/dev/null

# 3. Subscription failure degrades gracefully to plan: null.
MISTRAL_SUB_HTTP=500 MISTRAL_SUB_BODY='oops' run_fetch "$both_budgets" | jq -e '
    .mistral.status == "ok" and .mistral.plan == null and (.mistral.entries | length) == 2' >/dev/null

# 4. Zero budgets on both pools report no_quota; malformed responses report error.
run_fetch '{"api_budget":{"usage_percentage":0,"initial_budget":0,"currency":null,"reset_at":"2030-01-01T00:00:00Z"},"vibe_budget":{"usage_percentage":0,"initial_budget":0,"currency":null,"reset_at":"2030-01-01T00:00:00Z"}}' | jq -e '
    .mistral.status == "unavailable" and .mistral.reason == "no_quota"' >/dev/null
run_fetch '{"error":"unexpected"}' | jq -e '
    .mistral.status == "error" and .mistral.error == "Could not parse Mistral budget response"' >/dev/null

# 5. HTTP error statuses do not call /subscription.
run_fetch '{}' 401 | jq -e '.mistral.status == "error" and .mistral.reason == "auth_expired"' >/dev/null
if grep -q 'billing/subscription' "$requests"; then exit 1; fi
run_fetch '{}' 403 | jq -e '.mistral.status == "error" and .mistral.reason == "access_denied"' >/dev/null
run_fetch '{}' 429 | jq -e '.mistral.status == "error" and .mistral.reason == "rate_limited"' >/dev/null
run_fetch '{}' 500 | jq -e '.mistral.status == "error" and .mistral.reason == "http_error"' >/dev/null
run_fetch '{}' 000 | jq -e '.mistral.status == "error" and .mistral.reason == "network"' >/dev/null

# 6. Missing credentials make no network or keyring calls when VIBE_HOME does not exist.
MISTRAL_API_KEY= run_fetch "$both_budgets" | jq -e '
    .mistral.status == "unavailable" and .mistral.reason == "not_authenticated"' >/dev/null
[ ! -s "$requests" ]
[ ! -s "$lookups" ]

# 7. Vibe ~/.vibe/.env fallback works, stripping quotes, and MISTRAL_API_KEY wins over it.
mkdir -p "$test_dir/home/.vibe"
printf 'OTHER=1\nMISTRAL_API_KEY="vibe-dotenv-key"\n' > "$test_dir/home/.vibe/.env"
MISTRAL_API_KEY= run_fetch "$both_budgets" | jq -e '.mistral.status == "ok"' >/dev/null
grep -Fqx 'vibe-dotenv-key' "$requests"
[ ! -s "$lookups" ]

run_fetch "$both_budgets" | jq -e '.mistral.status == "ok"' >/dev/null
grep -Fqx 'mistral-test-key' "$requests"
if grep -q 'vibe-dotenv-key' "$requests"; then exit 1; fi

# 8. OIDC marker in .env is skipped and falls back to Vibe keyring (ai.mistral.vibe and legacy vibe).
printf 'MISTRAL_API_KEY=vibe-cli-oidc\n' > "$test_dir/home/.vibe/.env"
MISTRAL_API_KEY= MISTRAL_KEYRING_VAL=vibe-keyring-key run_fetch "$both_budgets" | jq -e '.mistral.status == "ok"' >/dev/null
grep -Fqx 'vibe-keyring-key' "$requests"
grep -Fqx 'lookup service ai.mistral.vibe username MISTRAL_API_KEY' "$lookups"

MISTRAL_API_KEY= MISTRAL_KEYRING_SVC=vibe MISTRAL_KEYRING_VAL=vibe-legacy-key run_fetch "$both_budgets" | jq -e '.mistral.status == "ok"' >/dev/null
grep -Fqx 'vibe-legacy-key' "$requests"

MISTRAL_API_KEY= MISTRAL_KEYRING_VAL=vibe-cli-oidc run_fetch "$both_budgets" | jq -e '
    .mistral.status == "unavailable" and .mistral.reason == "not_authenticated"' >/dev/null
[ ! -s "$requests" ]

if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    run_fetch "$both_budgets" > "$AIQ_TEST_ARTIFACT_DIR/mistral-result.json"
fi
printf '%s\n' 'Mistral fetch checks passed.'
