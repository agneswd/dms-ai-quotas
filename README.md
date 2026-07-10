# dms-ai-quotas

OpenCode usage quotas and DeepSeek balance in your [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar.

Shows OpenCode rolling, weekly, and monthly usage percentages with reset countdowns, plus your DeepSeek account balance - all in one merged bar pill.

## Features

- Merged bar pill showing OpenCode usage ring + DeepSeek balance indicator
- Click to open a popout with per-window OpenCode detail (rolling, weekly, monthly)
- Live reset countdowns for each OpenCode window
- DeepSeek balance card with total/granted/topped-up breakdown
- Configurable refresh interval (30s - 300s)
- Toggle each provider on/off independently
- All credentials configured from DMS settings - no config files needed

## Requirements

- DankMaterialShell >= 1.5.0
- `curl` and `jq`
- For DeepSeek: an API key from [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys)
- For OpenCode: workspace ID and auth cookie from [opencode.ai](https://opencode.ai)

## Install

```sh
git clone https://github.com/agneswd/dms-ai-quotas \
          ~/.config/DankMaterialShell/plugins/aiQuotas
```

Then in DMS:
1. Open **Settings - Plugins**
2. Click **Scan for Plugins**
3. Enable **AI Quotas**
4. Add to DankBar layout (**Settings - DankBar Layout**)
5. Restart shell: `dms restart`

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| OpenCode | on | Show OpenCode usage quotas |
| DeepSeek | on | Show DeepSeek account balance |
| Refresh Interval | 60s | How often to fetch data (30-300s) |
| Show Reset Countdown | on | Live countdown in the popout |
| DeepSeek API Key | (empty) | Your DeepSeek API key |
| OpenCode Workspace ID | (empty) | From the URL: `opencode.ai/workspace/YOUR_ID/go` |
| OpenCode Auth Cookie | (empty) | The `auth` cookie from opencode.ai |

## How to get OpenCode credentials

1. Open [opencode.ai](https://opencode.ai) in your browser and sign in
2. Navigate to your workspace (e.g. `opencode.ai/workspace/wrk_abc123/go`)
3. Copy `wrk_abc123` from the URL - that's your **Workspace ID**
4. Open browser dev tools (F12) -> Application -> Cookies -> `opencode.ai`
5. Copy the `auth` cookie value - that's your **Auth Cookie**
6. Paste both into DMS Settings -> AI Quotas

## How it works

The plugin scrapes the OpenCode workspace dashboard directly via `curl` and queries the DeepSeek balance API. No external npm packages required.

```
curl opencode.ai/workspace/{id}/go  --\
                                       |---> fetch-usage.sh ---> cache ---> Widget
curl api.deepseek.com/user/balance  --/
```

## License

MIT
