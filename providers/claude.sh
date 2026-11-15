# Claude plan usage. The newest of three snapshots wins:
#
#   claude-code  The usage cache that Claude Code keeps in .claude.json. Every
#                Claude Code process writes it, also SDK and IDE sessions. Free.
#   native       The status line snapshot from claude-statusline.sh. Interactive
#                sessions write it after each response. Free.
#   oauth        This module's own request to api.anthropic.com/api/oauth/usage.
#
# The module asks the API only when the snapshots are likely out of date: one
# minute after Claude Code was used (a transcript changed after the newest
# snapshot), or every 15 minutes to see use from other devices. It asks at most
# once a minute and honors Retry-After on HTTP 429. Claude Code uses the same
# endpoint, so the module stays quiet when it is not needed.
#
# A window whose reset time has passed shows as unused, so old data stays correct.
#
# Env: CLAUDE_CONFIG_DIR, CLAUDE_USAGE_FILE, CLAUDE_FALLBACK_STATE_FILE

claude_plan_name() {
    case "$2" in
        *max_20x*) printf 'Max 20x' ;;
        *max_5x*) printf 'Max 5x' ;;
        *)
            case "$1" in
                pro) printf 'Pro' ;;
                max) printf 'Max' ;;
                team) printf 'Team' ;;
                enterprise) printf 'Enterprise' ;;
                free) printf 'Free' ;;
                '') printf 'Claude' ;;
                *) printf '%s' "$1" ;;
            esac
            ;;
    esac
}

# jq: usage API body (also the Claude Code cache) to entries. Prefers the
# "limits" list, which also has model-scoped weekly limits.
CLAUDE_JQ_ENTRIES='
def claude_entries:
    if (.limits | type) == "array" and (.limits | length) > 0 then
        [.limits[] | select(.percent != null) | {
            name: (if .kind == "session" then "5h"
                   elif .kind == "weekly_all" then "Weekly"
                   elif .kind == "weekly_scoped" then
                       "Weekly " + (.scope.model.display_name // .scope.surface.display_name // "scoped")
                   else .kind end),
            percentUsed: (.percent | number | clamp_pct),
            resetAt: (.resets_at | timestamp)
        }]
    else
        [{name: "5h", window: .five_hour}, {name: "Weekly", window: .seven_day}]
        | map(select(.window.utilization != null) | {
            name: .name,
            percentUsed: (.window.utilization | number | clamp_pct),
            resetAt: (.window.resets_at | timestamp)
        })
    end;
'

# Print the snapshots as one JSON array of {source, captured_at, entries}.
claude_snapshots() {
    {
        jq -c '{source: "native", captured_at, entries}' "$usage_file" 2>/dev/null
        jq -c --arg account "$account" 'select(.account == $account)
            | {source: "oauth", captured_at, entries}' "$poll_state" 2>/dev/null
        jq -c --arg account "$account" "$AIQ_JQ_DEFS $CLAUDE_JQ_ENTRIES"'
            .cachedUsageUtilization
            | select(.accountUuid == $account and .utilization != null)
            | {source: "claude-code", captured_at: (.fetchedAtMs / 1000 | floor),
               entries: (.utilization | claude_entries)}' "$global_config" 2>/dev/null
    } | jq -s -c 'map(select(
            (.captured_at | type) == "number"
            and (.entries | type) == "array" and (.entries | length) > 0))'
}

# True when a Claude Code transcript changed after the given time.
claude_used_since() {
    [ -d "$projects_dir" ] || return 1
    touch -d "@$1" "$auth_dir/claude-since" 2>/dev/null || return 0
    [ -n "$(find "$projects_dir" -name '*.jsonl' -newer "$auth_dir/claude-since" -print -quit 2>/dev/null)" ]
}

# Ask the usage API. On success, store the snapshot in the poll state. Always
# store when to ask next. Sets claude_error when the request fails.
claude_poll_api() {
    response_headers="$auth_dir/claude-response"
    headers=$(aiq_headers claude "Authorization: Bearer $access_token")
    aiq_request "$headers" https://api.anthropic.com/api/oauth/usage \
        -D "$response_headers" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: dms-ai-quotas"
    retry_at=0
    entries=null

    case "$http_code" in
        2??)
            entries=$(printf '%s' "$http_body" | jq -c "$AIQ_JQ_DEFS $CLAUDE_JQ_ENTRIES"'
                claude_entries | if length == 0 then error("no quota windows") else . end' 2>/dev/null) ||
                entries=null
            [ -n "$entries" ] || entries=null
            [ "$entries" != null ] ||
                claude_error=$(aiq_status error "" "Could not parse Claude usage response")
            ;;
        401)
            retry_at=$((now + 300))
            claude_error=$(aiq_status error auth_expired "Claude login expired. Start Claude Code to refresh it, then refresh AI Quotas.")
            ;;
        403)
            retry_at=$((now + 3600))
            claude_error=$(aiq_status error access_denied "Claude usage access was denied for this account.")
            ;;
        429)
            retry_after=$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' "$response_headers" | tr -d '\r' | tail -n 1)
            case "$retry_after" in
                '') retry_at=$((now + 300)) ;;
                *[!0-9]*) retry_at=$(date -d "$retry_after" +%s 2>/dev/null || printf '%s' 0) ;;
                *) retry_at=$((now + retry_after)) ;;
            esac
            [ "$retry_at" -gt "$now" ] || retry_at=$((now + 300))
            claude_error=$(aiq_http_failure 429 "the Claude usage service")
            ;;
        *)
            claude_error=$(aiq_http_failure "$http_code" "the Claude usage service")
            ;;
    esac
    rm -f "$response_headers" "$headers"

    old=$(jq -c 'select(type == "object")' "$poll_state" 2>/dev/null)
    tmp=$(mktemp "$(dirname "$poll_state")/.claude-poll.XXXXXX") || return
    jq -c -n --argjson old "${old:-"{}"}" --argjson now "$now" --argjson retry "$retry_at" \
        --argjson entries "$entries" --arg account "$account" '
        $old + {checked_at: $now, retry_at: $retry}
        + (if $entries == null then {}
           else {captured_at: $now, account: $account, entries: $entries} end)
    ' > "$tmp" && mv "$tmp" "$poll_state" || rm -f "$tmp"
}

# Read a non-negative integer field from a JSON file, or 0.
claude_int() {
    _value=$(jq -r "$1 // 0 | floor" "$2" 2>/dev/null)
    case "$_value" in ''|*[!0-9]*) _value=0 ;; esac
    printf '%s' "$_value"
}

fetch_claude() {
    config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        global_config="$CLAUDE_CONFIG_DIR/.claude.json"
    else
        global_config="$HOME/.claude.json"
    fi
    projects_dir="$config_dir/projects"
    creds="$config_dir/.credentials.json"
    access_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
    account=$(jq -r '.oauthAccount.accountUuid // empty' "$global_config" 2>/dev/null)
    # Claude Code refreshes the profile in .claude.json. The credentials keep the
    # plan from login time, so they are only the fallback.
    plan_type=$(jq -r '.oauthAccount.organizationType // empty | sub("^claude_"; "")' "$global_config" 2>/dev/null)
    plan_tier=$(jq -r '.oauthAccount | .userRateLimitTier // .organizationRateLimitTier // empty' "$global_config" 2>/dev/null)
    if [ -z "$plan_type" ]; then
        plan_type=$(jq -r '.claudeAiOauth.subscriptionType // empty' "$creds" 2>/dev/null)
        plan_tier=$(jq -r '.claudeAiOauth.rateLimitTier // empty' "$creds" 2>/dev/null)
    fi
    plan=$(claude_plan_name "$plan_type" "$plan_tier")

    state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas"
    usage_file="${CLAUDE_USAGE_FILE:-$state_dir/claude-native.json}"
    poll_state="${CLAUDE_FALLBACK_STATE_FILE:-$state_dir/claude-fallback.json}"
    mkdir -p "$(dirname "$usage_file")" "$(dirname "$poll_state")" 2>/dev/null

    snapshots=$(claude_snapshots)
    newest=$(printf '%s' "$snapshots" | jq 'map(.captured_at) | max // 0 | floor')
    age=$((now - newest))
    used=0
    claude_used_since "$newest" && used=1

    claude_error=""
    if [ -n "$access_token" ] &&
       [ "$now" -ge "$(claude_int .retry_at "$poll_state")" ] &&
       [ $((now - $(claude_int .checked_at "$poll_state"))) -ge 60 ] &&
       { [ "$age" -ge 900 ] || { [ "$used" = 1 ] && [ "$age" -ge 60 ]; }; }; then
        claude_poll_api
        [ -n "$claude_error" ] || {
            snapshots=$(claude_snapshots)
            newest=$now
            age=0
            used=0
        }
    fi

    # The newest full snapshot (Claude Code or oauth) is the base. A newer status
    # line snapshot replaces its windows, because it has no model-scoped limits.
    data=$(printf '%s' "$snapshots" | jq -c --arg plan "$plan" --argjson now "$now" \
        --argjson stale "$([ "$used" = 1 ] && [ "$age" -ge 300 ] && echo true || echo false)" '
        select(length > 0)
        | (map(select(.source != "native")) | max_by(.captured_at)) as $base
        | (map(select(.source == "native")) | max_by(.captured_at)) as $native
        | (if $base == null then $native
           elif $native != null and $native.captured_at > $base.captured_at then
               $native + {entries: (
                   [$base.entries[] | . as $e | ($native.entries | map(select(.name == $e.name)) | first) // $e]
                   + [$native.entries[] | select(.name as $n | $base.entries | map(.name) | index($n) | not)])}
           else $base end)
        | {
            status: "ok",
            plan: $plan,
            source: .source,
            capturedAt: .captured_at,
            stale: $stale,
            entries: [.entries[] | if .resetAt > 0 and .resetAt <= $now
                then .percentUsed = 0 | .resetAt = 0 else . end]
          }
    ' 2>/dev/null)

    if [ -n "$data" ]; then
        printf '%s\n' "$data"
    elif [ -n "$claude_error" ]; then
        printf '%s\n' "$claude_error"
    elif [ -n "$access_token" ]; then
        aiq_status unavailable usage_pending "Claude usage data is not available yet. Send a Claude Code message, then refresh AI Quotas."
    else
        aiq_status unavailable not_authenticated "Claude is not logged in. Run claude in a terminal and sign in, then refresh AI Quotas."
    fi
}
