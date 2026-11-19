# Antigravity agent and model quotas.
#
# Prefers the local snapshot written by antigravity-statusline.sh
# ($ANTIGRAVITY_USAGE_FILE, default $XDG_CACHE_HOME/dms-ai-quotas/antigravity-native.json),
# rolling over expired windows to 0% used. When no snapshot is present, falls
# back to reading the agy keyring entry and querying daily-cloudcode-pa.googleapis.com.
# agy owns the login: this module never refreshes the token.

antigravity_request() {
    aiq_request "$headers" "https://daily-cloudcode-pa.googleapis.com/v1internal:$1" \
        -H "Content-Type: application/json" \
        -H "User-Agent: dms-ai-quotas" \
        --data "$2"
}

fetch_antigravity() {
    usage_file="${ANTIGRAVITY_USAGE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dms-ai-quotas/antigravity-native.json}"
    if [ -s "$usage_file" ]; then
        native=$(jq -c --argjson now "$now" '
            select(type == "object" and (.entries | type) == "array" and (.entries | length) > 0)
            | {
                status: "ok",
                email: (.email // ""),
                plan: (.plan // ""),
                source: "native",
                capturedAt: (.captured_at // 0),
                entries: [.entries[] | if (.resetAt // 0) > 0 and .resetAt <= $now
                    then .percentUsed = 0 | .resetAt = 0 else . end]
              }
        ' "$usage_file" 2>/dev/null) || native=""
        if [ -n "$native" ]; then
            printf '%s\n' "$native"
            return
        fi
    fi

    if ! command -v secret-tool >/dev/null 2>&1; then
        aiq_status unavailable missing_dependency "Antigravity requires antigravity-statusline.sh or secret-tool. Configure statusLine in ~/.gemini/antigravity-cli/settings.json, or disable Antigravity in plugin settings."
        return
    fi

    keyring=$(secret-tool lookup service gemini username antigravity 2>/dev/null || true)
    token=$(printf '%s' "$keyring" | jq -r '.token.access_token // empty' 2>/dev/null)
    expiry=$(printf '%s' "$keyring" | jq -r '.token.expiry // empty' 2>/dev/null)
    account=$(printf '%s' "$keyring" | jq -r '.account // .email // .id_token_email // empty' 2>/dev/null)
    case "$expiry" in
        '') expires_at=0 ;;
        *[!0-9]*) expires_at=$(date -d "$expiry" +%s 2>/dev/null || printf '0') ;;
        *) if [ "${#expiry}" -ge 13 ]; then expires_at=$((expiry / 1000)); else expires_at=$expiry; fi ;;
    esac

    expired_message="Antigravity login expired. Open agy to refresh the login, then refresh AI Quotas."
    if [ -z "$token" ]; then
        aiq_status unavailable not_authenticated "Antigravity is not logged in. Start agy and sign in, then refresh AI Quotas."
        return
    fi
    if [ "$expires_at" -le $((now + 60)) ]; then
        aiq_status error auth_expired "$expired_message"
        return
    fi

    headers=$(aiq_headers antigravity "Authorization: Bearer $token")
    antigravity_request loadCodeAssist '{"metadata":{"ideType":"ANTIGRAVITY"}}'
    case "$http_code" in
        2??)
            project=$(printf '%s' "$http_body" | jq -r 'select((.cloudaicompanionProject | type) == "string") | .cloudaicompanionProject' 2>/dev/null)
            plan=$(printf '%s' "$http_body" | jq -r '.paidTier.name // .currentTier.name // empty' 2>/dev/null)
            if [ -z "$project" ]; then
                if printf '%s' "$http_body" | jq -e '(.ineligibleTiers // []) | any(.reasonCode == "UNSUPPORTED_CLIENT")' >/dev/null 2>&1; then
                    aiq_status error unsupported_client "Google rejected direct Antigravity quota requests (UNSUPPORTED_CLIENT). Configure antigravity-statusline.sh in ~/.gemini/antigravity-cli/settings.json and run a turn in agy."
                else
                    aiq_status error "" "Failed to load Antigravity companion project"
                fi
                return
            fi
            antigravity_request retrieveUserQuotaSummary "$(jq -cn --arg p "$project" '{project: $p}')"
            ;;
    esac

    case "$http_code" in
        2??)
            aiq_parse "Could not parse Antigravity quota response" '
                if (.groups | type) != "array" then error("missing quota groups") else
                {
                    status: "ok",
                    email: $email,
                    plan: $plan,
                    entries: [.groups[] | .displayName as $group | .buckets[] | {
                        name: ($group + " - " + .displayName),
                        percentUsed: ((1 - (.remainingFraction // 1.0)) * 100 | round),
                        resetAt: (.resetTime | timestamp)
                    }]
                }
                end
            ' --arg email "$account" --arg plan "$plan"
            ;;
        401) aiq_status error auth_expired "$expired_message" ;;
        403) aiq_status error access_denied "Antigravity quota access was denied for this account." ;;
        *) aiq_http_failure "$http_code" "the Antigravity quota service" ;;
    esac
}
