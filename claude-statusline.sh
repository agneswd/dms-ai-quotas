#!/bin/sh
# Capture Claude Code's native rate-limit data for AI Quotas.
set -u
umask 077

cache="${CLAUDE_USAGE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/claude-native.json}"
mkdir -p "$(dirname "$cache")" 2>/dev/null || exit 0
now=$(date +%s)
data=$(jq -c --argjson now "$now" '
    [
        {name: "5h", window: .rate_limits.five_hour},
        {name: "Weekly", window: .rate_limits.seven_day}
    ]
    | map(select(.window.used_percentage != null))
    | map({
        name: .name,
        percentUsed: .window.used_percentage,
        resetAt: (.window.resets_at // 0)
    })
    | if length == 0 then empty else {captured_at: $now, entries: .} end
' 2>/dev/null) || exit 0
[ -n "$data" ] || exit 0

tmp=$(mktemp "$(dirname "$cache")/.claude-native.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT HUP INT TERM
printf '%s\n' "$data" > "$tmp" && mv "$tmp" "$cache"
