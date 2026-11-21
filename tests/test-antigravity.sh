#!/bin/sh
set -eu

# Exercise the complete fetch command against an isolated HOME and agy settings file.
# Failures: agy not installed, settings file missing, user settings lost or reformatted
# away, a custom or disabled status line overwritten, invalid JSON overwritten, settings
# file mode changed, an installed hook that does not run, network requests, malformed
# status line input, expired windows, and stale snapshots.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/home"

# The provider must not use the network. Any curl call fails the fetch and is logged.
cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$AIQ_TEST_REQUESTS"
exit 99
EOF
chmod +x "$test_dir/bin/curl"

home="$test_dir/home"
agy_dir="$home/.gemini/antigravity-cli"
settings="$agy_dir/settings.json"
native_file="$home/.cache/dms-ai-quotas/antigravity-native.json"
requests="$test_dir/requests.txt"
run_fetch() {
    env PATH="$test_dir/bin:$PATH" HOME="$home" XDG_CACHE_HOME="$home/.cache" \
        AIQ_TEST_REQUESTS="$requests" \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_COPILOT_ENABLED=0 AIQ_OPENCODE_ENABLED=0 \
        AIQ_DEEPSEEK_ENABLED=0 AIQ_OPENROUTER_ENABLED=0 AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=1 AIQ_ZAI_ENABLED=0 AIQ_KIMI_ENABLED=0 AIQ_FORCE_REFRESH=1 \
        sh "$repo/fetch-usage.sh" > "$test_dir/result.json"
    cat "$test_dir/result.json"
}
expect_untouched() {
    printf '%s\n' "$1" > "$settings"
    run_fetch | jq -e --arg reason "$2" '.antigravity.reason == $reason' >/dev/null
    test "$(cat "$settings")" = "$1"
}

# agy is not installed: report it, and create nothing in HOME.
run_fetch | jq -e '.antigravity.status == "unavailable" and .antigravity.reason == "not_installed"' >/dev/null
test ! -e "$home/.gemini"

# agy is installed but has no settings file: create one with the hook.
mkdir -p "$agy_dir"
run_fetch | jq -e '.antigravity.status == "unavailable" and .antigravity.reason == "waiting_for_agy"' >/dev/null
jq -e '.statusLine.type == "command" and .statusLine.stack_with_default == true
    and (.statusLine.command | endswith("antigravity-statusline.sh'"'"'"))' "$settings" >/dev/null

# Empty command, as agy writes it: install the hook and keep every other setting and the file mode.
printf '%s\n' '{"model":"Gemini","statusLine":{"type":"","command":"","enabled":true},"trustedWorkspaces":["/w"]}' > "$settings"
chmod 644 "$settings"
run_fetch | jq -e '.antigravity.reason == "waiting_for_agy"' >/dev/null
test "$(stat -c %a "$settings")" = 644
jq -e '.model == "Gemini" and .trustedWorkspaces == ["/w"] and .statusLine.enabled == true
    and .statusLine.type == "command" and .statusLine.stack_with_default == true' "$settings" >/dev/null
test -z "$(find "$agy_dir" -name '.settings.json.*' -print -quit)"
installed=$(cat "$settings")

# A second fetch keeps the installed hook as it is.
run_fetch | jq -e '.antigravity.reason == "waiting_for_agy"' >/dev/null
test "$(cat "$settings")" = "$installed"

# Settings that belong to the user stay byte-identical.
expect_untouched '{"statusLine":{"type":"command","command":"my-line.sh"}}' custom_status_line
expect_untouched '{"statusLine":{"enabled":false}}' status_line_disabled
expect_untouched '{"statusLine":' invalid_settings
expect_untouched '["not","an","object"]' invalid_settings
expect_untouched '{"statusLine":"text"}' invalid_settings

# The installed command runs the capture script. An agy turn then makes the fetch report quotas.
printf '%s\n' "$installed" > "$settings"
hook=$(jq -r '.statusLine.command' "$settings")
printf '%s\n' '{"plan_tier":"Pro","quota":{"gemini-5h":{"remaining_fraction":0.8,"reset_in_seconds":3600}}}' |
    env HOME="$home" XDG_CACHE_HOME="$home/.cache" sh -c "$hook"
run_fetch | jq -e '.antigravity.status == "ok" and .antigravity.plan == "Pro"
    and .antigravity.entries[0].name == "Gemini Models - Five Hour Limit Remaining"
    and .antigravity.entries[0].percentUsed == 20' >/dev/null
rm -f "$native_file"

# Status line capture writes a private snapshot with empty stdout and skips disabled buckets.
now=$(date +%s)
stdout_capture=$(printf '%s\n' '{
    "email": "developer@example.invalid",
    "plan_tier": "Pro",
    "quota": {
        "claude-5h": {"remaining_fraction": 0.45, "reset_time": "2030-01-01T00:00:00Z"},
        "gemini-weekly": {"remaining_fraction": 0.9378, "reset_time": "2030-01-02T00:00:00.5+00:00"},
        "gemini-5h": {"remaining_fraction": 0.8, "reset_in_seconds": 3600},
        "disabled-bucket": {"remaining_fraction": 0.1, "disabled": true},
        "credits-only": {"remaining_amount": 50}
    }
}' | ANTIGRAVITY_USAGE_FILE="$native_file" sh "$repo/antigravity-statusline.sh")
[ -z "$stdout_capture" ]
[ "$(stat -c %a "$native_file")" = "600" ]
jq -e --argjson now "$now" '
    .email == "developer@example.invalid"
    and .plan == "Pro"
    and (.entries | length) == 3
    and .entries[0].name == "Gemini Models - Five Hour Limit Remaining"
    and .entries[0].percentUsed == 20
    and .entries[0].resetAt >= ($now + 3595)
    and .entries[1] == {name: "Gemini Models - Weekly Limit Remaining", percentUsed: 6, resetAt: 1893542400}
    and .entries[2] == {name: "Claude Models - Five Hour Limit Remaining", percentUsed: 55, resetAt: 1893456000}
' "$native_file" >/dev/null

# Empty or malformed statusLine input exits 0 and preserves the previous snapshot.
printf '%s\n' '{"agent_state":"idle"}' | ANTIGRAVITY_USAGE_FILE="$native_file" sh "$repo/antigravity-statusline.sh"
printf '%s\n' 'not-json' | ANTIGRAVITY_USAGE_FILE="$native_file" sh "$repo/antigravity-statusline.sh"
jq -e '(.entries | length) == 3' "$native_file" >/dev/null

# Expired windows roll over to 0%.
jq --argjson past $((now - 60)) '.entries[0].resetAt = $past' "$native_file" > "$native_file.tmp" && mv "$native_file.tmp" "$native_file"
run_fetch | jq -e '
    .antigravity.status == "ok"
    and .antigravity.source == "native"
    and .antigravity.stale == false
    and .antigravity.plan == "Pro"
    and .antigravity.email == "developer@example.invalid"
    and .antigravity.entries[0] == {name: "Gemini Models - Five Hour Limit Remaining", percentUsed: 0, resetAt: 0}
    and .antigravity.entries[1] == {name: "Gemini Models - Weekly Limit Remaining", percentUsed: 6, resetAt: 1893542400}
' >/dev/null

# A snapshot from more than an hour ago is still used, but marked stale.
jq --argjson old $((now - 3600)) '.captured_at = $old' "$native_file" > "$native_file.tmp" && mv "$native_file.tmp" "$native_file"
run_fetch | jq -e '.antigravity.status == "ok" and .antigravity.stale == true' >/dev/null

if [ -s "$requests" ]; then
    printf '%s\n' 'The Antigravity provider made a network request.' >&2
    exit 1
fi
if [ -n "${AIQ_TEST_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$AIQ_TEST_ARTIFACT_DIR"
    cp "$test_dir/result.json" "$AIQ_TEST_ARTIFACT_DIR/antigravity-result.json"
    cp "$settings" "$AIQ_TEST_ARTIFACT_DIR/antigravity-settings.json"
fi
printf '%s\n' 'Antigravity fetch checks passed.'
