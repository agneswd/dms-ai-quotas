import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "aiQuotas"

    StyledText {
        width: parent.width
        text: "AI Quotas"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "codexEnabled"
        label: "Codex"
        description: "Show Codex usage limits from your local Codex login"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "openCodeEnabled"
        label: "OpenCode Go"
        description: "Show OpenCode Go usage quotas"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "deepSeekEnabled"
        label: "DeepSeek API"
        description: "Show DeepSeek API account balance"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: "Refresh Interval"
        description: "How often to fetch usage data"
        defaultValue: 60
        minimum: 30
        maximum: 300
        unit: "sec"
    }

    ToggleSetting {
        settingKey: "showResetTime"
        label: "Show Reset Times"
        description: "Show reset date and time in the popout"
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "displayMode"
        label: "Display Mode"
        description: "Show used or remaining percentage"
        options: [
            { label: "Remaining (%)", value: "remaining" },
            { label: "Used (%)", value: "used" }
        ]
        defaultValue: "remaining"
    }

    StyledText {
        width: parent.width
        text: "Credentials"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingM
    }

    StringSetting {
        settingKey: "deepSeekApiKey"
        label: "DeepSeek API Key"
        description: "From platform.deepseek.com/api_keys"
        placeholder: "sk-..."
        defaultValue: ""
    }

    StringSetting {
        settingKey: "openCodeWorkspaceId"
        label: "OpenCode Workspace ID"
        description: "From URL: opencode.ai/workspace/YOUR_ID/go"
        placeholder: "wrk_..."
        defaultValue: ""
    }

    StringSetting {
        settingKey: "openCodeAuthCookie"
        label: "OpenCode Auth Cookie"
        description: "auth cookie from opencode.ai (dev tools > Application > Cookies)"
        placeholder: "Paste your auth cookie"
        defaultValue: ""
    }
}
