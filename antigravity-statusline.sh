#!/bin/sh
# Capture Antigravity CLI (agy) statusLine quota data for AI Quotas.
set -u
umask 077

cache="${ANTIGRAVITY_USAGE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/antigravity-native.json}"
mkdir -p "$(dirname "$cache")" 2>/dev/null || exit 0
now=$(date +%s)
data=$(jq -c --argjson now "$now" '
    def cap:
        if length == 0 then ""
        else (.[0:1] | ascii_upcase) + .[1:]
        end;
    def clamp_pct: if . < 0 then 0 elif . > 100 then 100 else . end;
    def round2: (. * 100 | round) / 100;
    def parse_ts:
        if type == "number" then (if . >= 100000000000 then (. / 1000 | floor) else (. | floor) end)
        elif type == "string" and . != "" then
            ((sub("\\.[0-9]+"; "") | sub("\\+00:?00$"; "Z") | fromdateiso8601?) // 0)
        else 0
        end;
    def reset_at:
        (.reset_time | parse_ts) as $ts |
        if $ts > 0 then $ts
        elif (.reset_in_seconds | type) == "number" and .reset_in_seconds > 0 then ($now + (.reset_in_seconds | floor))
        else 0
        end;
    def group_label($p):
        if $p == "gemini" then "Gemini Models"
        elif $p == "claude" then "Claude Models"
        elif $p == "gpt" or $p == "openai" then "OpenAI Models"
        else ($p | cap)
        end;
    def group_rank($p):
        if $p == "gemini" then 0
        elif $p == "claude" then 1
        elif $p == "gpt" or $p == "openai" then 2
        else 3
        end;
    def window_label($w):
        if $w == "5h" or $w == "five-hour" or $w == "five_hour" then "5 hour usage limit"
        elif $w == "weekly" or $w == "7d" or $w == "seven-day" or $w == "seven_day" then "Weekly usage limit"
        elif $w == "daily" or $w == "1d" or $w == "24h" then "Daily usage limit"
        elif $w == "monthly" or $w == "30d" then "Monthly usage limit"
        else ($w | gsub("[-_]"; " ") | cap)
        end;
    def window_rank($w):
        if $w == "5h" or $w == "five-hour" or $w == "five_hour" then 0
        elif $w == "daily" or $w == "1d" or $w == "24h" then 1
        elif $w == "weekly" or $w == "7d" or $w == "seven-day" or $w == "seven_day" then 2
        elif $w == "monthly" or $w == "30d" then 3
        else 4
        end;
    def bucket_meta($k):
        ($k | ascii_downcase) as $low |
        ($low | index("-")) as $dash |
        if $dash != null and $dash > 0 and $dash < (($low | length) - 1) then
            ($low[0:$dash]) as $prefix |
            ($low[($dash + 1):]) as $rest |
            {
                name: (group_label($prefix) + " - " + window_label($rest)),
                rank: [group_rank($prefix), window_rank($rest), $low]
            }
        else
            {
                name: ($k | gsub("[-_]"; " ") | cap),
                rank: [9, 9, $low]
            }
        end;
    select(type == "object" and (.quota | type) == "object")
    | . as $root
    | (.quota | to_entries
        | map(select((.value | type) == "object" and .value.disabled != true))
        | map(. + {rem: (.value.remaining_fraction | if type == "number" then . elif type == "string" then tonumber? else null end)})
        | map(select(.rem != null))
        | map(
            bucket_meta(.key) as $m |
            {
                rank: $m.rank,
                entry: {
                    name: $m.name,
                    percentUsed: ((1 - .rem) * 100 | clamp_pct | round2),
                    resetAt: (.value | reset_at)
                }
            }
        )
        | sort_by(.rank)
        | map(.entry)) as $entries
    | if ($entries | length) == 0 then empty
      else {
          captured_at: $now,
          email: ($root.email // ""),
          plan: ($root.plan_tier // ""),
          entries: $entries
      }
      end
' 2>/dev/null) || exit 0
[ -n "$data" ] || exit 0

tmp=$(mktemp "$(dirname "$cache")/.antigravity-native.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT HUP INT TERM
printf '%s\n' "$data" > "$tmp" && mv "$tmp" "$cache"
exit 0
