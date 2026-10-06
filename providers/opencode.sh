# OpenCode Go usage windows.
#
# GET https://opencode.ai/zen/go/v1/usage with an OpenCode Go API key.
# Key order: plugin setting or env, then the key saved by opencode /connect.
#
# Env: OPENCODE_GO_API_KEY, OPENCODE_API_KEY, OPENCODE_DATA_DIR

fetch_opencode() {
    key="${OPENCODE_GO_API_KEY:-${OPENCODE_API_KEY:-}}"
    if [ -z "$key" ]; then
        data_dir="${OPENCODE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode}"
        key=$(jq -r '."opencode-go".key // empty' "$data_dir/auth.json" 2>/dev/null)
    fi
    if [ -z "$key" ]; then
        aiq_status unavailable not_authenticated "OpenCode Go is not connected. Run opencode /connect and choose OpenCode Go, or set an API key in plugin settings."
        return
    fi

    headers=$(aiq_headers opencode "Authorization: Bearer $key")
    aiq_request "$headers" https://opencode.ai/zen/go/v1/usage

    case "$http_code" in
        2??)
            aiq_parse "Could not parse OpenCode usage" '
                def entry($name; $window):
                    if ($window | type) != "object" then empty
                    elif (($window.status // "ok") != "ok") then empty
                    else
                        {
                            name: $name,
                            percentUsed: ($window.percent | num | clamp_pct),
                            resetAt: ($window.resetsAt | timestamp)
                        }
                    end;
                (.usage // error("no usage data")) as $usage |
                [
                    entry("Rolling"; $usage.rolling),
                    entry("Weekly"; $usage.weekly),
                    entry("Monthly"; $usage.monthly)
                ] as $entries |
                if ($entries | length) == 0 then error("no quota windows")
                else {status: "ok", entries: $entries}
                end
            '
            ;;
        401) aiq_status error auth_expired "OpenCode Go rejected the API key. Run opencode /connect again, or update the API key in plugin settings." ;;
        403) aiq_status error access_denied "OpenCode Go usage access was denied for this key." ;;
        *) aiq_http_failure "$http_code" "the OpenCode Go usage service" ;;
    esac
}
