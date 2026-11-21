#!/bin/sh
# Capture Antigravity CLI (agy) statusLine quota data for AI Quotas.
#
# Optional: AI Quotas reads quotas from the API when an agy or T3 Code sign-in is
# available. This snapshot is the fallback. Set it as the agy statusLine command in
# ~/.gemini/antigravity-cli/settings.json, with "stack_with_default": true.
#
# Saves {captured_at, email, plan, buckets: [{bucketId, remainingFraction, resetAt}]}.
# providers/antigravity.sh names the buckets.
set -u
umask 077

cache="${ANTIGRAVITY_USAGE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/antigravity-native.json}"
mkdir -p "$(dirname "$cache")" 2>/dev/null || exit 0
now=$(date +%s)
data=$(jq -c --argjson now "$now" '
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
    select(type == "object" and (.quota | type) == "object")
    | [.quota | to_entries[]
        | select((.value | type) == "object" and .value.disabled != true)
        | (.value.remaining_fraction | if type == "number" then . elif type == "string" then tonumber? else null end) as $rem
        | select($rem != null)
        | {bucketId: .key, remainingFraction: $rem, resetAt: (.value | reset_at)}] as $buckets
    | if ($buckets | length) == 0 then empty
      else {captured_at: $now, email: (.email // ""), plan: (.plan_tier // ""), buckets: $buckets}
      end
' 2>/dev/null) || exit 0
[ -n "$data" ] || exit 0

tmp=$(mktemp "$(dirname "$cache")/.antigravity-native.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT HUP INT TERM
printf '%s\n' "$data" > "$tmp" && mv "$tmp" "$cache"
exit 0
