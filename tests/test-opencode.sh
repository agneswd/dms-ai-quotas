#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/opencode"

cat > "$test_dir/bin/curl" <<'EOF'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in @*) cat "${arg#@}" > "$OPENCODE_SENT_HEADERS" ;; esac
done
case "$OPENCODE_HTTP_CODE" in
    '')
        printf '%s\n200\n' "$OPENCODE_RESPONSE" ;;
    *)
        printf '%s\n%s\n' "$OPENCODE_RESPONSE" "$OPENCODE_HTTP_CODE" ;;
esac
EOF
chmod +x "$test_dir/bin/curl"

ok_body='{"usage":{"rolling":{"status":"ok","percent":11,"resetsAt":"2030-01-01T00:00:00.000Z"},"weekly":{"status":"ok","percent":22,"resetsAt":"2030-01-08T00:00:00Z"},"monthly":{"status":"ok","percent":33,"resetsAt":"2030-02-01T00:00:00.510Z"}}}'

run_fetch() {
    env PATH="$test_dir/bin:$PATH" \
        OPENCODE_RESPONSE="${1:-}" \
        OPENCODE_HTTP_CODE="${2:-}" \
        OPENCODE_SENT_HEADERS="$test_dir/sent-headers" \
        AIQ_CLAUDE_ENABLED=0 \
        AIQ_CODEX_ENABLED=0 \
        AIQ_OPENCODE_ENABLED=1 \
        AIQ_DEEPSEEK_ENABLED=0 \
        AIQ_OPENROUTER_ENABLED=0 \
        AIQ_GROK_ENABLED=0 \
        AIQ_ANTIGRAVITY_ENABLED=0 \
        OPENCODE_GO_API_KEY="${OPENCODE_GO_API_KEY-sk-test}" \
        OPENCODE_DATA_DIR="$test_dir/opencode" \
        AIQ_CACHE_TTL=0 \
        CACHE_FILE="$test_dir/usage.json" \
        sh "$repo/fetch-usage.sh"
}

run_fetch "$ok_body" | jq -e \
    '.opencode.status == "ok"
     and .opencode.entries == [
       {"name":"Rolling","percentUsed":11,"resetAt":1893456000},
       {"name":"Weekly","percentUsed":22,"resetAt":1894060800},
       {"name":"Monthly","percentUsed":33,"resetAt":1896134400}
     ]' >/dev/null

run_fetch '{"usage":{"rolling":{"status":"limited","percent":90,"resetsAt":"2030-01-01T00:00:00Z"},"weekly":{"status":"ok","percent":5,"resetsAt":"2030-01-08T00:00:00Z"},"monthly":{"percent":7,"resetsAt":"2030-02-01T00:00:00Z"}}}' | jq -e \
    '.opencode.status == "ok"
     and (.opencode.entries | length) == 2
     and .opencode.entries[0].name == "Weekly"
     and .opencode.entries[1].name == "Monthly"' >/dev/null

run_fetch '{}' 401 | jq -e \
    '.opencode.status == "error" and .opencode.reason == "auth_expired"' >/dev/null

run_fetch '{}' 403 | jq -e \
    '.opencode.status == "error" and .opencode.reason == "access_denied"' >/dev/null

run_fetch '{}' 000 | jq -e \
    '.opencode.status == "error" and .opencode.reason == "network"' >/dev/null

run_fetch '{"error":"bad shape"}' | jq -e \
    '.opencode.status == "error"
     and .opencode.error == "Could not parse OpenCode usage"' >/dev/null

OPENCODE_GO_API_KEY= run_fetch "$ok_body" | jq -e \
    '.opencode.status == "unavailable"
     and .opencode.reason == "not_authenticated"' >/dev/null

printf '%s\n' '{"opencode-go":{"type":"api","key":"sk-from-file"}}' > "$test_dir/opencode/auth.json"
OPENCODE_GO_API_KEY= run_fetch "$ok_body" | jq -e \
    '.opencode.status == "ok" and .opencode.entries[0].name == "Rolling"' >/dev/null

# opencode v2 saves /connect keys in opencode.db and can leave an old key in
# auth.json. The newest database key must win. The plugin setting wins over both.
sent_key() {
    sed -n 's/^Authorization: Bearer //p' "$test_dir/sent-headers"
}
if command -v sqlite3 >/dev/null 2>&1; then
    printf '%s\n' '{"opencode-go":{"type":"api","key":"sk-old-auth-json"}}' > "$test_dir/opencode/auth.json"
    sqlite3 "$test_dir/opencode/opencode.db" "
        create table credential (id text primary key, integration_id text, label text not null,
            value text not null, connector_id text, method_id text, active integer,
            time_created integer not null, time_updated integer not null);
        insert into credential values ('a', 'opencode-go', 'default', '{\"key\":\"sk-db-old\"}', null, null, null, 1, 1);
        insert into credential values ('b', 'opencode-go', 'default', '{\"key\":\"sk-db-new\"}', null, null, null, 2, 2);
        insert into credential values ('c', 'deepseek', 'default', '{\"key\":\"sk-other\"}', null, null, null, 3, 3);"
    OPENCODE_GO_API_KEY= run_fetch "$ok_body" | jq -e '.opencode.status == "ok"' >/dev/null
    [ "$(sent_key)" = "sk-db-new" ]

    sqlite3 "$test_dir/opencode/opencode.db" "update credential set active = 1 where id = 'a'"
    OPENCODE_GO_API_KEY= run_fetch "$ok_body" >/dev/null
    [ "$(sent_key)" = "sk-db-old" ]

    run_fetch "$ok_body" >/dev/null
    [ "$(sent_key)" = "sk-test" ]

    sqlite3 "$test_dir/opencode/opencode.db" "delete from credential where integration_id = 'opencode-go'"
    OPENCODE_GO_API_KEY= run_fetch "$ok_body" >/dev/null
    [ "$(sent_key)" = "sk-old-auth-json" ]
else
    printf '%s\n' 'sqlite3 is not installed. Skipped the opencode.db checks.' >&2
fi
printf '%s\n' 'OpenCode fetch checks passed.'
