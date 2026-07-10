#!/bin/sh
# Fetch OpenCode Go usage and DeepSeek balance, merge, cache, and print.
#
# OpenCode Go: Scrapes workspace dashboard directly via curl
# DeepSeek: GET https://api.deepseek.com/user/balance
#
# Env:
#   CACHE_FILE                cache path (default $XDG_CACHE_HOME/dms-ai-quotas/usage.json)
#   AIQ_OPENCODE_ENABLED      "1" to fetch OpenCode (default: "1")
#   AIQ_DEEPSEEK_ENABLED      "1" to fetch DeepSeek (default: "1")
#   DEEPSEEK_API_KEY          DeepSeek API key
#   OPENCODE_GO_WORKSPACE_ID  OpenCode workspace ID
#   OPENCODE_GO_AUTH_COOKIE   OpenCode auth cookie
#   AIQ_CACHE_TTL             seconds before cache is stale (default: 55)
#   AIQ_USAGE_MOCK            file with sample JSON (for tests)
set -u

cache="${CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/usage.json}"
ttl="${AIQ_CACHE_TTL:-55}"
mkdir -p "$(dirname "$cache")" 2>/dev/null
now=$(date +%s)

if [ -s "$cache" ]; then
    prev=$(jq -r '.captured_at // 0' "$cache" 2>/dev/null)
    case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
    if [ "$prev" -gt 0 ] && [ $((now - prev)) -lt "$ttl" ]; then
        cat "$cache"
        exit 0
    fi
fi

if [ -n "${AIQ_USAGE_MOCK:-}" ] && [ -f "$AIQ_USAGE_MOCK" ]; then
    cat "$AIQ_USAGE_MOCK"
    exit 0
fi

oc_enabled="${AIQ_OPENCODE_ENABLED:-1}"
ds_enabled="${AIQ_DEEPSEEK_ENABLED:-1}"

# ============================================================
# OpenCode Go
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
            # Extract usagePercent and resetInSec for each window.
            # Returns "pct reset" or empty.
            extract() {
                local label="$1"
                local pct="" reset=""
                # Match: rollingUsage:$R[N]={...usagePercent: N...resetInSec: N...}
                local block
                block=$(printf '%s' "$html" | sed -n "s/.*${label}:\$R\[[0-9]*\]={\([^}]*\)}.*/\1/p" | head -1)
                if [ -n "$block" ]; then
                    pct=$(printf '%s' "$block" | sed -n 's/.*usagePercent:[[:space:]]*\(-\{0,1\}[0-9.]*\).*/\1/p')
                    reset=$(printf '%s' "$block" | sed -n 's/.*resetInSec:[[:space:]]*\(-\{0,1\}[0-9.]*\).*/\1/p')
                fi
                if [ -n "$pct" ] && [ -n "$reset" ]; then
                    printf '%s %s' "$pct" "$reset"
                fi
            }

            rolling=$(extract "rollingUsage")
            weekly=$(extract "weeklyUsage")
            monthly=$(extract "monthlyUsage")

            # Build JSON entries.
            entries="["
            first=1
            for pair in "Rolling:$rolling" "Weekly:$weekly" "Monthly:$monthly"; do
                label="${pair%%:*}"
                data="${pair#*:}"
                [ -z "$data" ] && continue
                pct=$(printf '%s' "$data" | cut -d' ' -f1)
                reset=$(printf '%s' "$data" | cut -d' ' -f2)
                [ -z "$pct" ] || [ -z "$reset" ] && continue

                remaining=$(printf '%s' "$pct" | awk '{printf "%d", 100 - $1}')

                [ "$first" = "0" ] && entries="$entries,"
                first=0
                reset_at=$((now + ${reset%.*}))
                entries="$entries{\"name\":\"$label\",\"percentUsed\":$pct,\"resetAt\":$reset_at}"
            done
            entries="$entries]"

            if [ "$entries" != "[]" ]; then
                oc_data="{\"status\":\"ok\",\"entries\":$entries}"
            else
                oc_data="{\"status\":\"error\",\"error\":\"Could not parse usage from dashboard\"}"
            fi
        else
            oc_data="{\"status\":\"error\",\"error\":\"Failed to fetch dashboard\"}"
        fi
    else
        oc_data="{\"status\":\"unavailable\",\"error\":\"Set OpenCode credentials in plugin settings\"}"
    fi
fi

# ============================================================
# DeepSeek
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
# Merge and write cache
# ============================================================
out=$(jq -c -n \
    --argjson now "$now" \
    --argjson oc "$oc_data" \
    --argjson ds "$ds_data" \
    '{captured_at: $now, opencode: $oc, deepseek: $ds}') || exit 2

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
