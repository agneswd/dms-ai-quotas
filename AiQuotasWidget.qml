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
    property bool fetchFailed: false

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
                    root.fetchFailed = false
                } catch (e) {
                    // Ignore partial lines from multi-line output.
                }
            }
        }
        stderr: SplitParser {
            onRead: line => {}
        }
        onExited: code => {
            if (code !== 0 && !root.usageData) {
                root.fetchFailed = true
            }
        }
    }

    Component.onCompleted: {
        try {
            var cached = pluginService.loadPluginState("aiQuotas", "lastData", null)
            if (cached) root.usageData = cached
        } catch (e) {}
    }

    function openCodeEntries() {
        try {
            if (!usageData || !usageData.opencode) return []
            if (usageData.opencode.status !== "ok") return []
            return usageData.opencode.entries || []
        } catch (e) { return [] }
    }

    function deepSeekBalance() {
        try {
            if (!usageData || !usageData.deepseek) return null
            if (usageData.deepseek.status !== "ok") return null
            if (!usageData.deepseek.balances || usageData.deepseek.balances.length === 0) return null
            return usageData.deepseek.balances[0]
        } catch (e) { return null }
    }

    function color(pct) {
        if (pct >= 90) return Theme.error
        if (pct >= 70) return Theme.warning
        return Theme.primary
    }

    function countdown(resetAt) {
        try {
            if (!resetAt) return "--"
            var diff = resetAt - (Date.now() / 1000)
            if (diff <= 0) return "now"
            var h = Math.floor(diff / 3600)
            var m = Math.floor((diff % 3600) / 60)
            if (h > 0) return h + "h " + m + "m"
            return m + "m"
        } catch (e) { return "--" }
    }

    function formatBalance(b) {
        try {
            if (!b) return "--"
            return b.currency + " " + (parseFloat(b.total) || 0).toFixed(2)
        } catch (e) { return "--" }
    }

    function primaryPct() {
        try {
            var entries = openCodeEntries()
            if (entries.length === 0) return -1
            return entries[0].percentUsed || 0
        } catch (e) { return -1 }
    }

    horizontalBarPill: Component {
        StyledRect {
            id: pill
            implicitWidth: row.implicitWidth + Theme.spacingM * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            RowLayout {
                id: row
                anchors.centerIn: parent
                spacing: Theme.spacingS

                StyledText {
                    visible: !root.usageData
                    text: "\u2733 --"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                Repeater {
                    model: root.usageData && root.openCodeEnabled && root.primaryPct() >= 0 ? [1] : []
                    delegate: Row {
                        spacing: 4
                        Layout.alignment: Qt.AlignVCenter
                        UsageRing {
                            percentage: root.primaryPct()
                            ringColor: root.color(root.primaryPct())
                            diameter: Math.max(12, Math.min(pill.height - 9, 18))
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: Math.round(root.primaryPct()) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                Repeater {
                    model: root.usageData && root.deepSeekEnabled && root.deepSeekBalance() ? [1] : []
                    delegate: Row {
                        spacing: 4
                        Layout.alignment: Qt.AlignVCenter
                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: root.formatBalance(root.deepSeekBalance())
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
            implicitHeight: col.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            ColumnLayout {
                id: col
                anchors.centerIn: parent
                spacing: Theme.spacingS

                StyledText {
                    visible: !root.usageData
                    text: "\u2733"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                Repeater {
                    model: root.usageData && root.openCodeEnabled && root.primaryPct() >= 0 ? [1] : []
                    delegate: Column {
                        spacing: 1
                        Layout.alignment: Qt.AlignHCenter
                        UsageRing {
                            percentage: root.primaryPct()
                            ringColor: root.color(root.primaryPct())
                            diameter: Math.max(12, Math.min(pillV.width - 8, 18))
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: Math.round(root.primaryPct()) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                Repeater {
                    model: root.usageData && root.deepSeekEnabled && root.deepSeekBalance() ? [1] : []
                    delegate: Column {
                        spacing: 1
                        Layout.alignment: Qt.AlignHCenter
                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            color: Theme.primary
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: {
                                var b = root.deepSeekBalance()
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
                    model: root.openCodeEnabled ? root.openCodeEntries() : []
                    delegate: Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        Row {
                            width: parent.width
                            spacing: Theme.spacingM
                            UsageRing {
                                percentage: modelData.percentUsed || 0
                                ringColor: root.color(modelData.percentUsed || 0)
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
                                    text: (modelData.percentRemaining != null ? modelData.percentRemaining + "% remaining" : "--")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                                StyledText {
                                    visible: root.showResetTime && modelData.resetAt > 0
                                    text: "Resets in " + root.countdown(modelData.resetAt)
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }
                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.outlineVariant
                            opacity: 0.3
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.openCodeEnabled && root.openCodeEntries().length === 0
                    text: {
                        if (!root.usageData) return "Loading..."
                        var oc = root.usageData.opencode
                        if (oc && oc.error) return oc.error
                        if (oc && oc.status === "unavailable") return "No OpenCode config. Set workspace ID and auth cookie."
                        return "No OpenCode data."
                    }
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                Repeater {
                    model: root.deepSeekEnabled && root.deepSeekBalance() ? [root.deepSeekBalance()] : []
                    delegate: Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.outlineVariant
                            opacity: 0.3
                        }
                        Row {
                            width: parent.width
                            spacing: Theme.spacingM
                            Rectangle {
                                width: 28
                                height: 28
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHighest
                                anchors.verticalCenter: parent.verticalCenter
                                StyledText {
                                    anchors.centerIn: parent
                                    text: "DS"
                                    color: Theme.primary
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                }
                            }
                            Column {
                                width: parent.width - 40
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                StyledText {
                                    text: "DeepSeek"
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                }
                                StyledText {
                                    text: "Balance: " + root.formatBalance(modelData)
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.deepSeekEnabled && !root.deepSeekBalance() && root.deepSeekApiKey.length > 0
                    text: "Could not load DeepSeek balance."
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    width: parent.width
                    visible: root.deepSeekEnabled && !root.deepSeekBalance() && root.deepSeekApiKey.length === 0
                    text: "DeepSeek API key not set. Add it in plugin settings."
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }
}
