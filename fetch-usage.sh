#!/bin/sh
# Fetch Claude, Codex and OpenCode Go usage plus DeepSeek balance and Grok billing quotas, merge, cache, and print.
#
# Claude: reads native rate-limit data captured from Claude Code's status line
# Codex: GET https://chatgpt.com/backend-api/wham/usage using the local Codex login
# OpenCode Go: Scrapes workspace dashboard directly via curl
# DeepSeek: GET https://api.deepseek.com/user/balance
# Grok: billing usage via ~/.grok/auth.json + cli-chat-proxy billing
#
# Env:
#   AIQ_CLAUDE_ENABLED        "1" to fetch Claude (default: "1")
#   AIQ_CODEX_ENABLED         "1" to fetch Codex (default: "1")
#   CACHE_FILE                cache path (default $XDG_CACHE_HOME/dms-ai-quotas/usage.json)
#   CLAUDE_CONFIG_DIR         Claude Code config directory (default $HOME/.claude)
#   CLAUDE_USAGE_FILE         native Claude usage snapshot
#   CLAUDE_FALLBACK_STATE_FILE fallback poll state
#   CODEX_HOME                Codex home directory (default $HOME/.codex)
#   GROK_HOME                 Grok home directory (default $HOME/.grok)
#   AIQ_OPENCODE_ENABLED      "1" to fetch OpenCode (default: "1")
#   AIQ_DEEPSEEK_ENABLED      "1" to fetch DeepSeek (default: "1")
#   AIQ_GROK_ENABLED          "1" to fetch Grok (default: "1")
#   DEEPSEEK_API_KEY          DeepSeek API key
#   OPENCODE_GO_WORKSPACE_ID  OpenCode workspace ID
#   OPENCODE_GO_AUTH_COOKIE   OpenCode auth cookie
#   AIQ_CACHE_TTL             seconds before cache is stale (default: 55)
#   AIQ_FORCE_REFRESH         "1" to bypass the cache
#   AIQ_USAGE_MOCK            file with sample JSON (for tests)
set -u
umask 077

claude_enabled="${AIQ_CLAUDE_ENABLED:-1}"
oc_enabled="${AIQ_OPENCODE_ENABLED:-1}"
ds_enabled="${AIQ_DEEPSEEK_ENABLED:-1}"
codex_enabled="${AIQ_CODEX_ENABLED:-1}"
agy_enabled="${AIQ_ANTIGRAVITY_ENABLED:-1}"
grok_enabled="${AIQ_GROK_ENABLED:-1}"
cache="${CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/usage.json}"
ttl="${AIQ_CACHE_TTL:-55}"
force_refresh="${AIQ_FORCE_REFRESH:-0}"
mkdir -p "$(dirname "$cache")" 2>/dev/null
now=$(date +%s)

if [ "$force_refresh" != "1" ] && [ -s "$cache" ]; then
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

# ============================================================
# Claude plan usage from native status data with a five-minute API fallback
# ============================================================
claude_data='{"status":"unavailable"}'
if [ "$claude_enabled" = "1" ]; then
    claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    claude_creds="$claude_home/.credentials.json"
    access_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$claude_creds" 2>/dev/null)
    sub_type=$(jq -r '.claudeAiOauth.subscriptionType // empty' "$claude_creds" 2>/dev/null)
    rate_tier=$(jq -r '.claudeAiOauth.rateLimitTier // empty' "$claude_creds" 2>/dev/null)

    case "$rate_tier" in
        *max_20x*) claude_plan="Max 20x" ;;
        *max_5x*)  claude_plan="Max 5x" ;;
        *)
            case "$sub_type" in
                pro) claude_plan="Pro" ;;
                max) claude_plan="Max" ;;
                team) claude_plan="Team" ;;
                enterprise) claude_plan="Enterprise" ;;
                free) claude_plan="Free" ;;
                '') claude_plan="Claude" ;;
                *) claude_plan="$sub_type" ;;
            esac
            ;;
    esac

    claude_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas"
    claude_usage="${CLAUDE_USAGE_FILE:-$claude_cache_dir/claude-native.json}"
    claude_fallback_state="${CLAUDE_FALLBACK_STATE_FILE:-$claude_cache_dir/claude-fallback.json}"
    mkdir -p "$(dirname "$claude_usage")" "$(dirname "$claude_fallback_state")" 2>/dev/null
    claude_captured=$(jq -r '.captured_at // 0' "$claude_usage" 2>/dev/null)
    claude_checked=$(jq -r '.checked_at // 0' "$claude_fallback_state" 2>/dev/null)
    claude_retry=$(jq -r '.retry_at // 0' "$claude_fallback_state" 2>/dev/null)
    case "$claude_captured" in ''|*[!0-9]*) claude_captured=0 ;; esac
    case "$claude_checked" in ''|*[!0-9]*) claude_checked=0 ;; esac
    case "$claude_retry" in ''|*[!0-9]*) claude_retry=0 ;; esac

    claude_error=""
    if [ -n "$access_token" ] &&
       [ $((now - claude_captured)) -ge 300 ] &&
       [ $((now - claude_checked)) -ge 300 ] &&
       [ "$now" -ge "$claude_retry" ]; then
        claude_headers=$(mktemp "${TMPDIR:-/tmp}/aiq-claude-headers.XXXXXX")
        claude_response=$(curl -s -m 15 -D "$claude_headers" -w '\n%{http_code}' \
            -H "Authorization: Bearer $access_token" \
            -H "Accept: application/json" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: dms-ai-quotas" \
            https://api.anthropic.com/api/oauth/usage 2>/dev/null)
        claude_http_code=$(printf '%s\n' "$claude_response" | tail -n 1)
        claude_body=$(printf '%s\n' "$claude_response" | sed '$d')
        claude_retry_at=0

        case "$claude_http_code" in
            2??)
                claude_snapshot=$(printf '%s' "$claude_body" | jq -c --argjson now "$now" '
                    def number:
                        if type == "number" then .
                        elif type == "string" then (tonumber? // 0)
                        else 0
                        end;
                    def timestamp:
                        if type == "number" then .
                        elif type == "string" then
                            (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601?) // 0
                        else 0
                        end;
                    [
                        {name: "5h", window: .five_hour},
                        {name: "Weekly", window: .seven_day}
                    ]
                    | map(select(.window.utilization != null))
                    | map({
                        name: .name,
                        percentUsed: ([((.window.utilization | number)), 0] | max | [., 100] | min),
                        resetAt: (.window.resets_at | timestamp)
                    })
                    | if length == 0 then error("no quota windows")
                      else {captured_at: $now, source: "oauth", entries: .}
                      end
                ' 2>/dev/null) || claude_snapshot=""
                if [ -n "$claude_snapshot" ]; then
                    claude_tmp=$(mktemp "$(dirname "$claude_usage")/.claude-usage.XXXXXX")
                    printf '%s\n' "$claude_snapshot" > "$claude_tmp" && mv "$claude_tmp" "$claude_usage"
                else
                    claude_error='{"status":"error","error":"Could not parse Claude usage response"}'
                fi
                ;;
            401)
                claude_error='{"status":"error","reason":"auth_expired","error":"Claude login expired. Start Claude Code to refresh it, then refresh AI Quotas."}'
                ;;
            403)
                claude_error='{"status":"error","reason":"access_denied","error":"Claude usage access was denied for this account."}'
                ;;
            429)
                retry_after=$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' "$claude_headers" | tr -d '\r' | tail -n 1)
                case "$retry_after" in
                    '') claude_retry_at=$((now + 3600)) ;;
                    *[!0-9]*) claude_retry_at=$(date -d "$retry_after" +%s 2>/dev/null || printf '%s' $((now + 3600))) ;;
                    *) claude_retry_at=$((now + retry_after)) ;;
                esac
                [ "$claude_retry_at" -gt "$now" ] || claude_retry_at=$((now + 3600))
                ;;
        esac
        rm -f "$claude_headers"

        fallback_tmp=$(mktemp "$(dirname "$claude_fallback_state")/.claude-fallback.XXXXXX")
        jq -n -c --argjson checked "$now" --argjson retry "$claude_retry_at" \
            '{checked_at: $checked, retry_at: $retry}' > "$fallback_tmp" &&
            mv "$fallback_tmp" "$claude_fallback_state"
    fi

    if [ -n "$claude_error" ]; then
        claude_data="$claude_error"
    elif [ -s "$claude_usage" ]; then
        claude_data=$(jq -c --arg plan "$claude_plan" --argjson now "$now" '
            select((.entries | type) == "array" and (.entries | length) > 0)
            | ((.captured_at | tonumber?) // 0) as $captured
            | {
                status: "ok",
                plan: $plan,
                source: (.source // "native"),
                capturedAt: ($captured // 0),
                stale: (($now - ($captured // 0)) >= 600),
                entries: .entries
              }
        ' "$claude_usage" 2>/dev/null)
        [ -n "$claude_data" ] || claude_data='{"status":"error","error":"Could not parse Claude usage data"}'
    elif [ -n "$access_token" ]; then
        claude_data='{"status":"unavailable","reason":"usage_pending","error":"Claude usage data is not available yet. Send a Claude Code message, then refresh AI Quotas."}'
    else
        claude_data='{"status":"unavailable","reason":"not_authenticated","error":"Claude is not logged in. Run claude in a terminal and sign in, then refresh AI Quotas."}'
    fi
fi

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
                    def quota_name($fallback; $window):
                        if $fallback == "Code Review" then $fallback
                        elif (($window.limit_window_seconds? | number) >= 604800) then "Weekly"
                        elif (($window.limit_window_seconds? | number) >= 14400) then "5h"
                        else $fallback
                        end;
                    def entry($name; $window):
                        if ($window | type) != "object" then empty
                        else
                            ($window.used_percent? |
                                if . == null then empty else number end) as $used |
                            {
                                name: quota_name($name; $window),
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
                codex_data='{"status":"error","reason":"auth_expired","error":"Codex login expired. Run codex login again, then refresh AI Quotas."}'
                ;;
            403)
                codex_data='{"status":"error","reason":"access_denied","error":"Codex usage access was denied for this account."}'
                ;;
            429)
                codex_data='{"status":"error","reason":"rate_limited","error":"Codex usage is temporarily rate limited. Try again shortly."}'
                ;;
            000)
                codex_data='{"status":"error","reason":"network","error":"Could not reach the Codex usage service. Check your connection and try again."}'
                ;;
            *)
                codex_data="{\"status\":\"error\",\"reason\":\"http_error\",\"error\":\"Codex usage service returned HTTP $codex_http_code. Try again shortly.\"}"
                ;;
        esac
    else
        codex_data='{"status":"unavailable","reason":"not_authenticated","error":"Codex is not logged in. Run codex login in a terminal, then refresh AI Quotas."}'
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
                status: "ok",
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
# Grok billing usage (OAuth via grok login, not API key)
# ============================================================
grok_data='{"status":"unavailable"}'
if [ "$grok_enabled" = "1" ]; then
    grok_home="${GROK_HOME:-$HOME/.grok}"
    grok_auth="$grok_home/auth.json"
    access_token=$(jq -r 'to_entries[0].value.key // empty' "$grok_auth" 2>/dev/null)
    email=$(jq -r 'to_entries[0].value.email // empty' "$grok_auth" 2>/dev/null)

    if [ -n "$access_token" ]; then
        grok_response=$(curl -s -m 15 -w '\n%{http_code}' \
            -H "Authorization: Bearer $access_token" \
            -H "Accept: application/json" \
            -H "User-Agent: dms-ai-quotas" \
            -H "x-grok-client-mode: cli" \
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits" 2>/dev/null)
        grok_http_code=$(printf '%s\n' "$grok_response" | tail -n 1)
        grok_body=$(printf '%s\n' "$grok_response" | sed '$d')
        case "$grok_http_code" in
            2??)
                grok_data=$(printf '%s' "$grok_body" | jq -c --arg email "$email" '
                    def number:
                        if type == "number" then .
                        elif type == "string" then (tonumber? // 0)
                        else 0
                        end;
                    def clamp_pct:
                        if . < 0 then 0 elif . > 100 then 100 else . end;
                    def parse_ts:
                        if . == null or . == "" then 0
                        else
                            (tostring
                             | sub("\\.[0-9]+"; "")
                             | sub("\\+00:00$"; "Z")
                             | sub("\\+0000$"; "Z")
                             | fromdateiso8601?) // 0
                        end;
                    def amount:
                        if type == "object" then (.val | number) else number end;
                    .config as $c |
                    ($c.currentPeriod.end // $c.billingPeriodEnd // null | parse_ts) as $reset |
                    ($c.onDemandCap | amount) as $cap |
                    ($c.onDemandUsed | amount) as $used |
                    (
                        if $c.creditUsagePercent != null then
                            [{
                                name: "Billing",
                                kind: "plan",
                                percentUsed: (($c.creditUsagePercent | number) | clamp_pct),
                                resetAt: $reset
                            }]
                        elif $cap > 0 then
                            [{
                                name: "Billing",
                                kind: "on_demand",
                                percentUsed: ((100 * $used / $cap) | clamp_pct),
                                resetAt: $reset
                            }]
                        else []
                        end
                    ) as $entries |
                    if ($entries | length) == 0 then
                        {
                            status: "unavailable",
                            reason: "no_quota",
                            error: "Grok does not expose a billing quota for this account."
                        }
                    else
                        {
                            status: "ok",
                            plan: (if $c.isUnifiedBillingUser == true then "SuperGrok" else "Grok" end),
                            email: (if $email == "" then null else $email end),
                            entries: $entries
                        }
                    end
                ' 2>/dev/null) || grok_data='{"status":"error","error":"Could not parse Grok billing response"}'
                ;;
            401|403)
                grok_data='{"status":"error","reason":"auth_expired","error":"Grok login expired. Run grok login again, then refresh AI Quotas."}'
                ;;
            000)
                grok_data='{"status":"error","reason":"network","error":"Could not reach the Grok billing service. Check your connection and try again."}'
                ;;
            *)
                grok_data="{\"status\":\"error\",\"reason\":\"http_error\",\"error\":\"Grok billing service returned HTTP $grok_http_code. Try again shortly.\"}"
                ;;
        esac
    else
        grok_data='{"status":"unavailable","reason":"not_authenticated","error":"Grok is not logged in. Run grok login in a terminal, then refresh AI Quotas."}'
    fi
fi

# ============================================================
# Antigravity
# ============================================================
agy_data='{"status":"unavailable"}'
if [ "$agy_enabled" = "1" ]; then
    if command -v secret-tool >/dev/null 2>&1; then
        KEYRING_JSON=$(secret-tool lookup service gemini username antigravity 2>/dev/null || true)
        if [ -n "$KEYRING_JSON" ]; then
            ACCESS_TOKEN=$(printf '%s' "$KEYRING_JSON" | jq -r '.token.access_token // empty' 2>/dev/null || true)
            REFRESH_TOKEN=$(printf '%s' "$KEYRING_JSON" | jq -r '.token.refresh_token // empty' 2>/dev/null || true)
            EXPIRY_RAW=$(printf '%s' "$KEYRING_JSON" | jq -r '.token.expiry // empty' 2>/dev/null || true)
            ACCOUNT=$(printf '%s' "$KEYRING_JSON" | jq -r '.account // .email // empty' 2>/dev/null || true)
            [ -z "$ACCOUNT" ] && [ -f "$HOME/.gemini/google_accounts.json" ] && \
                ACCOUNT=$(jq -r '.active // empty' "$HOME/.gemini/google_accounts.json" 2>/dev/null || true)

            token_valid() {
                local exp="$1"
                [ -z "$exp" ] && return 1
                local exp_epoch=0
                case "$exp" in
                    ''|*[!0-9]*)
                        exp_epoch=$(date -d "$exp" +%s 2>/dev/null || echo 0) ;;
                    *)
                        if [ "${#exp}" -ge 13 ]; then
                            exp_epoch=$(( exp / 1000 ))
                        else
                            exp_epoch="$exp"
                        fi ;;
                esac
                [ "$exp_epoch" -gt "$(( $(date +%s) + 60 ))" ] 2>/dev/null
            }

            CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agy-usage"
            mkdir -p "$CACHE_DIR"
            chmod 700 "$CACHE_DIR" 2>/dev/null || true
            TOKEN_CACHE="$CACHE_DIR/token.json"
            SECRET_CACHE="$CACHE_DIR/client_secret.txt"
            PROJECT_CACHE="$CACHE_DIR/project.txt"
            PLAN_CACHE="$CACHE_DIR/plan.txt"
            chmod 600 "$TOKEN_CACHE" "$SECRET_CACHE" 2>/dev/null || true

            if ! token_valid "$EXPIRY_RAW"; then
                if [ -f "$TOKEN_CACHE" ]; then
                    c_at=$(jq -r '.access_token // empty' "$TOKEN_CACHE" 2>/dev/null || true)
                    c_ex=$(jq -r '.expiry // 0' "$TOKEN_CACHE" 2>/dev/null || echo 0)
                    if [ -n "$c_at" ] && token_valid "$c_ex"; then
                        ACCESS_TOKEN="$c_at"
                        EXPIRY_RAW="$c_ex"
                    fi
                fi
            fi

            if ! token_valid "$EXPIRY_RAW" && [ -n "$REFRESH_TOKEN" ]; then
                secrets=""
                if [ -s "$SECRET_CACHE" ]; then
                    secrets=$(cat "$SECRET_CACHE")
                else
                    bin_path=$(command -v agy 2>/dev/null || true)
                    if [ -n "$bin_path" ] && [ -f "$bin_path" ]; then
                        secrets=$(grep -aoE 'GOCSPX-[A-Za-z0-9_-]{28}' "$bin_path" 2>/dev/null | sort -u || true)
                    fi
                fi

                for secret in $secrets; do
                    resp=$(curl -s --max-time 15 "https://oauth2.googleapis.com/token" \
                        --data-urlencode "client_id=1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com" \
                        --data-urlencode "client_secret=$secret" \
                        --data-urlencode "refresh_token=$REFRESH_TOKEN" \
                        --data-urlencode "grant_type=refresh_token" 2>/dev/null) || continue
                    at=$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null || true)
                    if [ -n "$at" ]; then
                        ein=$(printf '%s' "$resp" | jq -r '.expires_in // 3600' 2>/dev/null || echo 3600)
                        ACCESS_TOKEN="$at"
                        EXPIRY_RAW=$(( $(date +%s) + ein ))
                        printf '%s' "$secret" > "$SECRET_CACHE" 2>/dev/null || true
                        jq -n --arg t "$at" --argjson e "$EXPIRY_RAW" '{access_token:$t, expiry:$e}' > "$TOKEN_CACHE" 2>/dev/null || true
                        break
                    fi
                done
            fi

            PROJECT=""
            [ -f "$PROJECT_CACHE" ] && PROJECT=$(cat "$PROJECT_CACHE" 2>/dev/null || true)
            PLAN=""
            if [ -z "$PROJECT" ]; then
                LCA=$(curl -s --max-time 12 \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -H "Content-Type: application/json" \
                    -H "Accept: application/json" \
                    -H "User-Agent: antigravity/cli/1.0.8 linux/amd64" \
                    -X POST "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" \
                    --data '{"metadata":{"ideType":"ANTIGRAVITY"}}' 2>/dev/null || true)
                PROJECT=$(printf '%s' "$LCA" | jq -r '.cloudaicompanionProject // empty' 2>/dev/null || true)
                PLAN=$(printf '%s' "$LCA" | jq -r '(.paidTier.name // .currentTier.name) // empty' 2>/dev/null || true)
                if [ -n "$PROJECT" ]; then
                    printf '%s' "$PROJECT" > "$PROJECT_CACHE"
                    [ -n "$PLAN" ] && printf '%s' "$PLAN" > "$PLAN_CACHE"
                fi
            fi

            if [ -z "$PLAN" ] && [ -f "$PLAN_CACHE" ]; then
                PLAN=$(cat "$PLAN_CACHE" 2>/dev/null || true)
            fi

            if [ -n "$PROJECT" ]; then
                resp=$(curl -s --max-time 12 \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -H "Content-Type: application/json" \
                    -H "Accept: application/json" \
                    -H "User-Agent: antigravity/cli/1.0.8 linux/amd64" \
                    -X POST "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary" \
                    --data "$(jq -n --arg p "$PROJECT" '{project:$p}')" 2>/dev/null || true)
                
                if printf '%s' "$resp" | jq -e '.groups' >/dev/null 2>&1; then
                    agy_data=$(printf '%s' "$resp" | jq -c --arg email "$ACCOUNT" --arg plan "$PLAN" '{
                        status: "ok",
                        email: $email,
                        plan: $plan,
                        entries: [.groups[] | .displayName as $groupName | .buckets[] | {
                            name: ($groupName + " - " + .displayName),
                            percentUsed: ((1 - (.remainingFraction // 1.0)) * 100 | round),
                            resetAt: ((.resetTime | fromdateiso8601) // 0)
                        }]
                    }' 2>/dev/null) || agy_data='{"status":"error","error":"Could not parse Antigravity quota response"}'
                else
                    agy_data='{"status":"error","error":"Failed to retrieve Antigravity quota summary"}'
                fi
            else
                agy_data='{"status":"error","error":"Failed to load Antigravity companion project"}'
            fi
        else
            agy_data='{"status":"error","reason":"not_authenticated","error":"Antigravity is not logged in. Run agy login in a terminal, then refresh AI Quotas."}'
        fi
    else
        agy_data='{"status":"error","error":"secret-tool is not installed. Please install libsecret."}'
    fi
fi

# ============================================================
# Merge and write cache
# ============================================================
out=$(jq -c -n \
    --argjson now "$now" \
    --argjson claude "$claude_data" \
    --argjson codex "$codex_data" \
    --argjson oc "$oc_data" \
    --argjson ds "$ds_data" \
    --argjson grok "$grok_data" \
    --argjson agy "$agy_data" \
    '{captured_at: $now, claude: $claude, codex: $codex, opencode: $oc, deepseek: $ds, grok: $grok, antigravity: $agy}') || exit 2

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
