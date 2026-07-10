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

## Requirements

- DankMaterialShell >= 1.5.0
- [opencode-quota](https://github.com/slkiser/opencode-quota) (`npm i -g @slkiser/opencode-quota`)
- `jq`
- For DeepSeek: an API key from [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys)

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
| DeepSeek API Key | (empty) | Your DeepSeek API key |
| Refresh Interval | 60s | How often to fetch data (30-300s) |
| Show Reset Countdown | on | Live countdown in the popout |

## How it works

```
opencode-quota show --json        --\
                                     |---> fetch-usage.sh ---> cache JSON ---> Widget
curl api.deepseek.com/user/balance --/
```

The plugin runs the fetch script on a timer. It calls `opencode-quota` for OpenCode usage data and curls the DeepSeek balance API, merges the results into a single JSON cache file, and renders it in the bar.

## Setting up OpenCode quotas

Run the init command to connect OpenCode to the quota plugin:

```sh
opencode-quota init
```

This sets up the local data sources that `opencode-quota` reads from. Restart OpenCode after running init.

## License

MIT
