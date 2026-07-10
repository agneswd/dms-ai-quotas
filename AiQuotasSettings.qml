import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "aiQuotas"

    StyledText {
        width: parent.width
        text: "AI Quotas Settings"
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
        description: "From the URL: opencode.ai/workspace/YOUR_ID/go"
        placeholder: "wrk_..."
        defaultValue: ""
    }

    StringSetting {
        settingKey: "openCodeAuthCookie"
        label: "OpenCode Auth Cookie"
        description: "The 'auth' cookie from opencode.ai (browser dev tools > Application > Cookies)"
        placeholder: "Paste your auth cookie"
        defaultValue: ""
    }
}
