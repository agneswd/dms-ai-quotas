# Grok billing usage from the local grok login (OAuth, not an API key).
#
# GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
#
# Env: GROK_HOME (default ~/.grok)

fetch_grok() {
    auth="${GROK_HOME:-$HOME/.grok}/auth.json"
    access_token=$(jq -r 'to_entries[0].value.key // empty' "$auth" 2>/dev/null)
    email=$(jq -r 'to_entries[0].value.email // empty' "$auth" 2>/dev/null)
    if [ -z "$access_token" ]; then
        aiq_status unavailable not_authenticated "Grok is not logged in. Run grok login in a terminal, then refresh AI Quotas."
        return
    fi

    headers=$(aiq_headers grok "Authorization: Bearer $access_token")
    aiq_request "$headers" "https://cli-chat-proxy.grok.com/v1/billing?format=credits" \
        -H "User-Agent: dms-ai-quotas" \
        -H "x-grok-client-mode: cli"

    case "$http_code" in
        2??)
            aiq_parse "Could not parse Grok usage response" '
                def amount: if type == "object" then (.val | number) else number end;
                .config as $c |
                ($c.currentPeriod.end // $c.billingPeriodEnd // null | timestamp) as $reset |
                ($c.onDemandCap | amount) as $cap |
                ($c.onDemandUsed | amount) as $used |
                (
                    if $c.creditUsagePercent != null then
                        [{name: "Billing", kind: "plan", percentUsed: ($c.creditUsagePercent | number | clamp_pct), resetAt: $reset}]
                    elif $cap > 0 then
                        [{name: "Billing", kind: "on_demand", percentUsed: (100 * $used / $cap | clamp_pct), resetAt: $reset}]
                    elif $c.currentPeriod != null or $c.billingPeriodEnd != null then
                        [{name: "Billing", kind: "plan", percentUsed: 0, resetAt: $reset}]
                    else []
                    end
                ) as $entries |
                if ($entries | length) == 0 then
                    {status: "unavailable", reason: "no_quota"}
                else
                    {
                        status: "ok",
                        plan: (if $c.isUnifiedBillingUser == true then "SuperGrok" else "Grok" end),
                        email: (if $email == "" then null else $email end),
                        entries: $entries
                    }
                end
            ' --arg email "$email"
            ;;
        401|403) aiq_status error auth_expired "Grok login expired. Run grok login again, then refresh AI Quotas." ;;
        *) aiq_http_failure "$http_code" "the Grok usage service" ;;
    esac
}
