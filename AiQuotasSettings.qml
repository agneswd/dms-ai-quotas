import QtQuick
import qs.Common
import qs.Modules.Plugins
import "./dms-common"

PluginSettings {
    id: root
    pluginId: "aiQuotas"

    SettingsCard {
        SectionTitle {
            text: I18n.tr("Providers")
            icon: "smart_toy"
            showReset: claudeEnabled.isDirty || codexEnabled.isDirty || openCodeEnabled.isDirty || deepSeekEnabled.isDirty || grokEnabled.isDirty || antigravityEnabled.isDirty
            onResetClicked: {
                claudeEnabled.resetToDefault()
                codexEnabled.resetToDefault()
                openCodeEnabled.resetToDefault()
                deepSeekEnabled.resetToDefault()
                grokEnabled.resetToDefault()
                antigravityEnabled.resetToDefault()
            }
        }

        ToggleSettingPlus {
            id: claudeEnabled
            settingKey: "claudeEnabled"
            label: I18n.tr("Claude")
            description: I18n.tr("Show plan usage limits from your local Claude Code login.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: codexEnabled
            settingKey: "codexEnabled"
            label: I18n.tr("Codex")
            description: I18n.tr("Show usage limits from your local Codex login.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: openCodeEnabled
            settingKey: "openCodeEnabled"
            label: I18n.tr("OpenCode Go")
            description: I18n.tr("Show OpenCode Go usage quotas.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: deepSeekEnabled
            settingKey: "deepSeekEnabled"
            label: I18n.tr("DeepSeek API")
            description: I18n.tr("Show your DeepSeek API account balance.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: grokEnabled
            settingKey: "grokEnabled"
            label: I18n.tr("Grok")
            description: I18n.tr("Show billing usage from your local Grok login.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: antigravityEnabled
            settingKey: "antigravityEnabled"
            label: I18n.tr("Antigravity")
            description: I18n.tr("Show Antigravity agent and model quotas.")
            defaultValue: true
        }
    }

    SettingsCard {
        SectionTitle {
            text: I18n.tr("Display and Refresh")
            icon: "display_settings"
            showReset: refreshInterval.isDirty || showResetTime.isDirty || showResetCountdown.isDirty || displayMode.isDirty
            onResetClicked: {
                refreshInterval.resetToDefault()
                showResetTime.resetToDefault()
                showResetCountdown.resetToDefault()
                displayMode.resetToDefault()
            }
        }

        SliderSettingPlus {
            id: refreshInterval
            settingKey: "refreshInterval"
            label: I18n.tr("Refresh Interval")
            description: I18n.tr("How often to fetch usage data.")
            defaultValue: 60
            minimum: 30
            maximum: 300
            unit: "sec"
            leftLabel: "30 sec"
            rightLabel: "300 sec"
        }

        Separator {}

        ToggleSettingPlus {
            id: showResetTime
            settingKey: "showResetTime"
            label: I18n.tr("Show Reset Times")
            description: I18n.tr("Show reset information in the popout.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: showResetCountdown
            settingKey: "showResetCountdown"
            label: I18n.tr("Show Reset Countdown")
            description: I18n.tr("Use a countdown instead of the reset date and time.")
            defaultValue: false
        }

        Separator {}

        SelectionSettingPlus {
            id: displayMode
            settingKey: "displayMode"
            label: I18n.tr("Display Mode")
            description: I18n.tr("Show used or remaining percentage.")
            options: [
                { label: I18n.tr("Remaining (%)"), value: "remaining" },
                { label: I18n.tr("Used (%)"), value: "used" }
            ]
            defaultValue: "remaining"
        }
    }

    SettingsCard {
        SectionTitle {
            text: I18n.tr("Credentials")
            icon: "key"
            showReset: deepSeekApiKey.isDirty || openCodeWorkspaceId.isDirty || openCodeAuthCookie.isDirty
            onResetClicked: {
                deepSeekApiKey.resetToDefault()
                openCodeWorkspaceId.resetToDefault()
                openCodeAuthCookie.resetToDefault()
            }
        }

        StringSettingPlus {
            id: deepSeekApiKey
            settingKey: "deepSeekApiKey"
            label: I18n.tr("DeepSeek API Key")
            description: I18n.tr("Get this from platform.deepseek.com/api_keys.")
            placeholder: "sk-..."
            defaultValue: ""
        }

        Separator {}

        StringSettingPlus {
            id: openCodeWorkspaceId
            settingKey: "openCodeWorkspaceId"
            label: I18n.tr("OpenCode Workspace ID")
            description: I18n.tr("Find this in your opencode.ai workspace URL.")
            placeholder: "wrk_..."
            defaultValue: ""
        }

        Separator {}

        StringSettingPlus {
            id: openCodeAuthCookie
            settingKey: "openCodeAuthCookie"
            label: I18n.tr("OpenCode Auth Cookie")
            description: I18n.tr("Copy the auth cookie from your browser's application storage.")
            placeholder: I18n.tr("Paste your auth cookie")
            defaultValue: ""
        }
    }
}
