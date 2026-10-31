# GitHub Copilot quota snapshots from the local GitHub CLI login or token env.
#
# GET https://api.github.com/copilot_internal/user
# Env: COPILOT_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN, or `gh auth token`

fetch_copilot() {
    access_token=${COPILOT_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}
    if [ -z "$access_token" ] && command -v gh >/dev/null 2>&1; then
        access_token=$(gh auth token 2>/dev/null || true)
    fi
    if [ -z "$access_token" ]; then
        aiq_status unavailable not_authenticated "GitHub Copilot is not authenticated. Sign in with gh auth login or provide a Copilot/GitHub token."
        return
    fi

    headers=$(aiq_headers copilot \
        "Authorization: token $access_token" \
        "Editor-Version: vscode/1.96.2" \
        "Editor-Plugin-Version: copilot-chat/0.26.7" \
        "User-Agent: GitHubCopilotChat/0.26.7" \
        "X-GitHub-Api-Version: 2025-04-01")
    aiq_request "$headers" https://api.github.com/copilot_internal/user

    case "$http_code" in
        2??)
            aiq_parse "Could not parse GitHub Copilot usage" '
                def reset_value($root; $snapshot):
                    ($snapshot.quota_reset_at // $snapshot.reset_at // $snapshot.reset_date //
                     $root.quota_reset_at // $root.quota_reset_date // $root.reset_at // 0) as $value |
                    if ($value | type) == "string" and ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then
                        (($value + "T00:00:00Z") | timestamp)
                    else ($value | timestamp) end;
                def snapshot($root; $key; $name):
                    ($root.quota_snapshots[$key] // $root.quotaSnapshots[$key] // null) as $quota |
                    if ($quota | type) != "object" or $quota.has_quota == false or $quota.unlimited == true then empty
                    else
                        ((($quota.percent_remaining? | num) // null) as $remaining_pct |
                         if $remaining_pct != null then
                             (if $remaining_pct > 0 and $remaining_pct <= 1 then $remaining_pct * 100 else $remaining_pct end)
                         elif (($quota.entitlement? | num) // 0) > 0 and (($quota.remaining? | num) // null) != null then
                             (($quota.remaining | num) / ($quota.entitlement | num) * 100)
                         else empty end) as $remaining |
                        {
                            name: $name,
                            percentUsed: (100 - $remaining | clamp_pct),
                            resetAt: reset_value($root; $quota)
                        }
                    end;
                . as $root |
                [
                    snapshot($root; "premium_interactions"; "Premium Requests"),
                    snapshot($root; "chat"; "Chat"),
                    snapshot($root; "completions"; "Completions")
                ] as $entries |
                if ($entries | length) == 0 then
                    if (($root.quota_snapshots // $root.quotaSnapshots | type) == "object") then
                        {status: "unavailable", reason: "no_quota"}
                    else error("no quota snapshots") end
                else {status: "ok", plan: ($root.copilot_plan // $root.plan_type // "Copilot"), entries: $entries} end
            '
            ;;
        401) aiq_status error auth_expired "GitHub Copilot login expired. Run gh auth login again, then refresh AI Quotas." ;;
        403|404) aiq_status error access_denied "GitHub Copilot usage access was denied. Check that this GitHub account has Copilot access." ;;
        *) aiq_http_failure "$http_code" "the GitHub Copilot usage service" ;;
    esac
}
