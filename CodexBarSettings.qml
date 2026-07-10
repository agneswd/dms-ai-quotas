import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "codexbar"

    StyledText {
        width: parent.width
        text: "CodexBar Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "AI coding provider usage in your bar"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "providers"
        label: "Providers"
        description: "Comma-separated provider IDs, or 'all' for every enabled provider"
        placeholder: "all"
        defaultValue: "all"
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

    SliderSetting {
        settingKey: "maxBarProviders"
        label: "Max Providers in Bar"
        description: "Number of top providers shown in the bar pill"
        defaultValue: 3
        minimum: 1
        maximum: 5
    }

    SelectionSetting {
        settingKey: "displayStyle"
        label: "Display Style"
        description: "How to show usage in the bar pill"
        options: [
            { label: "Rings", value: "rings" },
            { label: "Numbers", value: "numbers" }
        ]
        defaultValue: "rings"
    }

    ToggleSetting {
        settingKey: "showCredits"
        label: "Show Credits"
        description: "Display credit balance in the popout"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showResetTime"
        label: "Show Reset Countdown"
        description: "Show live reset countdown in the popout"
        defaultValue: true
    }
}
