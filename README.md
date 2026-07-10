# dms-codexbar

AI coding provider usage limits in your [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar.

Shows session and weekly usage for providers like Codex, Claude, Cursor, DeepSeek, OpenCode, Copilot, Gemini, and more - powered by the [CodexBar](https://github.com/steipete/CodexBar) CLI.

## Features

- Merged bar pill showing top providers as theme-colored progress rings
- Click to open a popout with per-provider detail
- Session and weekly usage percentages with live reset countdowns
- Credit balance display where supported
- Provider status indicators
- Configurable refresh interval (30s - 300s)
- Choose which providers to display

## Requirements

- DankMaterialShell >= 1.5.0
- [CodexBar CLI](https://github.com/steipete/CodexBar) (`codexbar`)
- `jq`

### Installing codexbar

**Homebrew (macOS/Linux):**

```sh
brew install steipete/tap/codexbar
```

**Arch Linux (AUR):**

```sh
yay -S codexbar-cli
```

**Manual:** Download release tarballs from [GitHub Releases](https://github.com/steipete/CodexBar/releases).

## Install

```sh
git clone https://github.com/agneswd/dms-codexbar \
          ~/.config/DankMaterialShell/plugins/codexbar
```

Then in DMS:
1. Open **Settings - Plugins**
2. Click **Scan for Plugins**
3. Enable **CodexBar**
4. Add to DankBar layout (**Settings - DankBar Layout**)
5. Restart shell: `dms restart`

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Providers | `all` | Comma-separated provider IDs, or `all` |
| Refresh Interval | 60s | How often to fetch usage (30-300s) |
| Max Providers in Bar | 3 | Top N providers shown in the bar pill |
| Display Style | Rings | Rings (% in center) or numbers (15% . 4%) |
| Show Credits | on | Display credit balance in popout |
| Show Reset Countdown | on | Live reset countdown in popout |

## How it works

```
codexbar usage --format json --provider all
    |
    v
fetch-usage.sh  -->  ~/.cache/dms-codexbar/usage.json
    |
    v
CodexBarWidget.qml (polls on timer)
    |-- Bar pill: merged rings for top providers
    |-- Popout: full provider list with usage, reset countdowns, credits
```

The plugin calls the CodexBar CLI periodically, caches the JSON output, and renders it in the bar. No passwords are stored - it reuses whatever auth the CodexBar CLI already has configured.

## Supported Providers

CodexBar supports 57+ providers including:

Codex, OpenAI, Claude, Cursor, OpenCode, Copilot, Gemini, Grok, GroqCloud, DeepSeek, Windsurf, Zed, Kilo, Kiro, ElevenLabs, OpenRouter, Vertex AI, Augment, LiteLLM, Deepgram, and many more.

See the [CodexBar providers list](https://github.com/steipete/CodexBar#providers) for the full list and setup instructions.

## License

MIT
