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
            showReset: claudeEnabled.isDirty || codexEnabled.isDirty || openCodeEnabled.isDirty || zaiEnabled.isDirty || kimiEnabled.isDirty || deepSeekEnabled.isDirty || openRouterEnabled.isDirty || grokEnabled.isDirty || antigravityEnabled.isDirty
            onResetClicked: {
                claudeEnabled.resetToDefault()
                codexEnabled.resetToDefault()
                openCodeEnabled.resetToDefault()
                zaiEnabled.resetToDefault()
                kimiEnabled.resetToDefault()
                deepSeekEnabled.resetToDefault()
                openRouterEnabled.resetToDefault()
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
            description: I18n.tr("Show OpenCode Go usage quotas from your local OpenCode login.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: zaiEnabled
            settingKey: "zaiEnabled"
            label: I18n.tr("Z.ai Coding Plan")
            description: I18n.tr("Show GLM Coding Plan quotas for your Z.ai API key.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: kimiEnabled
            settingKey: "kimiEnabled"
            label: I18n.tr("Kimi Code")
            description: I18n.tr("Show Kimi Code plan quotas from an API key or your kimi login.")
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
            id: openRouterEnabled
            settingKey: "openRouterEnabled"
            label: I18n.tr("OpenRouter")
            description: I18n.tr("Show your OpenRouter account credit balance.")
            defaultValue: true
        }

        Separator {}

        ToggleSettingPlus {
            id: grokEnabled
            settingKey: "grokEnabled"
            label: I18n.tr("Grok")
            description: I18n.tr("Show usage limits from your local Grok login.")
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
            showReset: openCodeApiKey.isDirty || zaiApiKey.isDirty || zaiRegion.isDirty || kimiApiKey.isDirty || deepSeekApiKey.isDirty || openRouterApiKey.isDirty
            onResetClicked: {
                openCodeApiKey.resetToDefault()
                zaiApiKey.resetToDefault()
                zaiRegion.resetToDefault()
                kimiApiKey.resetToDefault()
                deepSeekApiKey.resetToDefault()
                openRouterApiKey.resetToDefault()
            }
        }

        StringSettingPlus {
            id: openCodeApiKey
            settingKey: "openCodeApiKey"
            label: I18n.tr("OpenCode Go API Key")
            description: I18n.tr("Optional. Leave empty to use the key from opencode /connect.")
            placeholder: "sk-..."
            defaultValue: ""
        }

        Separator {}

        StringSettingPlus {
            id: zaiApiKey
            settingKey: "zaiApiKey"
            label: I18n.tr("Z.ai Coding Plan API Key")
            description: I18n.tr("The API key you use with your GLM Coding Plan, from z.ai/manage-apikey/apikey-list.")
            placeholder: I18n.tr("Paste your API key")
            defaultValue: ""
        }

        Separator {}

        SelectionSettingPlus {
            id: zaiRegion
            settingKey: "zaiRegion"
            label: I18n.tr("Z.ai Region")
            description: I18n.tr("Use China for BigModel (open.bigmodel.cn) Coding Plan keys.")
            options: [
                { label: I18n.tr("Global (api.z.ai)"), value: "api.z.ai" },
                { label: I18n.tr("China (open.bigmodel.cn)"), value: "open.bigmodel.cn" }
            ]
            defaultValue: "api.z.ai"
        }

        Separator {}

        StringSettingPlus {
            id: kimiApiKey
            settingKey: "kimiApiKey"
            label: I18n.tr("Kimi Code API Key")
            description: I18n.tr("Recommended. Without a key, the plugin uses the kimi login, which expires a few minutes after kimi closes.")
            placeholder: "sk-kimi-..."
            defaultValue: ""
        }

        Separator {}

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
            id: openRouterApiKey
            settingKey: "openRouterApiKey"
            label: I18n.tr("OpenRouter API Key")
            description: I18n.tr("Your API key from openrouter.ai/settings/keys.")
            placeholder: "sk-or-..."
            defaultValue: ""
        }
    }
}
