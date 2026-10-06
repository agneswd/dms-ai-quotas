// Quickshell config for tests/render.sh. Do not run it directly.
//
// Loads the plugin daemon and widget with real DMS components and a small
// in-memory PluginService. The daemon runs fetch-usage.sh, which prints the
// AIQ_USAGE_MOCK file. The config then saves PNG files to AIQ_SHOT_DIR:
// one per provider tab (pill above the popout), the vertical pill, and the
// settings page. It logs "AIQ pill:" and "AIQ done" lines for render.sh.
import QtQuick
import Quickshell
import qs.Common
import qs.DankCommon.Common as DC

ShellRoot {
    id: shell

    readonly property string pluginDir: Quickshell.env("AIQ_PLUGIN_DIR")
    readonly property string shotDir: Quickshell.env("AIQ_SHOT_DIR")
    property var widget: null
    property var daemon: null
    property var shots: []

    Component.onCompleted: {
        DC.Style.theme = Theme
        DC.Style.settings = SettingsData
        DC.I18n.backend = I18n
        DC.Paths.backend = Paths
        DC.Log.backend = Log
    }

    QtObject {
        id: service
        signal pluginDataChanged(string pluginId)
        signal pluginStateChanged(string pluginId)
        property var data: ({})
        property var state: ({})
        function getPluginVariants(id) { return [] }
        function loadPluginData(id, key, fallback) { return data[key] !== undefined ? data[key] : fallback }
        function savePluginData(id, key, value) { data[key] = value }
        function loadPluginState(id, key, fallback) { return state[key] !== undefined ? state[key] : fallback }
        function savePluginState(id, key, value) {
            state[key] = value
            pluginStateChanged(id)
        }
    }

    function load(file) {
        var component = Qt.createComponent("file://" + pluginDir + "/" + file)
        if (component.status === Component.Error) console.warn("AIQ ERROR " + component.errorString())
        return component
    }

    FloatingWindow {
        implicitWidth: 760
        implicitHeight: 2400
        color: "transparent"
        visible: true

        Column {
            id: stage
            padding: Theme.spacingL
            spacing: Theme.spacingS

            Item {
                id: pillHost
                property real widgetThickness: 34
                width: popoutHost.width
                height: widgetThickness
            }

            Rectangle {
                id: popoutHost
                width: shell.widget ? shell.widget.popoutWidth : 420
                height: childrenRect.height + Theme.spacingL
                radius: Theme.cornerRadius * 1.5
                color: Theme.popupBackground ? Theme.popupBackground() : Theme.surfaceContainer
                border.color: Theme.outlineVariant
                border.width: 1
            }
        }

        Item {
            id: verticalStage
            x: 600
            width: 60
            height: verticalHost.height + Theme.spacingL * 2

            Item {
                id: verticalHost
                property real widgetThickness: 40
                x: Theme.spacingS; y: Theme.spacingL
                width: 40; height: childrenRect.height
            }
        }

        Item {
            id: settingsStage
            y: 1000
            width: 520
            height: childrenRect.height
        }
    }

    Timer {
        running: true
        interval: 500
        onTriggered: {
            shell.daemon = shell.load("AiQuotasDaemon.qml").createObject(shell, { pluginService: service, pluginId: "aiQuotas" })
            shell.widget = shell.load("AiQuotasWidget.qml").createObject(shell, { pluginService: service, pluginId: "aiQuotas" })
            dataTimer.start()
        }
    }

    // Wait for the daemon to deliver data, then build the scene.
    Timer {
        id: dataTimer
        interval: 250
        repeat: true
        property int tries: 0
        onTriggered: {
            tries++
            if (!shell.widget.usageData && tries < 40) return
            stop()
            var pill = shell.widget.horizontalBarPill.createObject(pillHost)
            pill.anchors.horizontalCenter = pillHost.horizontalCenter
            shell.widget.verticalBarPill.createObject(verticalHost)
            shell.widget.popoutContent.createObject(popoutHost, { width: popoutHost.width, y: Theme.spacingS })
            shell.load("AiQuotasSettings.qml").createObject(settingsStage, { pluginService: service, pluginId: "aiQuotas", width: 480 })
            console.warn("AIQ pill: " + shell.widget.pillItems().map(function (item) {
                return item.provider + "=" + (item.isBalance ? item.value : item.shortValue)
            }).join(" "))
            var tabs = shell.widget.enabledProviders().map(function (p) { return { tab: p.id, item: stage } })
            shell.shots = tabs.concat([{ tab: "", item: verticalStage, name: "vertical" }, { tab: "", item: settingsStage, name: "settings" }])
            shell.nextShot()
        }
    }

    // Pin behavior on the real widget: a missing pin falls back to the first
    // window, unpinning the last visible window hides the provider even when a
    // missing pin remains, and pinning shows it again.
    function checkPins() {
        var pinned = function () {
            return widget.pillItems().filter(function (item) { return item.provider === "codex" })
                .map(function (item) { return item.pinKey }).join(",")
        }
        var saved = widget.pinState
        var withCodex = function (pins) {
            var state = JSON.parse(JSON.stringify(saved))
            state.codex = pins
            widget.pinState = state
        }
        withCodex(["Missing window"])
        var steps = [pinned()]
        withCodex(["Missing window", "Weekly"])
        steps.push(pinned())
        widget.togglePin("codex", "Weekly")
        steps.push(pinned())
        widget.togglePin("codex", "5h")
        steps.push(pinned())
        widget.pinState = saved
        console.warn("AIQ pins: " + steps.join(" | "))
    }

    // Select a tab, wait for the tab animation, save, then continue.
    function nextShot() {
        if (shots.length === 0) {
            checkPins()
            console.warn("AIQ done")
            Qt.callLater(Qt.quit)
            return
        }
        var shot = shots[0]
        if (shot.tab) widget.selectedProvider = shot.tab
        settleTimer.start()
    }

    Timer {
        id: settleTimer
        interval: 900
        onTriggered: {
            var shot = shell.shots[0]
            shot.item.grabToImage(function (result) {
                result.saveToFile(shell.shotDir + "/" + (shot.name || shot.tab) + ".png")
                shell.shots = shell.shots.slice(1)
                shell.nextShot()
            })
        }
    }
}
