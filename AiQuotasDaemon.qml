import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiQuotas"

    property int refreshInterval: pluginData.refreshInterval || 60
    property bool openCodeEnabled: pluginData.openCodeEnabled !== false
    property bool deepSeekEnabled: pluginData.deepSeekEnabled !== false
    property string deepSeekApiKey: pluginData.deepSeekApiKey || ""

    property var usageData: null
    property bool fetchFailed: false
    property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

    signal usageUpdated()

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: fetchProcess.running = true
    }

    Process {
        id: fetchProcess
        command: [
            "sh", "-c",
            "AIQ_OPENCODE_ENABLED='" + (root.openCodeEnabled ? "1" : "0") + "' " +
            "AIQ_DEEPSEEK_ENABLED='" + (root.deepSeekEnabled ? "1" : "0") + "' " +
            "DEEPSEEK_API_KEY='" + root.deepSeekApiKey + "' " +
            "AIQ_USAGE_MOCK=${AIQ_USAGE_MOCK:-} " +
            "sh '" + root.pluginDir + "fetch-usage.sh'"
        ]
        stdout: SplitParser {
            onRead: line => {
                if (!line.trim()) return
                try {
                    var parsed = JSON.parse(line)
                    root.usageData = parsed
                    root.fetchFailed = false
                    pluginService.savePluginState("aiQuotas", "lastData", parsed)
                    root.usageUpdated()
                } catch (e) {
                    console.warn("aiQuotas: JSON parse error:", e)
                    root.fetchFailed = true
                }
            }
        }
        stderr: SplitParser {
            onRead: line => {
                if (line.trim()) console.warn("aiQuotas fetch:", line)
            }
        }
        onExited: code => {
            if (code !== 0 && !root.usageData) {
                root.fetchFailed = true
            }
        }
    }

    Component.onCompleted: {
        var cached = pluginService.loadPluginState("aiQuotas", "lastData", null)
        if (cached) {
            root.usageData = cached
        }
    }

    function openCodeProviders() {
        if (!usageData || !usageData.opencode) return []
        if (usageData.opencode.status !== "ok") return []
        return usageData.opencode.providers || []
    }

    function deepSeekBalance() {
        if (!usageData || !usageData.deepseek) return null
        if (usageData.deepseek.status !== "ok") return null
        if (!usageData.deepseek.balances || usageData.deepseek.balances.length === 0) return null
        return usageData.deepseek.balances[0]
    }
}
