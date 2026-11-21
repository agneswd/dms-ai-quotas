# Codex usage limits. The newer of two snapshots wins:
#
#   local  The rate limits that Codex writes into its session files
#          (CODEX_HOME/sessions/**/rollout-*.jsonl) on each turn. Free.
#   api    GET https://chatgpt.com/backend-api/wham/usage with the token in
#          CODEX_HOME/auth.json. Also gives the plan and credits.
#
# The module asks the API at most once a minute, or on a forced refresh, and
# keeps the last answer in a state file. So the fast refresh can read the local
# snapshot every few seconds without extra requests.
#
# A window whose reset time has passed shows as unused.
#
# Env: CODEX_HOME (default ~/.codex), CODEX_STATE_FILE

# jq: one window to an entry. The name comes from the window length: Free and
# Go plans have a 30-day window, paid plans a 5-hour and a weekly window.
CODEX_JQ_WINDOW='
def window_name($seconds; $fallback):
    if $seconds >= 2592000 then "Monthly"
    elif $seconds >= 604800 then "Weekly"
    elif $seconds >= 14400 then "5h"
    else $fallback
    end;
# A missing window gives no entry: num is empty for null, so entry is too.
def entry($name; $seconds; $used; $reset):
    {name: window_name($seconds; $name), percentUsed: ($used | clamp_pct), resetAt: $reset};
'

# Print the local snapshot as {captured_at, plan, entries}, or nothing.
codex_local_snapshot() {
    sessions="${CODEX_HOME:-$HOME/.codex}/sessions"
    [ -d "$sessions" ] || return 0
    # Only files written after the last API answer can hold newer limits.
    touch -d "@$1" "$auth_dir/codex-since" 2>/dev/null || return 0
    newest=$(find "$sessions" -name 'rollout-*.jsonl' -newer "$auth_dir/codex-since" \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)
    [ -n "$newest" ] || return 0
    # tac reads from the end, so a long session file costs little. Model-specific
    # limits share the event, so take the newest line for the main "codex" limit.
    tac "$newest" 2>/dev/null | grep -m 50 '"rate_limits":{' |
        jq -c -R --argjson now "$now" "$AIQ_JQ_DEFS $CODEX_JQ_WINDOW"'
            fromjson? | .payload.rate_limits as $r
            | select(($r.limit_id // "codex") == "codex")
            | [
                entry("5h"; ($r.primary.window_minutes // 0) * 60;
                    ($r.primary.used_percent? | num); ($r.primary.resets_at? | number)),
                entry("Weekly"; ($r.secondary.window_minutes // 0) * 60;
                    ($r.secondary.used_percent? | num); ($r.secondary.resets_at? | number))
              ] as $entries
            | select($entries | length > 0)
            | {captured_at: (.timestamp | timestamp), plan: ($r.plan_type // ""), entries: $entries}
        ' 2>/dev/null | head -n 1
}

# Ask the usage API and store the result in the state file. A failure is stored
# as the error to show, and the last good answer stays.
codex_poll_api() {
    if [ -n "$account_id" ]; then
        headers=$(aiq_headers codex "Authorization: Bearer $access_token" "ChatGPT-Account-Id: $account_id")
    else
        headers=$(aiq_headers codex "Authorization: Bearer $access_token")
    fi
    aiq_request "$headers" https://chatgpt.com/backend-api/wham/usage -H "User-Agent: codex-cli"

    case "$http_code" in
        2??)
            result=$(aiq_parse "Could not parse Codex usage" "$CODEX_JQ_WINDOW"'
                . as $root
                | ($root.spend_control.individual_limit // null) as $credit
                | [
                    entry("5h"; ($root.rate_limit.primary_window.limit_window_seconds? | number);
                        ($root.rate_limit.primary_window.used_percent? | num);
                        ($root.rate_limit.primary_window | .reset_at // (if .reset_after_seconds then $now + .reset_after_seconds else 0 end) | number)),
                    entry("Weekly"; ($root.rate_limit.secondary_window.limit_window_seconds? | number);
                        ($root.rate_limit.secondary_window.used_percent? | num);
                        ($root.rate_limit.secondary_window | .reset_at // (if .reset_after_seconds then $now + .reset_after_seconds else 0 end) | number)),
                    (if ($root.code_review_rate_limit.primary_window | type) == "object" then
                        {name: "Code Review",
                         percentUsed: ($root.code_review_rate_limit.primary_window.used_percent | number | clamp_pct),
                         resetAt: ($root.code_review_rate_limit.primary_window.reset_at | number)}
                     else empty end),
                    (if ($credit | type) == "object" and ($credit.remaining_percent? | num) != null then
                        {name: "Credits",
                         percentUsed: (100 - ($credit.remaining_percent | num) | clamp_pct),
                         resetAt: ($credit | .resets_at // .reset_at | number)}
                     else empty end)
                  ] as $entries
                | if ($entries | length) == 0 then error("no quota windows") else
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
            ' --argjson now "$now")
            ;;
        401) result=$(aiq_status error auth_expired "Codex login expired. Run codex login again, then refresh AI Quotas.") ;;
        403) result=$(aiq_status error access_denied "Codex usage access was denied for this account.") ;;
        *) result=$(aiq_http_failure "$http_code" "the Codex usage service") ;;
    esac
    rm -f "$headers"

    old=$(jq -c 'select(type == "object")' "$state" 2>/dev/null)
    tmp=$(mktemp "$(dirname "$state")/.codex-api.XXXXXX") || return
    jq -c -n --argjson old "${old:-"{}"}" --argjson now "$now" --argjson result "$result" \
        --arg account "$account" '
        $old + {checked_at: $now, account: $account, error: null}
        + (if $result.status == "ok" then {captured_at: $now, result: $result}
           else {error: $result} end)
    ' > "$tmp" && mv "$tmp" "$state" || rm -f "$tmp"
}

fetch_codex() {
    auth="${CODEX_HOME:-$HOME/.codex}/auth.json"
    access_token=$(jq -r '.tokens.access_token // empty' "$auth" 2>/dev/null)
    account_id=$(jq -r '.tokens.account_id // empty' "$auth" 2>/dev/null)
    if [ -z "$access_token" ]; then
        aiq_status unavailable not_authenticated "Codex is not logged in. Run codex login in a terminal, then refresh AI Quotas."
        return
    fi

    state="${CODEX_STATE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/codex-api.json}"
    mkdir -p "$(dirname "$state")" 2>/dev/null
    # A state file from another account does not count. It keeps a hash, not the account ID.
    account=$(printf '%s' "$account_id" | sha256sum | cut -d' ' -f1)
    jq -e --arg account "$account" '.account == $account' "$state" >/dev/null 2>&1 || rm -f "$state"
    checked_at=$(jq -r '.checked_at // 0 | floor' "$state" 2>/dev/null)
    case "$checked_at" in ''|*[!0-9]*) checked_at=0 ;; esac
    if [ "${AIQ_FORCE_REFRESH:-0}" = "1" ] || [ $((now - checked_at)) -ge 60 ]; then
        codex_poll_api
    fi

    api_at=$(jq -r '.captured_at // 0 | floor' "$state" 2>/dev/null)
    case "$api_at" in ''|*[!0-9]*) api_at=0 ;; esac
    local_snapshot=$(codex_local_snapshot "$api_at")

    # The API answer is the base: it has the plan, credits, and code review.
    # A newer local snapshot replaces its windows by name.
    jq -c -n --slurpfile state "$state" --argjson now "$now" \
        --argjson local "${local_snapshot:-null}" '
        ($state[0] // {}) as $s
        | ($s.result // null) as $api
        | if $local != null and $local.captured_at > ($s.captured_at // 0) then
              ($api // {status: "ok", plan: ($local.plan | if . == "" then "ChatGPT" else . end)})
              + {source: "local", capturedAt: $local.captured_at,
                 entries: ($local.entries + [($api.entries // [])[]
                     | select(.name as $n | $local.entries | map(.name) | index($n) | not)])}
          elif $api != null and $s.error == null then
              $api + {source: "api", capturedAt: $s.captured_at}
          else $s.error // empty
          end
        | if (.entries | type) == "array" then
              .entries |= map(if (.resetAt // 0) > 0 and .resetAt <= $now
                  then .percentUsed = 0 | .resetAt = 0 else . end)
          else . end
    ' 2>/dev/null || aiq_status error "" "Could not read Codex usage."
}
