# Z.ai (GLM) Coding Plan quotas.
#
# GET https://<host>/api/monitor/usage/quota/limit with a Coding Plan API key.
# Each limit has a type, a window (unit + number), a used percentage, optional
# credit counts, and nextResetTime in epoch milliseconds. Z.ai reports some
# failures as HTTP 200 with {"success": false, "code": ..., "msg": ...}.
#
# Env:
#   ZAI_API_KEY    Coding Plan API key (plugin setting)
#   ZAI_API_HOST   api.z.ai (global, default) or open.bigmodel.cn (China)

fetch_zai() {
    key="${ZAI_API_KEY:-}"
    host="${ZAI_API_HOST:-api.z.ai}"
    if [ -z "$key" ]; then
        aiq_status unavailable not_authenticated "Set your Z.ai Coding Plan API key in plugin settings."
        return
    fi
    # The key goes only to the two official hosts.
    case "$host" in
        api.z.ai|open.bigmodel.cn) ;;
        *)
            aiq_status error invalid_config "Unknown Z.ai API host $host. Use api.z.ai or open.bigmodel.cn."
            return
            ;;
    esac

    headers=$(aiq_headers zai "Authorization: Bearer $key")
    aiq_request "$headers" "https://$host/api/monitor/usage/quota/limit" -H "Accept-Language: en-US,en"

    case "$http_code" in
        2??)
            aiq_parse "Could not parse Z.ai quota response" '
                # Window length in minutes. Units: 1 day, 3 hour, 5 minute, 6 week.
                def window_minutes:
                    ({"1": 1440, "3": 60, "5": 1, "6": 10080}[(.unit | number | tostring)]) as $unit |
                    if $unit == null or (.number | number) <= 0 then null
                    else $unit * (.number | number)
                    end;
                def window_name($minutes):
                    if .type == "TIME_LIMIT" then "MCP"
                    elif $minutes == 300 or ($minutes == null and .type == "TOKENS_LIMIT") then "5h"
                    elif $minutes == 1440 then "Daily"
                    elif $minutes == 10080 then "Weekly"
                    elif $minutes == null then "Quota"
                    elif $minutes % 1440 == 0 then "\($minutes / 1440)d"
                    elif $minutes % 60 == 0 then "\($minutes / 60)h"
                    else "\($minutes)m"
                    end;
                # Prefer credit counts over the rounded percentage when Z.ai sends them.
                def percent_used:
                    (.usage | num // null) as $limit |
                    (.currentValue | num // null) as $current |
                    (.remaining | num // null) as $remaining |
                    (if $current != null then $current
                     elif $remaining != null and $limit != null then $limit - $remaining
                     else null
                     end) as $used |
                    if $limit != null and $limit > 0 and $used != null then ($used * 100 / $limit | round2)
                    else (.percentage | number)
                    end | clamp_pct;
                . as $root |
                if .success == false or ((.code // 200) | tostring) != "200" then
                    {
                        status: "error",
                        reason: (if ((.code | tostring) | test("^(401|100[0-9])$")) then "auth_expired" else "api_error" end),
                        error: ("Z.ai rejected the request: " + (.msg // .message // "unknown error") + ". Check the key in plugin settings.")
                    }
                elif (.data.limits | type) != "array" then error("no limits")
                else
                    [
                        .data.limits[]
                        | select(.type == "TOKENS_LIMIT" or .type == "CREDIT_LIMIT" or .type == "TIME_LIMIT")
                        | window_minutes as $minutes
                        | {
                            name: window_name($minutes),
                            percentUsed: percent_used,
                            resetAt: (.nextResetTime | timestamp),
                            order: (if .type == "TIME_LIMIT" then 1000000 else ($minutes // 300) end)
                          }
                    ]
                    | sort_by(.order) | map(del(.order)) as $entries
                    | if ($entries | length) == 0 then
                        {status: "unavailable", reason: "no_quota", error: "Z.ai reported no Coding Plan quota for this key."}
                      else
                        {status: "ok", plan: ($root.data.level // $root.data.planName // null), entries: $entries}
                      end
                end
            '
            ;;
        401|403) aiq_status error auth_expired "Z.ai rejected this API key. Check the key in plugin settings." ;;
        *) aiq_http_failure "$http_code" "the Z.ai quota service" ;;
    esac
}
