# Codex usage limits from the local Codex login.
#
# GET https://chatgpt.com/backend-api/wham/usage with the token in CODEX_HOME/auth.json.
#
# Env: CODEX_HOME (default ~/.codex)

fetch_codex() {
    auth="${CODEX_HOME:-$HOME/.codex}/auth.json"
    access_token=$(jq -r '.tokens.access_token // empty' "$auth" 2>/dev/null)
    account_id=$(jq -r '.tokens.account_id // empty' "$auth" 2>/dev/null)
    if [ -z "$access_token" ]; then
        aiq_status unavailable not_authenticated "Codex is not logged in. Run codex login in a terminal, then refresh AI Quotas."
        return
    fi

    if [ -n "$account_id" ]; then
        headers=$(aiq_headers codex "Authorization: Bearer $access_token" "ChatGPT-Account-Id: $account_id")
    else
        headers=$(aiq_headers codex "Authorization: Bearer $access_token")
    fi
    aiq_request "$headers" https://chatgpt.com/backend-api/wham/usage -H "User-Agent: codex-cli"

    case "$http_code" in
        2??)
            aiq_parse "Could not parse Codex usage" '
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
                        ($window.used_percent? | num) as $used |
                        {
                            name: quota_name($name; $window),
                            percentUsed: ($used | clamp_pct),
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
            ' --argjson now "$now"
            ;;
        401) aiq_status error auth_expired "Codex login expired. Run codex login again, then refresh AI Quotas." ;;
        403) aiq_status error access_denied "Codex usage access was denied for this account." ;;
        *) aiq_http_failure "$http_code" "the Codex usage service" ;;
    esac
}
