# OpenRouter credit balance.
#
# GET https://openrouter.ai/api/v1/credits. Some keys need management access.
#
# Env: OPENROUTER_API_KEY

fetch_openrouter() {
    key="${OPENROUTER_API_KEY:-}"
    if [ -z "$key" ]; then
        aiq_status unavailable not_authenticated "Set your OpenRouter API key in plugin settings."
        return
    fi

    headers=$(aiq_headers openrouter "Authorization: Bearer $key")
    aiq_request "$headers" https://openrouter.ai/api/v1/credits

    case "$http_code" in
        2??)
            aiq_parse "Could not parse OpenRouter credits response" '
                (.data // error("no credit data")) as $d |
                ($d.total_credits | number) as $purchased |
                ($d.total_usage | number) as $used |
                {
                    status: "ok",
                    balances: [{
                        currency: "USD",
                        total: (($purchased - $used) | tostring),
                        purchased: ($purchased | tostring),
                        used: ($used | tostring)
                    }]
                }
            '
            ;;
        401) aiq_status error auth_expired "OpenRouter rejected this API key. Check the key in plugin settings." ;;
        403) aiq_status error access_denied "OpenRouter denied credit access for this key. Create a management key at openrouter.ai/settings/management-keys and use it in plugin settings." ;;
        *) aiq_http_failure "$http_code" "the OpenRouter API" ;;
    esac
}
