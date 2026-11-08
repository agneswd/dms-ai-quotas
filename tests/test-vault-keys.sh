#!/bin/sh
set -eu

# Provider keys read from the freedesktop keyring, for a shell that never
# exported them (DMS starts from the graphical session, not from ~/.bashrc).
# Covered: the key reaches the request from the keyring, an exported key wins
# and skips the lookup, a locked keyring is bounded, and the key never appears
# in a process argument or in the cache.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/tmp" "$test_dir/data"

cat >"$test_dir/bin/secret-tool" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AIQ_TEST_LOOKUPS"
[ -z "${AIQ_TEST_SLEEP:-}" ] || exec sleep "$AIQ_TEST_SLEEP"
shift
printf 'keyring-%s' "$(printf '%s' "$*" | tr ' ' '-')"
EOF
chmod +x "$test_dir/bin/secret-tool"

cat >"$test_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$@" >> "$AIQ_TEST_REQUESTS"
if printf '%s\n' "$@" | grep -Eq 'keyring-|envkey-'; then
    printf '%s\n' 'A credential reached curl arguments.' >&2
    exit 99
fi
header_file=""
for arg in "$@"; do
    case "$arg" in
        @*) header_file=${arg#@} ;;
    esac
done
test -n "$header_file"
test "$(stat -c %a "$header_file")" = 600
expected=""
for arg in "$@"; do
    case "$arg" in
        *api.z.ai*)
            provider=zai
            expected=keyring-service-zai-username-quota
            body='{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":10}]}}'
            ;;
        *openrouter.ai*)
            provider=openrouter
            expected=keyring-service-openrouter-username-quota
            body='{"data":{"total_credits":20,"total_usage":10}}'
            ;;
        *opencode.ai*)
            provider=opencode
            expected=keyring-service-opencode-username-quota
            body='{"usage":{"rolling":{"percent":10}}}'
            ;;
    esac
done
grep -Fqx "Authorization: Bearer $expected" "$header_file" ||
    grep -Fqx "Authorization: Bearer envkey-$provider" "$header_file"
printf '%s' "$body"
printf '\n200\n'
EOF
chmod +x "$test_dir/bin/curl"

run_fetch() {
    env -u OPENROUTER_API_KEY -u ZAI_API_KEY -u GLM_API_KEY -u ZHIPU_API_KEY \
        -u OPENCODE_API_KEY -u OPENCODE_GO_API_KEY -u AIQ_VAULT_TIMEOUT \
        PATH="$test_dir/bin:$PATH" TMPDIR="$test_dir/tmp" XDG_CACHE_HOME="$test_dir/cache" \
        OPENCODE_DATA_DIR="$test_dir/data" AIQ_FORCE_REFRESH=1 \
        AIQ_ZAI_ENABLED="${1:-1}" AIQ_OPENROUTER_ENABLED="${2:-1}" AIQ_OPENCODE_ENABLED="${3:-1}" \
        AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_KIMI_ENABLED=0 AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_GROK_ENABLED=0 AIQ_ANTIGRAVITY_ENABLED=0 \
        AIQ_VAULT_ZAI="service zai username quota" \
        AIQ_VAULT_OPENROUTER="service openrouter username quota" \
        AIQ_VAULT_OPENCODE="service opencode username quota" \
        AIQ_TEST_REQUESTS="$test_dir/requests.txt" AIQ_TEST_LOOKUPS="$test_dir/lookups.txt" \
        AIQ_VAULT_TIMEOUT="${4:-3}" AIQ_TEST_SLEEP="${5:-}" \
        sh "$repo/fetch-usage.sh"
}

# 1. The keyring supplies all three keys, and no key reaches an argument.
: >"$test_dir/lookups.txt"
run_fetch >"$test_dir/result.json"
jq -e '[.zai, .openrouter, .opencode] | all(.status == "ok")' "$test_dir/result.json" >/dev/null
grep -qx 'lookup service zai username quota' "$test_dir/lookups.txt"
grep -qx 'lookup service openrouter username quota' "$test_dir/lookups.txt"
grep -qx 'lookup service opencode username quota' "$test_dir/lookups.txt"
if grep -rEq 'keyring-' "$test_dir/cache"; then
    printf '%s\n' 'A keyring key was written to the cache.' >&2
    exit 1
fi

# 2. An exported key wins and skips that provider's lookup.
before=$(grep -c 'service openrouter username quota' "$test_dir/lookups.txt" || true)
env -u ZAI_API_KEY -u OPENCODE_API_KEY -u OPENCODE_GO_API_KEY \
    OPENROUTER_API_KEY=envkey-openrouter \
    PATH="$test_dir/bin:$PATH" TMPDIR="$test_dir/tmp" XDG_CACHE_HOME="$test_dir/cache" \
    OPENCODE_DATA_DIR="$test_dir/data" AIQ_FORCE_REFRESH=1 \
    AIQ_ZAI_ENABLED=0 AIQ_OPENCODE_ENABLED=0 AIQ_OPENROUTER_ENABLED=1 \
    AIQ_CLAUDE_ENABLED=0 AIQ_CODEX_ENABLED=0 AIQ_KIMI_ENABLED=0 AIQ_DEEPSEEK_ENABLED=0 \
    AIQ_GROK_ENABLED=0 AIQ_ANTIGRAVITY_ENABLED=0 \
    AIQ_VAULT_OPENROUTER="service openrouter username quota" \
    AIQ_TEST_REQUESTS="$test_dir/requests.txt" AIQ_TEST_LOOKUPS="$test_dir/lookups.txt" \
    sh "$repo/fetch-usage.sh" >"$test_dir/env-result.json"
jq -e '.openrouter.status == "ok"' "$test_dir/env-result.json" >/dev/null
after=$(grep -c 'service openrouter username quota' "$test_dir/lookups.txt" || true)
test "$before" = "$after"

# 3. A keyring that does not answer is bounded: the provider reports a missing
#    credential instead of blocking the fetch on a prompt nobody will answer.
started=$(date +%s)
run_fetch 1 0 0 1 5 >"$test_dir/bounded.json"
elapsed=$(($(date +%s) - started))
test "$elapsed" -le 3
jq -e '.zai.status == "unavailable" and .zai.reason == "not_authenticated"' "$test_dir/bounded.json" >/dev/null

printf '%s\n' 'Keyring credential checks passed.'
