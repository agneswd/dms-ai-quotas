#!/bin/sh
# Fetch AI coding provider usage from the CodexBar CLI, cache it, and print it.
#
# Reads the codexbar CLI JSON output for enabled providers, caches the result,
# and prints it to stdout for the DMS plugin to consume.
#
# Env:
#   CACHE_FILE              cache path (default $XDG_CACHE_HOME/dms-codexbar/usage.json)
#   CODEXBAR_PROVIDERS      comma-separated provider IDs (default: all enabled)
#   CODEXBAR_USAGE_MOCK     file with sample JSON (skips network; for tests)
#   CODEXBAR_CACHE_TTL      seconds before cache is stale (default: 55)
#
# Exit: 0 ok, 1 no data, 2 fetch/parse error.
set -u

cache="${CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-codexbar/usage.json}"
ttl="${CODEXBAR_CACHE_TTL:-55}"
mkdir -p "$(dirname "$cache")" 2>/dev/null
now=$(date +%s)

# Return cached data if fresh.
if [ -s "$cache" ]; then
    prev=$(jq -r '.captured_at // 0' "$cache" 2>/dev/null)
    case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
    if [ "$prev" -gt 0 ] && [ $((now - prev)) -lt "$ttl" ]; then
        cat "$cache"
        exit 0
    fi
fi

# Use mock data if provided (for testing).
if [ -n "${CODEXBAR_USAGE_MOCK:-}" ] && [ -f "$CODEXBAR_USAGE_MOCK" ]; then
    resp=$(cat "$CODEXBAR_USAGE_MOCK")
else
    # Build provider flag.
    provider_flag="--provider"
    provider_val="${CODEXBAR_PROVIDERS:-all}"

    # Fetch from codexbar CLI.
    resp=$(codexbar usage --format json --provider "$provider_val" --pretty 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ] || [ -z "$resp" ]; then
        # If codexbar returned nothing, try to read last good cache.
        if [ -s "$cache" ]; then
            cat "$cache"
            exit 0
        fi
        exit 2
    fi
fi

# Validate that we got a JSON array of provider objects.
echo "$resp" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    # Maybe it's a single object (one provider). Wrap in array.
    wrapped=$(echo "$resp" | jq -e 'type == "object"' >/dev/null 2>&1 && echo "[$resp]" || echo "[]")
    resp="$wrapped"
}

# Add captured_at timestamp and write cache.
out=$(echo "$resp" | jq --argjson now "$now" '[ .[] | . + {captured_at: $now} ]') || exit 2

tmp="$cache.tmp.$$"
printf '%s' "$out" > "$tmp" && mv -f "$tmp" "$cache"
printf '%s' "$out"
