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
    property string pluginDir: {
        var url = Qt.resolvedUrl(".")
        var path = url.toString()
        if (path.indexOf("file://") === 0) path = path.substring(7)
        return path
    }

    property var usageData: null

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            try {
                fetchProcess.running = true
            } catch (e) {
                console.warn("aiQuotas: failed to start fetch:", e)
            }
        }
    }

    Process {
        id: fetchProcess
        command: ["sh", "-c",
            "AIQ_OPENCODE_ENABLED='" + (root.openCodeEnabled ? "1" : "0") + "' " +
            "AIQ_DEEPSEEK_ENABLED='" + (root.deepSeekEnabled ? "1" : "0") + "' " +
            "DEEPSEEK_API_KEY='" + root.deepSeekApiKey + "' " +
            "AIQ_USAGE_MOCK=${AIQ_USAGE_MOCK:-} " +
            "sh '" + root.pluginDir + "fetch-usage.sh'"
        ]
        stdout: SplitParser {
            onRead: line => {
                try {
                    var trimmed = line.trim()
                    if (trimmed.length === 0) return
                    var parsed = JSON.parse(trimmed)
                    root.usageData = parsed
                    pluginService.savePluginState("aiQuotas", "lastData", parsed)
                } catch (e) {
                    // Ignore partial lines.
                }
            }
        }
        stderr: SplitParser {
            onRead: line => {}
        }
        onExited: code => {}
    }

    Component.onCompleted: {
        try {
            var cached = pluginService.loadPluginState("aiQuotas", "lastData", null)
            if (cached) root.usageData = cached
        } catch (e) {}
    }
}
