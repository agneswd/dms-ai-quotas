# Mistral AI monthly API and Vibe Code budgets.
#
# GET https://api.mistral.ai/v1/billing/budget for monthly usage percentages and
# reset timestamps, plus a best-effort GET https://api.mistral.ai/v1/billing/subscription
# for the plan name.
#
# Key order: MISTRAL_API_KEY (plugin setting or env), AIQ_VAULT_MISTRAL keyring
# entry, then Mistral Vibe's local .env or keyring entry when VIBE_HOME exists.
#
# Env: MISTRAL_API_KEY, AIQ_VAULT_MISTRAL, VIBE_HOME (default ~/.vibe)

# Read MISTRAL_API_KEY from a dotenv file (e.g. ~/.vibe/.env), stripping quotes.
mistral_env_key() {
    _env_file="$1/.env"
    [ -r "$_env_file" ] || return 0
    awk '
        /^[[:space:]]*(export[[:space:]]+)?MISTRAL_API_KEY[[:space:]]*=/ {
            sub(/^[[:space:]]*(export[[:space:]]+)?MISTRAL_API_KEY[[:space:]]*=[[:space:]]*/, "")
            sub(/[[:space:]]*$/, "")
            if ((substr($0, 1, 1) == "\"" && substr($0, length($0), 1) == "\"") ||
                (substr($0, 1, 1) == "\047" && substr($0, length($0), 1) == "\047")) {
                $0 = substr($0, 2, length($0) - 2)
            }
            val = $0
        }
        END { if (val != "") printf "%s", val }
    ' "$_env_file" 2>/dev/null
}

# Read MISTRAL_API_KEY from Mistral Vibe's freedesktop keyring entry.
mistral_vibe_keyring_key() {
    command -v secret-tool >/dev/null 2>&1 || return 0
    for _svc in ai.mistral.vibe vibe; do
        _val=$(timeout "${AIQ_VAULT_TIMEOUT:-3}" secret-tool lookup service "$_svc" username MISTRAL_API_KEY 2>/dev/null || true)
        if [ -n "$_val" ] && [ "$_val" != "vibe-cli-oidc" ]; then
            printf '%s' "$_val"
            return 0
        fi
    done
}

fetch_mistral() {
    key="${MISTRAL_API_KEY:-}"
    [ "$key" != "vibe-cli-oidc" ] || key=""
    [ -n "$key" ] || key=$(aiq_vault_key mistral)
    if [ -z "$key" ]; then
        vibe_home="${VIBE_HOME:-$HOME/.vibe}"
        if [ -d "$vibe_home" ]; then
            key=$(mistral_env_key "$vibe_home")
            [ "$key" != "vibe-cli-oidc" ] || key=""
            [ -n "$key" ] || key=$(mistral_vibe_keyring_key)
        fi
    fi
    if [ -z "$key" ]; then
        aiq_status unavailable not_authenticated "Set your Mistral API key in plugin settings, AIQ_VAULT_MISTRAL for a keyring entry, or sign in with Mistral Vibe."
        return
    fi

    headers=$(aiq_headers mistral "Authorization: Bearer $key")
    aiq_request "$headers" https://api.mistral.ai/v1/billing/budget

    case "$http_code" in
        2??)
            budget_body=$http_body
            aiq_request "$headers" https://api.mistral.ai/v1/billing/subscription
            case "$http_code" in
                2??) sub_body=$http_body ;;
                *) sub_body='null' ;;
            esac
            sub_json=$(printf '%s' "$sub_body" | jq -c 'if type == "object" then . else null end' 2>/dev/null) || sub_json='null'
            [ -n "$sub_json" ] || sub_json='null'
            http_body=$budget_body
            aiq_parse "Could not parse Mistral budget response" '
                def budget_entry($name; $b; $sub_payg):
                    if ($b | type) != "object" or ($b.initial_budget | num // 0) <= 0
                       or ($b.usage_percentage | num // null) == null then empty
                    else
                        {
                            name: $name,
                            percentUsed: ($b.usage_percentage | num | round2 | clamp_pct),
                            resetAt: ($b.reset_at | timestamp),
                            initialBudget: ($b.initial_budget | num),
                            currency: (if ($b.currency | type) == "string" and $b.currency != "" then $b.currency else null end),
                            paygEnabled: ((if $b.payg_enabled != null then $b.payg_enabled else $sub_payg end) == true)
                        }
                    end;
                def plan_title($sub):
                    if ($sub | type) != "object" then null
                    elif $sub.enterprise == true then "Enterprise"
                    else
                        (($sub.plan_name // "") | ascii_upcase) as $p |
                        ({"FREE": "Free", "INDIVIDUAL": "Pro", "EDU": "Student", "TEAM": "Team"}[$p]
                         // (if $p == "" then null else $sub.plan_name end))
                    end;
                if type != "object" or ((has("api_budget") | not) and (has("vibe_budget") | not)) then
                    error("no budget data")
                else
                    [
                        budget_entry("API"; .api_budget; ($sub.payg_enabled? // false)),
                        budget_entry("Vibe"; .vibe_budget; ($sub.vibe_payg_enabled? // false))
                    ] as $entries |
                    if ($entries | length) == 0 then
                        {status: "unavailable", reason: "no_quota", error: "Mistral reported no monthly budget for this account."}
                    else
                        {
                            status: "ok",
                            plan: plan_title($sub),
                            entries: $entries
                        }
                    end
                end
            ' --argjson sub "$sub_json"
            ;;
        401) aiq_status error auth_expired "Mistral rejected this API key. Check the key in plugin settings." ;;
        403) aiq_status error access_denied "Mistral denied billing budget access for this key. The key needs organization usage permission." ;;
        *) aiq_http_failure "$http_code" "the Mistral API" ;;
    esac
}
