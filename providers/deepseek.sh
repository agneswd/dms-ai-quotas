# DeepSeek API account balance.
#
# GET https://api.deepseek.com/user/balance with the API key from plugin settings.
#
# Env: DEEPSEEK_API_KEY

fetch_deepseek() {
    key="${DEEPSEEK_API_KEY:-}"
    if [ -z "$key" ]; then
        aiq_status unavailable not_authenticated "Set your DeepSeek API key in plugin settings."
        return
    fi

    headers=$(aiq_headers deepseek "Authorization: Bearer $key")
    aiq_request "$headers" https://api.deepseek.com/user/balance

    case "$http_code" in
        2??)
            aiq_parse "Could not parse DeepSeek balance response" '
                {
                    status: "ok",
                    isAvailable: .is_available,
                    balances: [.balance_infos[] | {
                        currency: .currency,
                        total: .total_balance,
                        granted: .granted_balance,
                        toppedUp: .topped_up_balance
                    }]
                }
            '
            ;;
        401) aiq_status error auth_expired "DeepSeek rejected this API key. Check the key in plugin settings." ;;
        *) aiq_http_failure "$http_code" "the DeepSeek API" ;;
    esac
}
