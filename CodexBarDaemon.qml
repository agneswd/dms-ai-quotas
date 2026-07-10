import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "codexbar"

    property int refreshInterval: pluginData.refreshInterval || 60
    property var usageData: null
    property bool fetchFailed: false
    property string providers: pluginData.providers || "all"

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
            "CODEXBAR_PROVIDERS='" + root.providers + "' " +
            "CODEXBAR_USAGE_MOCK=${CODEXBAR_USAGE_MOCK:-} " +
            "sh '" + Qt.resolvedUrl("fetch-usage.sh") + "'"
        ]
        stdout: SplitParser {
            onRead: line => {
                if (!line.trim()) return
                try {
                    var parsed = JSON.parse(line)
                    root.usageData = parsed
                    root.fetchFailed = false
                    pluginService.savePluginState("codexbar", "lastData", parsed)
                    root.usageUpdated()
                } catch (e) {
                    console.warn("codexbar: JSON parse error:", e)
                    root.fetchFailed = true
                }
            }
        }
        stderr: SplitParser {
            onRead: line => {
                if (line.trim()) console.warn("codexbar fetch:", line)
            }
        }
        onExited: code => {
            if (code !== 0 && !root.usageData) {
                root.fetchFailed = true
            }
        }
    }

    Component.onCompleted: {
        var cached = pluginService.loadPluginState("codexbar", "lastData", null)
        if (cached) {
            root.usageData = cached
        }
    }

    function providersList() {
        if (!root.usageData) return []
        return root.usageData
    }

    function findProvider(id) {
        if (!root.usageData) return null
        for (var i = 0; i < root.usageData.length; i++) {
            if (root.usageData[i].provider === id) return root.usageData[i]
        }
        return null
    }
}
