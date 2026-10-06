# Shared helpers for provider modules. fetch-usage.sh sources this file.
#
# Each provider module defines fetch_<id>. The function prints one JSON object:
#   {"status":"ok", ...provider data}
#   {"status":"unavailable"|"error", "reason":"...", "error":"message for the popout"}
# Provider functions run in their own subshell, so they can set variables freely.
# Credentials go into private header files under $auth_dir, never into arguments.

# jq definitions that provider filters can use. Prepend them to a filter.
AIQ_JQ_DEFS='
def num:
    if type == "number" then .
    elif type == "string" then (tonumber? // empty)
    else empty
    end;
def number: (num // 0);
def clamp_pct: if . < 0 then 0 elif . > 100 then 100 else . end;
def round2: (. * 100 | round) / 100;
def timestamp:
    if type == "number" then (if . >= 100000000000 then (. / 1000 | floor) else . end)
    elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$") then (tonumber | timestamp)
    elif type == "string" and . != "" then
        ((sub("\\.[0-9]+"; "") | sub("\\+00:?00$"; "Z") | fromdateiso8601?) // 0)
    else 0
    end;
'

# Print a status object. Usage: aiq_status STATUS REASON MESSAGE
# Empty REASON or MESSAGE values are left out.
aiq_status() {
    jq -cn --arg status "$1" --arg reason "$2" --arg error "$3" '
        {status: $status}
        + (if $reason == "" then {} else {reason: $reason} end)
        + (if $error == "" then {} else {error: $error} end)'
}

# Print the status for an HTTP failure that has no provider-specific meaning.
# Usage: aiq_http_failure HTTP_CODE SERVICE_NAME (for example "the Codex usage service")
aiq_http_failure() {
    case "$1" in
        429) aiq_status error rate_limited "Too many requests to $2. Try again shortly." ;;
        000|'') aiq_status error network "Could not reach $2. Check your connection and try again." ;;
        *) aiq_status error http_error "The request to $2 failed with HTTP $1. Try again shortly." ;;
    esac
}

# Write request headers to a private file and print its path.
# Usage: aiq_headers NAME "Header: value"...
aiq_headers() {
    _file="$auth_dir/$1"
    shift
    printf '%s\n' "$@" > "$_file"
    printf '%s' "$_file"
}

# Send a request with headers from a private file. Sets http_code and http_body.
# Usage: aiq_request HEADER_FILE URL [curl options...]
aiq_request() {
    _headers=$1
    _url=$2
    shift 2
    _response=$(curl -s -m "${AIQ_HTTP_TIMEOUT:-15}" -w '\n%{http_code}' \
        -H "@$_headers" \
        -H "Accept: application/json" \
        "$@" "$_url" 2>/dev/null)
    http_code=$(printf '%s\n' "$_response" | tail -n 1)
    http_body=$(printf '%s\n' "$_response" | sed '$d')
}

# Parse $http_body with a jq filter that has access to AIQ_JQ_DEFS.
# Prints FALLBACK_MESSAGE as an error status when the filter fails or prints nothing.
# Usage: aiq_parse FALLBACK_MESSAGE FILTER [jq options...]
aiq_parse() {
    _fallback=$1
    _filter=$2
    shift 2
    if _parsed=$(printf '%s' "$http_body" | jq -c "$@" "$AIQ_JQ_DEFS $_filter" 2>/dev/null) &&
       [ -n "$_parsed" ]; then
        printf '%s\n' "$_parsed"
    else
        aiq_status error "" "$_fallback"
    fi
}
