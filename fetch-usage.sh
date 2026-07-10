#!/bin/sh
# Fetch OpenCode usage quotas and DeepSeek balance, merge, cache, and print.
#
# Data sources:
#   - OpenCode: `opencode-quota show --json` (requires @slkiser/opencode-quota)
#   - DeepSeek: GET https://api.deepseek.com/user/balance (requires API key)
#
# Env:
#   CACHE_FILE              cache path (default $XDG_CACHE_HOME/dms-ai-quotas/usage.json)
#   AIQ_OPENCODE_ENABLED    "1" to fetch OpenCode (default: "1")
#   AIQ_DEEPSEEK_ENABLED    "1" to fetch DeepSeek (default: "1")
#   DEEPSEEK_API_KEY        DeepSeek API key (or read from plugin settings)
#   AIQ_CACHE_TTL           seconds before cache is stale (default: 55)
#   AIQ_USAGE_MOCK          file with sample JSON (skips network; for tests)
#
# Exit: 0 ok, 1 no data, 2 fetch/parse error.
set -u

cache="${CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/usage.json}"
ttl="${AIQ_CACHE_TTL:-55}"
mkdir -p "$(dirname "$cache")" 2>/dev/null
now=$(date +%s)

# Return cached data if fresh.
if [ -s "$cache" ]; then
    prev=$(jq -r '.captured_at // 0' "$cache" 2>/dev/null)
    case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
    if [ "$prev" -gt 0 ] && [ $((now - prev)) -lt "$ttl" ]; then
        cat "$cache"
        exit 0
    fi
fi

# Use mock data if provided (for testing).
if [ -n "${AIQ_USAGE_MOCK:-}" ] && [ -f "$AIQ_USAGE_MOCK" ]; then
    cat "$AIQ_USAGE_MOCK"
    exit 0
fi

oc_enabled="${AIQ_OPENCODE_ENABLED:-1}"
ds_enabled="${AIQ_DEEPSEEK_ENABLED:-1}"
ds_key="${DEEPSEEK_API_KEY:-}"

# --- Fetch OpenCode data ---
oc_data='{"status":"unavailable"}'
if [ "$oc_enabled" = "1" ]; then
    oc_json=$(opencode-quota show --json 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$oc_json" ]; then
        # Extract the opencode-go provider entries (or all providers with data).
        # We want providers that have status "ok" and entries.
        oc_data=$(echo "$oc_json" | jq -c '{
            status: "ok",
            providers: [(.providers | to_entries[] | select(.value.status == "ok" and .value.entries != null) | {
                id: .key,
                entries: .value.entries
            })]
        }' 2>/dev/null) || oc_data='{"status":"error"}'
    fi
fi

# --- Fetch DeepSeek data ---
ds_data='{"status":"unavailable"}'
if [ "$ds_enabled" = "1" ] && [ -n "$ds_key" ]; then
    ds_resp=$(curl -s -m 10 \
        -H "Authorization: Bearer $ds_key" \
        -H "Accept: application/json" \
        https://api.deepseek.com/user/balance 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$ds_resp" ]; then
        ds_data=$(echo "$ds_resp" | jq -c '{
            status: (if .is_available then "ok" else "error" end),
            isAvailable: .is_available,
            balances: [.balance_infos[] | {
                currency: .currency,
                total: .total_balance,
                granted: .granted_balance,
                toppedUp: .topped_up_balance
            }]
        }' 2>/dev/null) || ds_data='{"status":"error"}'
    fi
fi

# --- Merge and write cache ---
out=$(jq -c -n \
    --argjson now "$now" \
    --argjson oc "$oc_data" \
    --argjson ds "$ds_data" \
    '{
        captured_at: $now,
        opencode: $oc,
        deepseek: $ds
    }') || exit 2

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
