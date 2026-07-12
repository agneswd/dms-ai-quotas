#!/bin/sh
# Fetch Codex and OpenCode Go usage plus DeepSeek balance, merge, cache, and print.
#
# Codex: GET https://chatgpt.com/backend-api/wham/usage using the local Codex login
# OpenCode Go: Scrapes workspace dashboard directly via curl
# DeepSeek: GET https://api.deepseek.com/user/balance
#
# Env:
#   AIQ_CODEX_ENABLED         "1" to fetch Codex (default: "1")
#   CACHE_FILE                cache path (default $XDG_CACHE_HOME/dms-ai-quotas/usage.json)
#   CODEX_HOME                Codex home directory (default $HOME/.codex)
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
codex_enabled="${AIQ_CODEX_ENABLED:-1}"

# ============================================================
# Codex
# ============================================================
codex_data='{"status":"unavailable"}'
if [ "$codex_enabled" = "1" ]; then
    codex_home="${CODEX_HOME:-$HOME/.codex}"
    codex_auth="$codex_home/auth.json"
    access_token=$(jq -r '.tokens.access_token // empty' "$codex_auth" 2>/dev/null)
    account_id=$(jq -r '.tokens.account_id // empty' "$codex_auth" 2>/dev/null)

    if [ -n "$access_token" ]; then
        if [ -n "$account_id" ]; then
            codex_response=$(curl -s -m 15 -w '\n%{http_code}' \
                -H "Authorization: Bearer $access_token" \
                -H "ChatGPT-Account-Id: $account_id" \
                -H "Accept: application/json" \
                -H "User-Agent: codex-cli" \
                https://chatgpt.com/backend-api/wham/usage 2>/dev/null)
        else
            codex_response=$(curl -s -m 15 -w '\n%{http_code}' \
                -H "Authorization: Bearer $access_token" \
                -H "Accept: application/json" \
                -H "User-Agent: codex-cli" \
                https://chatgpt.com/backend-api/wham/usage 2>/dev/null)
        fi

        codex_http_code=$(printf '%s\n' "$codex_response" | tail -n 1)
        codex_body=$(printf '%s\n' "$codex_response" | sed '$d')
        case "$codex_http_code" in
            2??)
                codex_data=$(printf '%s' "$codex_body" | jq -c --argjson now "$now" '
                    def number:
                        if type == "number" then .
                        elif type == "string" then (tonumber? // 0)
                        else 0
                        end;
                    def reset_at:
                        if (.reset_at? != null) then (.reset_at | number)
                        elif (.reset_after_seconds? != null) then ($now + (.reset_after_seconds | number))
                        else 0
                        end;
                    def entry($name; $window):
                        if ($window | type) != "object" then empty
                        else
                            ($window.used_percent? |
                                if . == null then empty else number end) as $used |
                            {
                                name: $name,
                                percentUsed: (if $used < 0 then 0 elif $used > 100 then 100 else $used end),
                                resetAt: ($window | reset_at)
                            }
                        end;
                    . as $root |
                    [
                        entry("5h"; $root.rate_limit.primary_window),
                        entry("Weekly"; $root.rate_limit.secondary_window),
                        entry("Code Review"; $root.code_review_rate_limit.primary_window)
                    ] as $entries |
                    if ($entries | length) == 0 then
                        error("no quota windows")
                    else
                        {
                            status: "ok",
                            plan: ($root.plan_type // "ChatGPT"),
                            entries: $entries,
                            credits: (if $root.credits == null then null else {
                                hasCredits: ($root.credits.has_credits // false),
                                unlimited: ($root.credits.unlimited // false),
                                balance: ($root.credits.balance // null)
                            } end)
                        }
                    end
                ' 2>/dev/null) || codex_data='{"status":"error","error":"Could not parse Codex usage"}'
                ;;
            401)
                codex_data='{"status":"error","error":"Codex login expired; run codex login"}'
                ;;
            *)
                codex_data='{"status":"error","error":"Failed to fetch Codex usage"}'
                ;;
        esac
    else
        codex_data='{"status":"unavailable","error":"Run codex login to enable Codex usage"}'
    fi
fi

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
    --argjson codex "$codex_data" \
    --argjson oc "$oc_data" \
    --argjson ds "$ds_data" \
    '{captured_at: $now, codex: $codex, opencode: $oc, deepseek: $ds}') || exit 2

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
