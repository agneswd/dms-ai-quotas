# Kimi Code plan quotas.
#
# GET <base>/usages with a Kimi Code API key, or with the login token of the
# kimi CLI. The CLI token lives about 15 minutes and only kimi refreshes it,
# so the API key is the steady option. The plugin never refreshes tokens.
#
# Current responses carry usages.limit_5h, limit_7d, limit_month_total, and
# limit_month_code with a used_ratio from 0 to 1. Older responses carry
# limits[] windows and a usage summary with limit, used, and remaining counts.
#
# Env:
#   KIMI_API_KEY         Kimi Code API key (plugin setting)
#   KIMI_CODE_HOME       kimi CLI home (default ~/.kimi-code, then ~/.kimi)
#   KIMI_CODE_BASE_URL   https://api.kimi.com/coding/v1 (default) or https://api.kimi.ai/coding/v1

# Print the kimi CLI credential file, or nothing.
kimi_credentials() {
    for home in "${KIMI_CODE_HOME:-}" "$HOME/.kimi-code" "$HOME/.kimi"; do
        if [ -n "$home" ] && [ -f "$home/credentials/kimi-code.json" ]; then
            printf '%s' "$home/credentials/kimi-code.json"
            return
        fi
    done
}

fetch_kimi() {
    key="${KIMI_API_KEY:-}"
    rejected="Kimi rejected this API key. Check the key in plugin settings."
    if [ -z "$key" ]; then
        creds=$(kimi_credentials)
        key=$(jq -r '.access_token // empty' "$creds" 2>/dev/null)
        expires_at=$(jq -r '(.expires_at // 0) | tonumber? // 0 | floor' "$creds" 2>/dev/null)
        case "$expires_at" in ''|*[!0-9]*) expires_at=0 ;; esac
        if [ -z "$key" ]; then
            aiq_status unavailable not_authenticated "Kimi Code is not connected. Sign in with kimi, or set a Kimi Code API key in plugin settings."
            return
        fi
        if [ "$expires_at" -le $((now + 60)) ]; then
            aiq_status error auth_expired "The kimi login token expired. Run kimi to refresh it, or set a Kimi Code API key in plugin settings for steady updates."
            return
        fi
        rejected="Kimi rejected the kimi login token. Run kimi to sign in again, or set a Kimi Code API key in plugin settings."
    fi

    base="${KIMI_CODE_BASE_URL:-https://api.kimi.com/coding/v1}"
    base="${base%/}"
    # The key goes only to the two official hosts.
    case "$base" in
        https://api.kimi.com/*|https://api.kimi.ai/*) ;;
        *)
            aiq_status error invalid_config "Unknown Kimi Code address $base. Use https://api.kimi.com/coding/v1 or https://api.kimi.ai/coding/v1."
            return
            ;;
    esac

    headers=$(aiq_headers kimi "Authorization: Bearer $key")
    aiq_request "$headers" "$base/usages" -H "User-Agent: dms-ai-quotas"

    case "$http_code" in
        2??)
            aiq_parse "Could not parse Kimi Code usage response" '
                def ratio_entry($name; $window):
                    if ($window | type) != "object" or ($window.used_ratio | num // null) == null then empty
                    else
                        {
                            name: $name,
                            percentUsed: ($window.used_ratio | num * 100 | round2 | clamp_pct),
                            resetAt: ($window.reset_time | timestamp)
                        }
                    end;
                def count_entry($name; $detail):
                    if ($detail | type) != "object" then empty else
                        ($detail.limit | num // null) as $limit |
                        ($detail.used | num // null) as $counted |
                        ($detail.remaining | num // null) as $remaining |
                        (if $counted != null then $counted
                         elif $remaining != null and $limit != null then $limit - $remaining
                         else null
                         end) as $used |
                        if $limit == null or $limit <= 0 or $used == null then empty
                        else
                            {
                                name: $name,
                                percentUsed: ($used * 100 / $limit | round2 | clamp_pct),
                                resetAt: (($detail.resetTime // $detail.reset_time // $detail.resetAt) | timestamp)
                            }
                        end
                    end;
                # Window length, such as {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, as a name.
                def window_name:
                    (.window.duration | number) as $duration |
                    ((.window.timeUnit // "") | ascii_upcase | sub("^TIME_UNIT_"; "") | sub("S$"; "")) as $unit |
                    ({"MINUTE": 1, "HOUR": 60, "DAY": 1440, "WEEK": 10080, "MONTH": 43200}[$unit]) as $scale |
                    if $scale == null or $duration <= 0 then "Limit"
                    else ($duration * $scale) as $minutes |
                        if $minutes == 300 then "5h"
                        elif $minutes == 1440 then "Daily"
                        elif $minutes == 10080 then "Weekly"
                        elif $minutes >= 40320 and $minutes <= 44640 then "Monthly"
                        elif $minutes % 60 == 0 then "\($minutes / 60)h"
                        else "\($minutes)m"
                        end
                    end;
                . as $root |
                (if ($root.usages | type) == "object" then
                    [
                        ratio_entry("5h"; $root.usages.limit_5h),
                        ratio_entry("Weekly"; $root.usages.limit_7d),
                        ratio_entry("Monthly"; $root.usages.limit_month_total),
                        ratio_entry("Monthly Code"; $root.usages.limit_month_code)
                    ]
                 else
                    [($root.limits // [])[] | count_entry(window_name; .detail)]
                    + [count_entry("Weekly"; $root.usage)]
                 end) as $entries |
                if ($entries | length) == 0 then
                    {status: "unavailable", reason: "no_quota", error: "Kimi Code reported no usage windows for this account."}
                else
                    {
                        status: "ok",
                        plan: ($root.user.membership.level // null
                            | if type == "string" then sub("^LEVEL_"; "") | ascii_downcase | gsub("_"; " ") else null end),
                        entries: $entries
                    }
                end
            '
            ;;
        401|403) aiq_status error auth_expired "$rejected" ;;
        404) aiq_status error access_denied "Kimi Code usage is not available for this account. Check that the key belongs to a Kimi Code plan." ;;
        *) aiq_http_failure "$http_code" "the Kimi Code usage service" ;;
    esac
}
