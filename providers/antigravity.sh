# Antigravity agent and model quotas. The newer of two snapshots wins:
#
#   api     POST retrieveUserQuotaSummary on daily-cloudcode-pa.googleapis.com, then
#           cloudcode-pa.googleapis.com. The daily host meters personal accounts, so
#           its value for a bucket wins. Google answers only agy, so the request sends
#           the agy User-Agent. Asked at most once a minute, or on a forced refresh.
#   native  The snapshot that antigravity-statusline.sh writes on each agy turn
#           ($ANTIGRAVITY_USAGE_FILE), for setups without a usable token.
#
# The access token comes from the agy keyring entry while it is valid; only agy
# renews it. Otherwise it comes from a T3 Code Antigravity sign-in
# (~/.t3/userdata/providers/antigravity/*/antigravity-acp/acp_token.json), which
# carries its own OAuth client, so this module renews a token from it in memory.
#
# Env: ANTIGRAVITY_USAGE_FILE, ANTIGRAVITY_STATE_FILE

# jq: one bucket {bucketId, window?, remainingFraction, resetAt} to an entry. The
# name comes from the bucket ID, so the API and the status line agree.
ANTIGRAVITY_JQ_ENTRY='
def clamp_pct01: if . < 0 then 0 elif . > 1 then 1 else . end;
def family_rank:
    if . == "Gemini" then 0 elif . == "Gemini Argon" then 1
    elif . == "Gemini Carbon" then 2 elif . == "Claude & GPT" then 3 else 4 end;
def bucket_entry:
    .bucketId as $id
    | (.window // ($id | capture("-(?<w>5h|weekly)$").w) // "") as $window
    | (if ($id | startswith("gemini-argon-")) then "Gemini Argon"
       elif ($id | startswith("gemini-carbon-")) then "Gemini Carbon"
       elif ($id | startswith("gemini-")) then "Gemini"
       elif ($id | startswith("3p-")) then "Claude & GPT"
       else ($id | sub("-(5h|weekly)$"; "") | gsub("[-_]"; " ")) end) as $family
    | {
        name: ($family + " - "
            + (if $window == "5h" then "5 hour limit" elif $window == "weekly" then "Weekly limit" else "Limit" end)),
        percentUsed: ((1 - (.remainingFraction | clamp_pct01)) * 100 | round),
        resetAt: (.resetAt // 0),
        rank: [($family | family_rank), (if $window == "5h" then 0 elif $window == "weekly" then 1 else 2 end), $id]
      };
def entries_from_buckets: [.[] | bucket_entry] | sort_by(.rank) | map(del(.rank));
'

ANTIGRAVITY_UA="antigravity/hub/2.24.0 (aidev_client; os_type=linux; arch=$(uname -m | sed 's/^x86_64$/x64/; s/^aarch64$/arm64/'); cl=963137146)"

# Set access_token and project from the first usable sign-in. Returns 1 when none.
antigravity_token() {
    project=""
    if command -v secret-tool >/dev/null 2>&1; then
        # A locked keyring raises a prompt and waits, so the lookup has a time limit.
        keyring=$(timeout "${AIQ_VAULT_TIMEOUT:-3}" secret-tool lookup service gemini username antigravity 2>/dev/null || true)
        access_token=$(printf '%s' "$keyring" | jq -r '.token.access_token // empty' 2>/dev/null)
        expiry=$(printf '%s' "$keyring" | jq -r '.token.expiry // empty' 2>/dev/null)
        expires_at=$(date -d "$expiry" +%s 2>/dev/null || printf '0')
        [ -n "$access_token" ] && [ "$expires_at" -gt $((now + 60)) ] && return 0
    fi
    for token_file in "$HOME"/.t3/userdata/providers/antigravity/*/antigravity-acp/acp_token.json; do
        [ -s "$token_file" ] || continue
        # The refresh request body holds the secret, so it goes in a private file.
        jq -r '"client_id=\(.client_id | @uri)&client_secret=\(.client_secret | @uri)&refresh_token=\(.refresh_token | @uri)&grant_type=refresh_token"' \
            "$token_file" > "$auth_dir/antigravity-refresh" 2>/dev/null || continue
        headers=$(aiq_headers antigravity-oauth "Content-Type: application/x-www-form-urlencoded")
        aiq_request "$headers" https://oauth2.googleapis.com/token --data "@$auth_dir/antigravity-refresh"
        rm -f "$auth_dir/antigravity-refresh"
        case "$http_code" in 2??) ;; *) continue ;; esac
        access_token=$(printf '%s' "$http_body" | jq -r '.access_token // empty' 2>/dev/null)
        project=$(jq -r '.project_id // empty' "$token_file" 2>/dev/null)
        [ -n "$access_token" ] && return 0
    done
    access_token=""
    return 1
}

# Ask both hosts and store the result in the state file. A failure is stored as
# the error to show, and the last good answer stays.
antigravity_poll_api() {
    if ! antigravity_token; then
        result=$(aiq_status unavailable not_authenticated "Antigravity is not signed in, or its sign-in expired. Use agy or T3 Code once, then refresh AI Quotas.")
    else
        headers=$(aiq_headers antigravity "Authorization: Bearer $access_token")
        body=$(jq -cn --arg p "$project" 'if $p == "" then {} else {project: $p} end')
        buckets="[]"
        first_code=""
        for host in daily-cloudcode-pa cloudcode-pa; do
            aiq_request "$headers" "https://$host.googleapis.com/v1internal:retrieveUserQuotaSummary" \
                -H "Content-Type: application/json" -H "User-Agent: $ANTIGRAVITY_UA" --data "$body"
            [ -n "$first_code" ] || first_code=$http_code
            case "$http_code" in 2??) ;; *) continue ;; esac
            # An untouched bucket reports a rolling reset one full window ahead, which is not a real reset.
            buckets=$(printf '%s' "$http_body" | jq -c --argjson have "$buckets" --argjson now "$now" "$AIQ_JQ_DEFS"'
                [(.groups // [{buckets: .buckets}])[] | (.buckets // [])[]
                 | select(.disabled != true and (.bucketId | type) == "string" and (.remainingFraction | type) == "number")
                 | (.resetTime | timestamp) as $reset
                 | ({"5h": 18000, "weekly": 604800}[.window // ""] // null) as $length
                 | {bucketId, window, remainingFraction,
                    resetAt: (if .remainingFraction == 1 and .description == null and $length != null
                                 and (($reset - $now - $length) | fabs) <= 60 then 0 else $reset end)}] as $new
                | $have + [$new[] | select(.bucketId as $id | $have | map(.bucketId) | index($id) | not)]
            ' 2>/dev/null) || buckets="[]"
        done
        rm -f "$headers"
        if [ "$buckets" != "[]" ]; then
            result=$(printf '%s' "$buckets" | jq -c "$AIQ_JQ_DEFS $ANTIGRAVITY_JQ_ENTRY"'{status: "ok", entries: entries_from_buckets}')
        else
            case "$first_code" in
                2??) result=$(aiq_status error "" "Antigravity did not return usable quota information.") ;;
                401) result=$(aiq_status error auth_expired "Antigravity sign-in expired. Use agy or T3 Code once, then refresh AI Quotas.") ;;
                403) result=$(aiq_status error access_denied "Antigravity quota access was denied for this account.") ;;
                *) result=$(aiq_http_failure "$first_code" "the Antigravity quota service") ;;
            esac
        fi
    fi

    old=$(jq -c 'select(type == "object")' "$state" 2>/dev/null)
    tmp=$(mktemp "$(dirname "$state")/.antigravity-api.XXXXXX") || return
    jq -c -n --argjson old "${old:-"{}"}" --argjson now "$now" --argjson result "$result" '
        $old + {checked_at: $now, error: null}
        + (if $result.status == "ok" then {captured_at: $now, result: $result} else {error: $result} end)
    ' > "$tmp" && mv "$tmp" "$state" || rm -f "$tmp"
}

fetch_antigravity() {
    state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas"
    state="${ANTIGRAVITY_STATE_FILE:-$state_dir/antigravity-api.json}"
    usage_file="${ANTIGRAVITY_USAGE_FILE:-$state_dir/antigravity-native.json}"
    mkdir -p "$(dirname "$state")" 2>/dev/null

    checked_at=$(jq -r '.checked_at // 0 | floor' "$state" 2>/dev/null)
    case "$checked_at" in ''|*[!0-9]*) checked_at=0 ;; esac
    if [ "${AIQ_FORCE_REFRESH:-0}" = "1" ] || [ $((now - checked_at)) -ge 60 ]; then
        antigravity_poll_api
    fi

    native=$(jq -c "$AIQ_JQ_DEFS $ANTIGRAVITY_JQ_ENTRY"'
        select((.buckets | type) == "array" and (.buckets | length) > 0)
        | {captured_at: (.captured_at // 0), email: (.email // ""), plan: (.plan // ""),
           entries: (.buckets | entries_from_buckets)}' "$usage_file" 2>/dev/null) || native=""

    # Old data stays correct: a window whose reset passed shows as unused. agy writes
    # the native snapshot only on a turn, so one older than an hour is marked stale.
    jq -c -n --slurpfile state "$state" --argjson now "$now" --argjson native "${native:-null}" '
        ($state[0] // {}) as $s
        | if $native != null and $native.captured_at > ($s.captured_at // 0) then
              {status: "ok", email: $native.email, plan: $native.plan, source: "native",
               capturedAt: $native.captured_at, stale: ($now - $native.captured_at >= 3600),
               entries: $native.entries}
          elif $s.result != null and $s.error == null then
              $s.result + {source: "api", capturedAt: $s.captured_at}
          else $s.error // empty
          end
        | if (.entries | type) == "array" then
              .entries |= map(if .resetAt > 0 and .resetAt <= $now then .percentUsed = 0 | .resetAt = 0 else . end)
          else . end
    ' 2>/dev/null || aiq_status error "" "Could not read Antigravity usage."
}
