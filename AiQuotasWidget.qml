import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiQuotas"

    property int refreshInterval: pluginData.refreshInterval || 60
    property bool openCodeEnabled: pluginData.openCodeEnabled !== false
    property bool deepSeekEnabled: pluginData.deepSeekEnabled !== false
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
    property bool fetchFailed: false

    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            try { fetchProcess.running = true } catch (e) {}
        }
    }

    Process {
        id: fetchProcess
        command: ["sh", "-c",
            "AIQ_OPENCODE_ENABLED='" + (root.openCodeEnabled ? "1" : "0") + "' " +
            "AIQ_DEEPSEEK_ENABLED='" + (root.deepSeekEnabled ? "1" : "0") + "' " +
            "DEEPSEEK_API_KEY='" + root.deepSeekApiKey + "' " +
            "OPENCODE_GO_WORKSPACE_ID='" + root.openCodeWorkspaceId + "' " +
            "OPENCODE_GO_AUTH_COOKIE='" + root.openCodeAuthCookie + "' " +
            "AIQ_USAGE_MOCK=${AIQ_USAGE_MOCK:-} " +
            "sh '" + root.pluginDir + "fetch-usage.sh'"
        ]
        stdout: SplitParser {
            onRead: line => {
                try {
                    var t = line.trim()
                    if (t.length === 0) return
                    root.usageData = JSON.parse(t)
                    root.fetchFailed = false
                } catch (e) {}
            }
        }
        stderr: SplitParser { onRead: line => {} }
        onExited: code => {
            if (code !== 0 && !root.usageData) root.fetchFailed = true
        }
    }

    Component.onCompleted: {
        try {
            var c = pluginService.loadPluginState("aiQuotas", "lastData", null)
            if (c) root.usageData = c
        } catch (e) {}
    }

    function ocEntries() {
        try {
            if (!usageData || !usageData.opencode) return []
            if (usageData.opencode.status !== "ok") return []
            return usageData.opencode.entries || []
        } catch (e) { return [] }
    }

    function dsBalance() {
        try {
            if (!usageData || !usageData.deepseek) return null
            if (usageData.deepseek.status !== "ok") return null
            var b = usageData.deepseek.balances
            if (!b || b.length === 0) return null
            return b[0]
        } catch (e) { return null }
    }

    function clr(pct) {
        if (pct >= 90) return Theme.error
        if (pct >= 70) return Theme.warning
        return Theme.primary
    }

    function cdown(t) {
        try {
            if (!t) return "--"
            var d = t - Date.now() / 1000
            if (d <= 0) return "now"
            var h = Math.floor(d / 3600)
            var m = Math.floor((d % 3600) / 60)
            return h > 0 ? h + "h " + m + "m" : m + "m"
        } catch (e) { return "--" }
    }

    function fmtBal(b) {
        try {
            if (!b) return "--"
            return b.currency + " " + (parseFloat(b.total) || 0).toFixed(2)
        } catch (e) { return "--" }
    }

    function pPct() {
        try {
            var e = ocEntries()
            return e.length > 0 ? (e[0].percentUsed || 0) : -1
        } catch (e) { return -1 }
    }

    // --- Bar Pills ---

    horizontalBarPill: Component {
        StyledRect {
            id: pill
            implicitWidth: hRow.implicitWidth + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Row {
                id: hRow
                anchors.centerIn: parent
                spacing: Theme.spacingS

                StyledText {
                    visible: !root.usageData
                    text: "\u2733 --"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                Repeater {
                    model: root.usageData && root.openCodeEnabled && root.pPct() >= 0 ? [1] : []
                    delegate: Row {
                        spacing: 4
                        UsageRing {
                            percentage: root.pPct()
                            ringColor: root.clr(root.pPct())
                            diameter: Math.max(12, Math.min(pill.height - 9, 18))
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: Math.round(root.pPct()) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                Repeater {
                    model: root.usageData && root.deepSeekEnabled && root.dsBalance() ? [1] : []
                    delegate: Row {
                        spacing: 4
                        Rectangle {
                            width: 8; height: 8; radius: 4
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: root.fmtBal(root.dsBalance())
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        StyledRect {
            id: pillV
            width: parent.widgetThickness
            implicitHeight: vCol.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Column {
                id: vCol
                anchors.centerIn: parent
                spacing: Theme.spacingS

                StyledText {
                    visible: !root.usageData
                    text: "\u2733"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                Repeater {
                    model: root.usageData && root.openCodeEnabled && root.pPct() >= 0 ? [1] : []
                    delegate: Column {
                        spacing: 1
                        UsageRing {
                            percentage: root.pPct()
                            ringColor: root.clr(root.pPct())
                            diameter: Math.max(12, Math.min(pillV.width - 8, 18))
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: Math.round(root.pPct()) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                Repeater {
                    model: root.usageData && root.deepSeekEnabled && root.dsBalance() ? [1] : []
                    delegate: Column {
                        spacing: 1
                        Rectangle {
                            width: 8; height: 8; radius: 4
                            color: Theme.primary
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: {
                                var b = root.dsBalance()
                                return b ? (parseFloat(b.total) || 0).toFixed(0) : "--"
                            }
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }
            }
        }
    }

    // --- Popout ---

    popoutWidth: 360
    popoutHeight: 400
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "AI Quotas"
            showCloseButton: true
            closePopout: function () { popout.visible = false }

            Column {
                width: parent.width
                spacing: Theme.spacingM

                Repeater {
                    model: root.openCodeEnabled ? root.ocEntries() : []
                    delegate: Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        Row {
                            width: parent.width
                            spacing: Theme.spacingM
                            UsageRing {
                                percentage: modelData.percentUsed || 0
                                ringColor: root.clr(modelData.percentUsed || 0)
                                diameter: 28
                                thickness: 3
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Column {
                                width: parent.width - 40
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                StyledText {
                                    text: modelData.name || "Unknown"
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                }
                                StyledText {
                                    text: modelData.percentRemaining != null ? modelData.percentRemaining + "% remaining" : "--"
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                                StyledText {
                                    visible: root.showResetTime && modelData.resetAt > 0
                                    text: "Resets in " + root.cdown(modelData.resetAt)
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }
                        Rectangle { width: parent.width; height: 1; color: Theme.outlineVariant; opacity: 0.3 }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.openCodeEnabled && root.ocEntries().length === 0
                    text: {
                        if (!root.usageData) return "Loading..."
                        var o = root.usageData.opencode
                        if (o && o.error) return o.error
                        if (o && o.status === "unavailable") return "No OpenCode config found."
                        return "No OpenCode data."
                    }
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                Repeater {
                    model: root.deepSeekEnabled && root.dsBalance() ? [root.dsBalance()] : []
                    delegate: Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        Rectangle { width: parent.width; height: 1; color: Theme.outlineVariant; opacity: 0.3 }
                        Row {
                            width: parent.width
                            spacing: Theme.spacingM
                            Rectangle {
                                width: 28; height: 28; radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHighest
                                anchors.verticalCenter: parent.verticalCenter
                                StyledText {
                                    anchors.centerIn: parent; text: "DS"
                                    color: Theme.primary; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold
                                }
                            }
                            Column {
                                width: parent.width - 40
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                StyledText { text: "DeepSeek"; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeMedium; font.weight: Font.Medium }
                                StyledText { text: "Balance: " + root.fmtBal(modelData); color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.deepSeekEnabled && !root.dsBalance() && root.deepSeekApiKey.length === 0
                    text: "DeepSeek API key not set. Add it in plugin settings."
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }
}
