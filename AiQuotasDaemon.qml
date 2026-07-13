import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiQuotas"

    property int refreshInterval: pluginData.refreshInterval || 60
    property bool codexEnabled: pluginData.codexEnabled !== false
    property bool openCodeEnabled: pluginData.openCodeEnabled !== false
    property bool deepSeekEnabled: pluginData.deepSeekEnabled !== false
    property bool antigravityEnabled: pluginData.antigravityEnabled !== false
    property string deepSeekApiKey: pluginData.deepSeekApiKey || ""
    property string openCodeWorkspaceId: pluginData.openCodeWorkspaceId || ""
    property string openCodeAuthCookie: pluginData.openCodeAuthCookie || ""
    property string pluginDir: {
        var url = Qt.resolvedUrl(".")
        var path = url.toString()
        if (path.indexOf("file://") === 0) path = path.substring(7)
        return path
    }

    property var usageData: null
    property bool fetchQueued: false

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        running: true
        repeat: true
        triggeredOnStart: false
        onTriggered: root.requestFetch()
    }

    Process {
        id: fetchProcess
        command: [
            "env",
            "AIQ_CODEX_ENABLED=" + (root.codexEnabled ? "1" : "0"),
            "AIQ_OPENCODE_ENABLED=" + (root.openCodeEnabled ? "1" : "0"),
            "AIQ_DEEPSEEK_ENABLED=" + (root.deepSeekEnabled ? "1" : "0"),
            "AIQ_ANTIGRAVITY_ENABLED=" + (root.antigravityEnabled ? "1" : "0"),
            "DEEPSEEK_API_KEY=" + root.deepSeekApiKey,
            "OPENCODE_GO_WORKSPACE_ID=" + root.openCodeWorkspaceId,
            "OPENCODE_GO_AUTH_COOKIE=" + root.openCodeAuthCookie,
            "sh", root.pluginDir + "fetch-usage.sh"
        ]
        stdout: SplitParser {
            onRead: line => {
                try {
                    var t = line.trim()
                    if (t.length === 0) return
                    root.usageData = JSON.parse(t)
                    pluginService.savePluginState("aiQuotas", "lastData", root.usageData)
                } catch (e) {}
            }
        }
        stderr: SplitParser { onRead: line => {} }
        onExited: code => {
            if (root.fetchQueued) {
                root.fetchQueued = false
                Qt.callLater(root.requestFetch)
            }
        }
    }

    function requestFetch() {
        if (fetchProcess.running) {
            fetchQueued = true
            return
        }
        fetchProcess.running = true
    }

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === "aiQuotas")
                Qt.callLater(root.requestFetch)
        }
    }

    Component.onCompleted: {
        try {
            var c = pluginService.loadPluginState("aiQuotas", "lastData", null)
            if (c) root.usageData = c
        } catch (e) {}
        // PluginComponent loads pluginData after child completion; defer the first request.
        Qt.callLater(root.requestFetch)
    }
}
