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

    StyledText {
        width: parent.width
        text: "OpenCode usage quotas and DeepSeek balance in your bar"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
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

    StringSetting {
        settingKey: "deepSeekApiKey"
        label: "DeepSeek API Key"
        description: "From platform.deepseek.com/api_keys"
        placeholder: "sk-..."
        defaultValue: ""
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

    StyledText {
        width: parent.width
        text: "OpenCode Config"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.surfaceText
        anchors.topMargin: Theme.spacingM
    }

    StyledText {
        width: parent.width
        text: "Set workspace ID and auth cookie from your OpenCode dashboard, or create ~/.config/opencode-quota/opencode-go.json"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
