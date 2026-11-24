#!/bin/sh
# Fetch usage for every enabled provider, merge, cache, and print one JSON line.
#
# Each provider lives in providers/<id>.sh and defines fetch_<id>. See
# providers/lib.sh for the output contract. Providers run in parallel.
#
# Env:
#   AIQ_<ID>_ENABLED   "0" to skip a provider, for example AIQ_CODEX_ENABLED=0 (default: "1")
#   AIQ_CACHE_TTL      seconds before the cache is stale (default: 55)
#   AIQ_FORCE_REFRESH  "1" to bypass the cache
#   AIQ_PROVIDERS      space-separated ids to refresh now, for example "claude". The
#                      others keep their cached results, and the cache keeps its age.
#   AIQ_USAGE_MOCK     file with sample JSON to print instead (for tests)
#   CACHE_FILE         cache path (default $XDG_CACHE_HOME/dms-ai-quotas/usage.json)
# Provider credentials and paths are listed at the top of each provider module.
set -u
umask 077

providers="claude codex copilot opencode zai kimi deepseek openrouter mistral grok antigravity"
plugin_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cache="${CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/usage.json}"
ttl="${AIQ_CACHE_TTL:-55}"
mkdir -p "$(dirname "$cache")" 2>/dev/null
now=$(date +%s)

# A partial refresh merges into the cache, so it needs one to merge into.
only="${AIQ_PROVIDERS:-}"
[ -z "$only" ] || [ -s "$cache" ] || only=""

if [ -z "$only" ] && [ "${AIQ_FORCE_REFRESH:-0}" != "1" ] && [ -s "$cache" ]; then
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

# Keep provider credentials out of process arguments. Remove private files on exit.
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/aiq-auth.XXXXXX") || exit 2
auth_dir="$work_dir/auth"
mkdir "$auth_dir" || exit 2
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

. "$plugin_dir/providers/lib.sh"

provider_enabled() {
    _var="AIQ_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_ENABLED"
    eval "_enabled=\${$_var:-1}"
    [ "$_enabled" = "1" ]
}

# Partial refresh: run only the requested providers.
[ -z "$only" ] || providers=$only

for id in $providers; do
    if provider_enabled "$id"; then
        . "$plugin_dir/providers/$id.sh"
        ("fetch_$id" > "$work_dir/$id.json") &
    else
        printf '%s\n' '{"status":"unavailable"}' > "$work_dir/$id.json"
    fi
done
wait

# Merge provider results in a stable order. A provider that crashed or printed
# invalid JSON becomes an error instead of breaking the whole result.
set -- --argjson captured_at "$now"
for id in $providers; do
    result=$(jq -c 'select(type == "object" and (.status | type) == "string")' "$work_dir/$id.json" 2>/dev/null)
    [ -n "$result" ] || result=$(aiq_status error "" "Could not read $id usage.")
    set -- "$@" --argjson "$id" "$result"
done
if [ -n "$only" ]; then
    out=$(jq -c "$@" '. + ($ARGS.named | del(.captured_at))' "$cache") || exit 2
else
    out=$(jq -c -n "$@" '$ARGS.named') || exit 2
fi

# A transient failure (network, HTTP 429 or 5xx, an unreadable answer) keeps the
# last good result for up to a day, marked stale, so one bad request does not
# blank a provider. Login and access errors always show. The age comes from the
# result's own capturedAt, else from the cache. Windows whose reset passed show as unused.
prev=$(jq -c 'select(type == "object")' "$cache" 2>/dev/null) || prev=""
out=$(printf '%s' "$out" | jq -c --argjson prev "${prev:-"{}"}" --argjson now "$now" '
    with_entries(if .key == "captured_at" then . else
        .key as $id | .value as $new | ($prev[$id] // null) as $old
        | ($old.capturedAt // $prev.captured_at // 0) as $old_at
        | .value = (
            if $new.status == "error"
                and (($new.reason // "") | IN("", "network", "rate_limited", "http_error"))
                and $old.status? == "ok" and $now - $old_at < 86400 then
                $old + {stale: true, capturedAt: $old_at}
                | if (.entries | type) == "array" then
                      .entries |= map(if (.resetAt // 0) > 0 and .resetAt <= $now
                          then .percentUsed = 0 | .resetAt = 0 else . end)
                  else . end
            else $new end)
    end)') || exit 2

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
