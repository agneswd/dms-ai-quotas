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
        settingKey: "openCodeEnabled"
        label: "OpenCode"
        description: "Show OpenCode usage quotas"
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "pinnedWindow"
        label: "Bar Pill Window"
        description: "Which OpenCode window to show in the bar"
        options: [
            { label: "Rolling (5h)", value: "Rolling" },
            { label: "Weekly", value: "Weekly" },
            { label: "Monthly", value: "Monthly" }
        ]
        defaultValue: "Rolling"
    }

    ToggleSetting {
        settingKey: "showRolling"
        label: "Show Rolling (5h)"
        description: "Show rolling usage in the popout"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showWeekly"
        label: "Show Weekly"
        description: "Show weekly usage in the popout"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showMonthly"
        label: "Show Monthly"
        description: "Show monthly usage in the popout"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "deepSeekEnabled"
        label: "DeepSeek"
        description: "Show DeepSeek account balance"
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
        label: "Show Reset Countdown"
        description: "Show live reset countdown in the popout"
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
