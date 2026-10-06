import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiQuotas"

    // Plugin settings passed to fetch-usage.sh as environment variables, never as
    // arguments. Provider toggles default to on.
    readonly property var toggleSettings: ({
        claudeEnabled: "AIQ_CLAUDE_ENABLED",
        codexEnabled: "AIQ_CODEX_ENABLED",
        openCodeEnabled: "AIQ_OPENCODE_ENABLED",
        zaiEnabled: "AIQ_ZAI_ENABLED",
        kimiEnabled: "AIQ_KIMI_ENABLED",
        deepSeekEnabled: "AIQ_DEEPSEEK_ENABLED",
        openRouterEnabled: "AIQ_OPENROUTER_ENABLED",
        grokEnabled: "AIQ_GROK_ENABLED",
        antigravityEnabled: "AIQ_ANTIGRAVITY_ENABLED"
    })
    readonly property var valueSettings: ({
        openCodeApiKey: "OPENCODE_GO_API_KEY",
        zaiApiKey: "ZAI_API_KEY",
        zaiRegion: "ZAI_API_HOST",
        kimiApiKey: "KIMI_API_KEY",
        deepSeekApiKey: "DEEPSEEK_API_KEY",
        openRouterApiKey: "OPENROUTER_API_KEY"
    })

    property int refreshInterval: pluginData.refreshInterval || 60
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

    // Environment for one fetch, without the force flag.
    function settingsEnvironment() {
        var env = {}
        for (var toggle in toggleSettings)
            env[toggleSettings[toggle]] = pluginData[toggle] !== false ? "1" : "0"
        for (var setting in valueSettings)
            env[valueSettings[setting]] = String(pluginData[setting] || "")
        return env
    }

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
        command: ["sh", root.pluginDir + "fetch-usage.sh"]
        environment: {
            var env = root.settingsEnvironment()
            env.AIQ_FORCE_REFRESH = root.activeForce ? "1" : "0"
            return env
        }
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
        return JSON.stringify(settingsEnvironment())
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
