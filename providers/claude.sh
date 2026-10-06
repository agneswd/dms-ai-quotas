# Claude plan usage from native status line data, with a five-minute API fallback.
#
# claude-statusline.sh writes the native snapshot. When that snapshot is older
# than five minutes, this module asks api.anthropic.com/api/oauth/usage at most
# once per five minutes and honors Retry-After on HTTP 429.
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

# Read a non-negative integer field from a JSON file, or 0.
claude_int() {
    _value=$(jq -r "$1 // 0" "$2" 2>/dev/null)
    case "$_value" in ''|*[!0-9]*) _value=0 ;; esac
    printf '%s' "$_value"
}

# Ask the OAuth usage API and store a fresh snapshot. Sets claude_error on failure.
claude_poll_api() {
    response_headers="$auth_dir/claude-response"
    headers=$(aiq_headers claude "Authorization: Bearer $access_token")
    aiq_request "$headers" https://api.anthropic.com/api/oauth/usage \
        -D "$response_headers" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: dms-ai-quotas"
    retry_at=0

    case "$http_code" in
        2??)
            snapshot=$(printf '%s' "$http_body" | jq -c --argjson now "$now" "$AIQ_JQ_DEFS"'
                [
                    {name: "5h", window: .five_hour},
                    {name: "Weekly", window: .seven_day}
                ]
                | map(select(.window.utilization != null))
                | map({
                    name: .name,
                    percentUsed: (.window.utilization | number | clamp_pct),
                    resetAt: (.window.resets_at | timestamp)
                })
                | if length == 0 then error("no quota windows")
                  else {captured_at: $now, source: "oauth", entries: .}
                  end
            ' 2>/dev/null) || snapshot=""
            if [ -n "$snapshot" ]; then
                tmp=$(mktemp "$(dirname "$usage_file")/.claude-usage.XXXXXX")
                printf '%s\n' "$snapshot" > "$tmp" && mv "$tmp" "$usage_file"
            else
                claude_error=$(aiq_status error "" "Could not parse Claude usage response")
            fi
            ;;
        401)
            claude_error=$(aiq_status error auth_expired "Claude login expired. Start Claude Code to refresh it, then refresh AI Quotas.")
            ;;
        403)
            claude_error=$(aiq_status error access_denied "Claude usage access was denied for this account.")
            ;;
        429)
            retry_after=$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' "$response_headers" | tr -d '\r' | tail -n 1)
            case "$retry_after" in
                '') retry_at=$((now + 3600)) ;;
                *[!0-9]*) retry_at=$(date -d "$retry_after" +%s 2>/dev/null || printf '%s' $((now + 3600))) ;;
                *) retry_at=$((now + retry_after)) ;;
            esac
            [ "$retry_at" -gt "$now" ] || retry_at=$((now + 3600))
            ;;
    esac
    rm -f "$response_headers" "$headers"

    tmp=$(mktemp "$(dirname "$fallback_state")/.claude-fallback.XXXXXX")
    jq -n -c --argjson checked "$now" --argjson retry "$retry_at" \
        '{checked_at: $checked, retry_at: $retry}' > "$tmp" &&
        mv "$tmp" "$fallback_state"
}

fetch_claude() {
    creds="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    access_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
    plan=$(claude_plan_name \
        "$(jq -r '.claudeAiOauth.subscriptionType // empty' "$creds" 2>/dev/null)" \
        "$(jq -r '.claudeAiOauth.rateLimitTier // empty' "$creds" 2>/dev/null)")

    state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas"
    usage_file="${CLAUDE_USAGE_FILE:-$state_dir/claude-native.json}"
    fallback_state="${CLAUDE_FALLBACK_STATE_FILE:-$state_dir/claude-fallback.json}"
    mkdir -p "$(dirname "$usage_file")" "$(dirname "$fallback_state")" 2>/dev/null

    claude_error=""
    if [ -n "$access_token" ] &&
       [ $((now - $(claude_int .captured_at "$usage_file"))) -ge 300 ] &&
       [ $((now - $(claude_int .checked_at "$fallback_state"))) -ge 300 ] &&
       [ "$now" -ge "$(claude_int .retry_at "$fallback_state")" ]; then
        claude_poll_api
    fi

    if [ -s "$usage_file" ]; then
        data=$(jq -c --arg plan "$plan" --argjson now "$now" '
            select((.entries | type) == "array" and (.entries | length) > 0)
            | ((.captured_at | tonumber?) // 0) as $captured
            | {
                status: "ok",
                plan: $plan,
                source: (.source // "native"),
                capturedAt: $captured,
                stale: (($now - $captured) >= 300),
                entries: .entries
              }
        ' "$usage_file" 2>/dev/null)
        if [ -n "$data" ]; then
            printf '%s\n' "$data"
        else
            aiq_status error "" "Could not parse Claude usage data"
        fi
    elif [ -n "$claude_error" ]; then
        printf '%s\n' "$claude_error"
    elif [ -n "$access_token" ]; then
        aiq_status unavailable usage_pending "Claude usage data is not available yet. Send a Claude Code message, then refresh AI Quotas."
    else
        aiq_status unavailable not_authenticated "Claude is not logged in. Run claude in a terminal and sign in, then refresh AI Quotas."
    fi
}
