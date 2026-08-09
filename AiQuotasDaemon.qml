import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiQuotas"

    property int refreshInterval: pluginData.refreshInterval || 60
    property bool claudeEnabled: pluginData.claudeEnabled !== false
    property bool codexEnabled: pluginData.codexEnabled !== false
    property bool openCodeEnabled: pluginData.openCodeEnabled !== false
    property bool deepSeekEnabled: pluginData.deepSeekEnabled !== false
    property bool antigravityEnabled: pluginData.antigravityEnabled !== false
    property bool grokEnabled: pluginData.grokEnabled !== false
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
    property bool queuedForce: false
    property bool activeForce: false
    property string lastFetchSignature: ""

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
            "AIQ_CLAUDE_ENABLED=" + (root.claudeEnabled ? "1" : "0"),
            "AIQ_CODEX_ENABLED=" + (root.codexEnabled ? "1" : "0"),
            "AIQ_OPENCODE_ENABLED=" + (root.openCodeEnabled ? "1" : "0"),
            "AIQ_DEEPSEEK_ENABLED=" + (root.deepSeekEnabled ? "1" : "0"),
            "AIQ_GROK_ENABLED=" + (root.grokEnabled ? "1" : "0"),
            "AIQ_ANTIGRAVITY_ENABLED=" + (root.antigravityEnabled ? "1" : "0"),
            "AIQ_FORCE_REFRESH=" + (root.activeForce ? "1" : "0"),
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
                var force = root.queuedForce
                root.fetchQueued = false
                root.queuedForce = false
                Qt.callLater(function () { root.requestFetch(force) })
            }
        }
    }

    function fetchSignature() {
        return [claudeEnabled, codexEnabled, openCodeEnabled, deepSeekEnabled,
            antigravityEnabled, grokEnabled, deepSeekApiKey,
            openCodeWorkspaceId, openCodeAuthCookie].join("\u001f")
    }

    function requestFetch(force) {
        if (fetchProcess.running) {
            fetchQueued = true
            queuedForce = queuedForce || force === true
            return
        }
        activeForce = force === true
        fetchProcess.running = true
    }

    function fetchIfSettingsChanged() {
        var signature = fetchSignature()
        if (lastFetchSignature === "") {
            lastFetchSignature = signature
            return
        }
        if (signature === lastFetchSignature) return
        lastFetchSignature = signature
        requestFetch(true)
    }

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === "aiQuotas")
                Qt.callLater(root.fetchIfSettingsChanged)
        }
    }

    Component.onCompleted: {
        try {
            var c = pluginService.loadPluginState("aiQuotas", "lastData", null)
            if (c) root.usageData = c
        } catch (e) {}
        // PluginComponent loads pluginData after child completion; defer the first request.
        Qt.callLater(function () {
            root.lastFetchSignature = root.fetchSignature()
            root.requestFetch(false)
        })
    }
}
