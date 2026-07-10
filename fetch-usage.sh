#!/bin/sh
# Fetch OpenCode Go usage and DeepSeek balance, merge, cache, and print.
#
# OpenCode Go: Scrapes the workspace dashboard at opencode.ai
#   - Reads config from ~/.config/opencode-quota/opencode-go.json
#     or env vars OPENCODE_GO_WORKSPACE_ID + OPENCODE_GO_AUTH_COOKIE
#   - Parses rolling/weekly/monthly usage from HTML response
#
# DeepSeek: GET https://api.deepseek.com/user/balance
#   - Reads API key from DEEPSEEK_API_KEY env var
#
# Env:
#   CACHE_FILE              cache path (default $XDG_CACHE_HOME/dms-ai-quotas/usage.json)
#   AIQ_OPENCODE_ENABLED    "1" to fetch OpenCode (default: "1")
#   AIQ_DEEPSEEK_ENABLED    "1" to fetch DeepSeek (default: "1")
#   DEEPSEEK_API_KEY        DeepSeek API key
#   OPENCODE_GO_WORKSPACE_ID  OpenCode workspace ID (overrides config file)
#   OPENCODE_GO_AUTH_COOKIE   OpenCode auth cookie (overrides config file)
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

# ============================================================
# OpenCode Go: scrape workspace dashboard
# ============================================================
oc_data='{"status":"unavailable"}'
if [ "$oc_enabled" = "1" ]; then
    ws_id="${OPENCODE_GO_WORKSPACE_ID:-}"
    auth="${OPENCODE_GO_AUTH_COOKIE:-}"

    if [ -n "$ws_id" ] && [ -n "$auth" ]; then
        url="https://opencode.ai/workspace/$(printf '%s' "$ws_id" | jq -sRr @uri)/go"
        html=$(curl -s -m 15 \
            -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/148.0" \
            -H "Accept: text/html" \
            -H "Cookie: auth=$auth" \
            "$url" 2>/dev/null)

        if [ -n "$html" ]; then
            # Parse SolidJS SSR format: rollingUsage:$R[N]={usagePercent: N, resetInSec: N}
            parse_window() {
                local label="$1"
                local html_content="$2"
                # Try usagePercent first, then resetInSec first.
                local result
                result=$(printf '%s' "$html_content" | grep -oP "${label}:\\\$R\[\d+\]=\{[^}]*usagePercent:\s*(-?\d+(?:\.\d+)?)[^}]*resetInSec:\s*(-?\d+(?:\.\d+)?)\}" | head -1)
                if [ -z "$result" ]; then
                    result=$(printf '%s' "$html_content" | grep -oP "${label}:\\\$R\[\d+\]=\{[^}]*resetInSec:\s*(-?\d+(?:\.\d+)?)[^}]*usagePercent:\s*(-?\d+(?:\.\d+)?)\}" | head -1)
                    if [ -n "$result" ]; then
                        local reset pct
                        reset=$(printf '%s' "$result" | grep -oP 'resetInSec:\s*\K-?\d+(?:\.\d+)?')
                        pct=$(printf '%s' "$result" | grep -oP 'usagePercent:\s*\K-?\d+(?:\.\d+)?')
                        [ -n "$pct" ] && [ -n "$reset" ] && printf '%s %s' "$pct" "$reset"
                        return
                    fi
                fi
                if [ -n "$result" ]; then
                    local pct reset
                    pct=$(printf '%s' "$result" | grep -oP 'usagePercent:\s*\K-?\d+(?:\.\d+)?')
                    reset=$(printf '%s' "$result" | grep -oP 'resetInSec:\s*\K-?\d+(?:\.\d+)?')
                    [ -n "$pct" ] && [ -n "$reset" ] && printf '%s %s' "$pct" "$reset"
                fi
            }

            rolling=$(parse_window "rollingUsage" "$html")
            weekly=$(parse_window "weeklyUsage" "$html")
            monthly=$(parse_window "monthlyUsage" "$html")

            # Build JSON entries.
            entries="["
            first=1

            for window_data in "rolling:$rolling" "weekly:$weekly" "monthly:$monthly"; do
                label="${window_data%%:*}"
                data="${window_data#*:}"
                [ -z "$data" ] && continue
                pct="${data%% *}"
                reset="${data#* }"
                [ -z "$pct" ] || [ -z "$reset" ] && continue

                [ "$first" = "0" ] && entries="$entries,"
                first=0
                reset_at=$((now + ${reset%.*}))
                entries="$entries{\"name\":\"$label\",\"percentRemaining\":$(echo "100 - $pct" | bc 2>/dev/null || echo "0"),\"percentUsed\":$pct,\"resetAt\":$reset_at}"
            done

            entries="$entries]"

            if [ "$entries" != "[]" ]; then
                oc_data="{\"status\":\"ok\",\"entries\":$entries}"
            else
                oc_data="{\"status\":\"error\",\"error\":\"No usage windows found in dashboard\"}"
            fi
        else
            oc_data="{\"status\":\"error\",\"error\":\"Failed to fetch dashboard\"}"
        fi
    else
        oc_data="{\"status\":\"unavailable\",\"error\":\"No OpenCode config found. Set OPENCODE_GO_WORKSPACE_ID + OPENCODE_GO_AUTH_COOKIE or create ~/.config/opencode-quota/opencode-go.json\"}"
    fi
fi

# ============================================================
# DeepSeek: query balance API
# ============================================================
ds_data='{"status":"unavailable"}'
if [ "$ds_enabled" = "1" ]; then
    ds_key="${DEEPSEEK_API_KEY:-}"
    if [ -n "$ds_key" ]; then
        ds_resp=$(curl -s -m 10 \
            -H "Authorization: Bearer $ds_key" \
            -H "Accept: application/json" \
            https://api.deepseek.com/user/balance 2>/dev/null)
        if [ -n "$ds_resp" ]; then
            ds_data=$(echo "$ds_resp" | jq -c '{
                status: (if .is_available then "ok" else "error" end),
                isAvailable: .is_available,
                balances: [.balance_infos[] | {
                    currency: .currency,
                    total: .total_balance,
                    granted: .granted_balance,
                    toppedUp: .topped_up_balance
                }]
            }' 2>/dev/null) || ds_data="{\"status\":\"error\"}"
        fi
    fi
fi

# ============================================================
# Merge and write cache (compact single-line JSON)
# ============================================================
out=$(jq -c -n \
    --argjson now "$now" \
    --argjson oc "$oc_data" \
    --argjson ds "$ds_data" \
    '{captured_at: $now, opencode: $oc, deepseek: $ds}') || exit 2

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
