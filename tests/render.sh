#!/bin/sh
set -eu

# Render the plugin offscreen with the real DMS components and the demo data in
# tests/fixtures/demo-usage.json. This runs the whole path: daemon, fetch-usage.sh,
# plugin state, bar pill, popout tabs, and settings page.
#
# Saves one PNG per provider tab, vertical.png, settings.png, pill.txt, and
# quickshell.log to AIQ_TEST_ARTIFACT_DIR (default tests/render-output).
# Failures: QML errors in plugin files, a pill that does not show the expected
# value for every provider, pins that cannot fall back or be removed, and
# missing images.
#
# Needs DankMaterialShell, quickshell (qs), dbus-run-session, and jq. The render
# uses temporary XDG directories and its own D-Bus session, so it does not
# touch the running shell.
#
# Env:
#   DMS_SHELL_DIR          DMS shell directory (default: the one the running shell uses)
#   AIQ_RENDER_SCALE       device pixel ratio of the images (default 1)
#   AIQ_UPDATE_SCREENSHOT  "1" to copy claude.png to assets/screenshot.png
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
out="${AIQ_TEST_ARTIFACT_DIR:-$repo/tests/render-output}"
expected_pill='claude=62% codex=88% opencode=78% zai=73% kimi=84% deepseek=18.42$ openrouter=9.66$ grok=38% antigravity=80%'

shell_dir="${DMS_SHELL_DIR:-$(pgrep -a qs | sed -n 's/.* -p \([^ ]*danklinux-shell[^ ]*\).*/\1/p' | head -n 1)}"
if [ ! -f "$shell_dir/shell.qml" ]; then
    printf '%s\n' 'Could not find the DMS shell. Start DMS, or set DMS_SHELL_DIR.' >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
harness="$work/harness"
mkdir -p "$harness/Modules/Plugins" "$work/config/DankMaterialShell" \
    "$work/cache/DankMaterialShell" "$work/state" "$work/data" "$work/runtime" "$out"
chmod 700 "$work/runtime"
rm -f "$out"/*.png

# Build a shell directory from the DMS one, with this config as shell.qml.
for entry in "$shell_dir"/*; do
    case "${entry##*/}" in shell.qml|Modules) ;; *) ln -s "$entry" "$harness/" ;; esac
done
for entry in "$shell_dir"/Modules/*; do
    [ "${entry##*/}" = Plugins ] || ln -s "$entry" "$harness/Modules/"
done
for entry in "$shell_dir"/Modules/Plugins/*; do
    [ "${entry##*/}" = PluginComponent.qml ] || ln -s "$entry" "$harness/Modules/Plugins/"
done
# A layer-shell popout cannot exist offscreen. Replace it with a stub.
awk '
    /^    PluginPopout \{/ {
        print "    QtObject { id: pluginPopout; function toggle() {} function close() {} function setTriggerPosition() {} }"
        skip = 1
        next
    }
    skip && /^    \}/ { skip = 0; next }
    !skip
' "$shell_dir/Modules/Plugins/PluginComponent.qml" > "$harness/Modules/Plugins/PluginComponent.qml"
cp "$repo/tests/render/shell.qml" "$harness/shell.qml"

# One JSON line, because the daemon parses line by line. Resets are relative to now.
now=$(date +%s)
jq -c --argjson now "$now" '
    {captured_at: $now} + map_values(
        if .entries then .entries |= map(.resetAt = ($now + .resetIn) | del(.resetIn)) else . end
        | if .source == "native" then .capturedAt = $now else . end
    )' "$repo/tests/fixtures/demo-usage.json" > "$work/usage.json"

# Every provider on, default pins. Reuse the local DMS theme when there is one.
printf '%s\n' '{"aiQuotas":{"enabled":true}}' > "$work/config/DankMaterialShell/plugin_settings.json"
cp "${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/settings.json" "$work/config/DankMaterialShell/" 2>/dev/null || true
cp "${XDG_CACHE_HOME:-$HOME/.cache}/DankMaterialShell/dms-colors.json" "$work/cache/DankMaterialShell/" 2>/dev/null || true

env -u WAYLAND_DISPLAY -u DISPLAY -u NIRI_SOCKET -u HYPRLAND_INSTANCE_SIGNATURE \
    -u DMS_SOCKET -u QT_QPA_PLATFORMTHEME \
    QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR="${AIQ_RENDER_SCALE:-1}" \
    XDG_RUNTIME_DIR="$work/runtime" XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache" \
    XDG_STATE_HOME="$work/state" XDG_DATA_HOME="$work/data" \
    AIQ_PLUGIN_DIR="$repo" AIQ_SHOT_DIR="$out" \
    AIQ_USAGE_MOCK="$work/usage.json" CACHE_FILE="$work/usage-cache.json" \
    timeout 120 dbus-run-session -- qs --log-rules 'scene.warning=true;qml.warning=true;js.warning=true' -p "$harness" > "$out/quickshell.log" 2>&1 || true

fail() {
    printf '%s\n' "$1" >&2
    grep -E "AIQ|$repo" "$out/quickshell.log" >&2 || tail -n 20 "$out/quickshell.log" >&2
    exit 1
}

grep -q 'AIQ done' "$out/quickshell.log" || fail 'The render did not finish.'
if grep -E "AIQ ERROR|$repo/[^ ]*: .*(Error|is not defined|Cannot read|Unable to assign)" "$out/quickshell.log" >&2; then
    fail 'QML errors in plugin files.'
fi
sed -n 's/.*AIQ pill: //p' "$out/quickshell.log" > "$out/pill.txt"
[ "$(cat "$out/pill.txt")" = "$expected_pill" ] ||
    fail "Unexpected pill: $(cat "$out/pill.txt") (expected: $expected_pill)"
pins=$(sed -n 's/.*AIQ pins: //p' "$out/quickshell.log")
[ "$pins" = '5h | Weekly |  | 5h' ] || fail "Unexpected pin behavior: $pins (expected: 5h | Weekly |  | 5h)"
for name in claude codex opencode zai kimi deepseek openrouter grok antigravity vertical settings; do
    [ -s "$out/$name.png" ] || fail "Missing $name.png."
done

if [ "${AIQ_UPDATE_SCREENSHOT:-0}" = "1" ]; then
    cp "$out/claude.png" "$repo/assets/screenshot.png"
fi
printf '%s\n' "Render checks passed. Images are in $out."
