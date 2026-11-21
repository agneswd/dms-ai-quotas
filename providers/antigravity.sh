# Antigravity agent and model quotas.
#
# Reads the snapshot that antigravity-statusline.sh writes on each agy turn
# ($ANTIGRAVITY_USAGE_FILE, default $XDG_CACHE_HOME/dms-ai-quotas/antigravity-native.json),
# rolling over expired windows to 0% used. A snapshot older than one hour is marked stale.
#
# Google rejects direct quota requests from clients other than agy (UNSUPPORTED_CLIENT),
# so the status line hook is the only data source. When the agy settings file
# ($HOME/.gemini/antigravity-cli/settings.json) has no statusLine command, this module
# installs the hook there. It never changes a statusLine command that the user set.

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
                stale: ($now - (.captured_at // 0) >= 3600),
                entries: [.entries[] | if (.resetAt // 0) > 0 and .resetAt <= $now
                    then .percentUsed = 0 | .resetAt = 0 else . end]
              }
        ' "$usage_file" 2>/dev/null) || native=""
        if [ -n "$native" ]; then
            printf '%s\n' "$native"
            return
        fi
    fi

    settings_dir="$HOME/.gemini/antigravity-cli"
    settings="$settings_dir/settings.json"
    script="$plugin_dir/antigravity-statusline.sh"
    if [ ! -d "$settings_dir" ]; then
        aiq_status unavailable not_installed "Antigravity CLI (agy) is not installed. Install agy, or disable Antigravity in plugin settings."
        return
    fi
    [ -s "$settings" ] || printf '%s\n' '{}' > "$settings"

    # What the statusLine block holds now: empty, ours, disabled, custom, or invalid.
    hook=$(jq -r '
        if type != "object" then "invalid"
        elif (.statusLine // {} | type) != "object" then "invalid"
        elif .statusLine.enabled == false then "disabled"
        elif (.statusLine.command // "" | type) != "string" then "invalid"
        elif (.statusLine.command // "" | test("^\\s*$")) then "empty"
        elif (.statusLine.command | contains("antigravity-statusline.sh")) then "ours"
        else "custom"
        end
    ' "$settings" 2>/dev/null) || hook="invalid"

    case "$hook" in
        empty)
            # Write a copy next to the file with the same mode, then rename it in place,
            # so agy never reads a partial file.
            tmp=$(mktemp "$settings_dir/.settings.json.XXXXXX") || return
            if jq --arg script "$script" '
                .statusLine = ((.statusLine // {})
                    + {type: "command", command: ("sh " + ($script | @sh)), stack_with_default: true})
            ' "$settings" > "$tmp" 2>/dev/null; then
                chmod --reference="$settings" "$tmp" 2>/dev/null
                mv "$tmp" "$settings"
            else
                rm -f "$tmp"
                aiq_status error settings_write_failed "Could not update $settings."
                return
            fi
            aiq_status unavailable waiting_for_agy "Send a message in agy to load Antigravity quotas."
            ;;
        ours)
            aiq_status unavailable waiting_for_agy "Send a message in agy to load Antigravity quotas."
            ;;
        disabled)
            aiq_status unavailable status_line_disabled "The agy status line is turned off. Set statusLine.enabled to true in $settings."
            ;;
        custom)
            aiq_status unavailable custom_status_line "agy already runs a custom status line command. Pipe its input to $script to load Antigravity quotas."
            ;;
        *)
            aiq_status error invalid_settings "Could not read $settings."
            ;;
    esac
}
