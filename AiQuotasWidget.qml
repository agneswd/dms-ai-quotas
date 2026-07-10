import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiQuotas"

    readonly property int warnPct: 70
    readonly property int critPct: 90

    readonly property int refreshInterval: pluginData.refreshInterval || 60
    readonly property bool openCodeEnabled: pluginData.openCodeEnabled !== false
    readonly property bool deepSeekEnabled: pluginData.deepSeekEnabled !== false
    readonly property bool showResetTime: pluginData.showResetTime !== false
    readonly property string deepSeekApiKey: pluginData.deepSeekApiKey || ""

    property var usageData: null
    property bool fetchFailed: false
    property real now: Date.now() / 1000
    property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

    function closePopout() {
        root.closePopout()
    }

    Timer {
        id: tickTimer
        interval: 1000
        running: root.showResetTime
        repeat: true
        onTriggered: root.now = Date.now() / 1000
    }

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
                } catch (e) {
                    root.fetchFailed = true
                }
            }
        }
        stderr: SplitParser {
            onRead: line => {
                if (line.trim()) console.warn("aiQuotas:", line)
            }
        }
        onExited: code => {
            if (code !== 0 && !root.usageData) root.fetchFailed = true
        }
    }

    // --- Helper functions ---

    function color(pct) {
        return pct >= critPct ? Theme.error : pct >= warnPct ? Theme.warning : Theme.primary
    }

    function countdown(resetAt) {
        if (!resetAt) return "--"
        var diff = resetAt - now
        if (diff <= 0) return "now"
        var h = Math.floor(diff / 3600)
        var m = Math.floor((diff % 3600) / 60)
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }

    function openCodeProviders() {
        if (!usageData || !usageData.opencode) return []
        if (usageData.opencode.status !== "ok") return []
        return usageData.opencode.providers || []
    }

    function openCodePrimaryPct() {
        var providers = openCodeProviders()
        if (providers.length === 0) return -1
        // Find the first provider with entries and use its first entry.
        for (var i = 0; i < providers.length; i++) {
            var entries = providers[i].entries
            if (entries && entries.length > 0) {
                return 100 - (entries[0].percentRemaining || 0)
            }
        }
        return -1
    }

    function deepSeekBalance() {
        if (!usageData || !usageData.deepseek) return null
        if (usageData.deepseek.status !== "ok") return null
        if (!usageData.deepseek.balances || usageData.deepseek.balances.length === 0) return null
        return usageData.deepseek.balances[0]
    }

    function deepSeekAvailable() {
        var b = deepSeekBalance()
        if (!b) return false
        return b.isAvailable !== false
    }

    function formatBalance(b) {
        if (!b) return "--"
        var total = parseFloat(b.total) || 0
        return b.currency + " " + total.toFixed(2)
    }

    function allEntries() {
        var out = []
        var providers = openCodeProviders()
        for (var i = 0; i < providers.length; i++) {
            var entries = providers[i].entries || []
            for (var j = 0; j < entries.length; j++) {
                out.push({
                    provider: providers[i].id,
                    name: entries[j].name || entries[j].window,
                    window: entries[j].window || "",
                    percentUsed: 100 - (entries[j].percentRemaining || 0),
                    percentRemaining: entries[j].percentRemaining || 0,
                    resetAt: entries[j].resetAt || 0,
                    unlimited: entries[j].unlimited || false
                })
            }
        }
        // Sort by percent used descending.
        out.sort(function (a, b) { return b.percentUsed - a.percentUsed })
        return out
    }

    // --- Bar pill ---

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

                // Loading / error state.
                StyledText {
                    visible: !root.usageData
                    text: "\u2733 --"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                // OpenCode ring.
                Repeater {
                    model: root.usageData && root.openCodeEnabled && root.openCodePrimaryPct() >= 0 ? [1] : []
                    delegate: Row {
                        spacing: 4
                        Layout.alignment: Qt.AlignVCenter
                        UsageRing {
                            percentage: root.openCodePrimaryPct()
                            ringColor: root.color(root.openCodePrimaryPct())
                            diameter: Math.max(12, Math.min(pill.height - 9, 18))
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: Math.round(root.openCodePrimaryPct()) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // DeepSeek balance indicator.
                Repeater {
                    model: root.usageData && root.deepSeekEnabled && root.deepSeekBalance() ? [1] : []
                    delegate: Row {
                        spacing: 4
                        Layout.alignment: Qt.AlignVCenter

                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            color: root.deepSeekAvailable() ? Theme.primary : Theme.error
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

                // OpenCode ring.
                Repeater {
                    model: root.usageData && root.openCodeEnabled && root.openCodePrimaryPct() >= 0 ? [1] : []
                    delegate: Column {
                        spacing: 1
                        Layout.alignment: Qt.AlignHCenter
                        UsageRing {
                            percentage: root.openCodePrimaryPct()
                            ringColor: root.color(root.openCodePrimaryPct())
                            diameter: Math.max(12, Math.min(pillV.width - 8, 18))
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: Math.round(root.openCodePrimaryPct()) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                // DeepSeek dot.
                Repeater {
                    model: root.usageData && root.deepSeekEnabled && root.deepSeekBalance() ? [1] : []
                    delegate: Column {
                        spacing: 1
                        Layout.alignment: Qt.AlignHCenter
                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            color: root.deepSeekAvailable() ? Theme.primary : Theme.error
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: {
                                var b = root.deepSeekBalance()
                                if (!b) return "--"
                                return (parseFloat(b.total) || 0).toFixed(0)
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

    popoutWidth: 380
    popoutHeight: 480
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "AI Quotas"
            showCloseButton: true
            closePopout: function () { root.closePopout() }

            Flickable {
                width: parent.width
                height: parent.height
                contentHeight: contentColumn.implicitHeight
                clip: true

                Column {
                    id: contentColumn
                    width: parent.width
                    spacing: Theme.spacingM

                    // --- OpenCode Section ---
                    Repeater {
                        model: root.openCodeEnabled ? root.allEntries() : []
                        delegate: Column {
                            width: parent.width
                            spacing: Theme.spacingXS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM

                                UsageRing {
                                    percentage: modelData.unlimited ? 0 : modelData.percentUsed
                                    ringColor: modelData.unlimited ? Theme.primary : root.color(modelData.percentUsed)
                                    diameter: 32
                                    thickness: 3.5
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    width: parent.width - 44
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2

                                    StyledText {
                                        text: modelData.name
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                    }

                                    StyledText {
                                        text: modelData.unlimited
                                            ? "Unlimited"
                                            : modelData.percentRemaining + "% remaining"
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }

                                    StyledText {
                                        visible: root.showResetTime && modelData.resetAt > 0 && !modelData.unlimited
                                        property real resetAt: modelData.resetAt
                                        text: "Resets in " + root.countdown(resetAt)
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

                    // OpenCode unavailable message.
                    StyledText {
                        width: parent.width
                        visible: root.openCodeEnabled && root.openCodeProviders().length === 0
                        text: root.usageData && root.usageData.opencode
                            ? "No OpenCode data. Run `opencode-quota init` to set up."
                            : "Loading OpenCode quotas..."
                        wrapMode: Text.WordWrap
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    // --- DeepSeek Section ---
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
                                    width: 32
                                    height: 32
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
                                    width: parent.width - 44
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2

                                    StyledText {
                                        text: "DeepSeek"
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                    }

                                    StyledText {
                                        text: "Total: " + root.formatBalance(modelData)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }

                                    StyledText {
                                        visible: parseFloat(modelData.granted) > 0
                                        text: "Granted: " + modelData.currency + " " + parseFloat(modelData.granted).toFixed(2)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }

                                    StyledText {
                                        visible: parseFloat(modelData.toppedUp) > 0
                                        text: "Top-up: " + modelData.currency + " " + parseFloat(modelData.toppedUp).toFixed(2)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }
                        }
                    }

                    // DeepSeek unavailable message.
                    StyledText {
                        width: parent.width
                        visible: root.deepSeekEnabled && !root.deepSeekBalance()
                        text: root.deepSeekApiKey
                            ? "Could not load DeepSeek balance."
                            : "DeepSeek API key not set. Add it in plugin settings."
                        wrapMode: Text.WordWrap
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    // --- Footer ---
                    StyledText {
                        width: parent.width
                        visible: root.usageData && (root.openCodeProviders().length > 0 || root.deepSeekBalance())
                        text: {
                            var ts = root.usageData ? root.usageData.captured_at || 0 : 0
                            if (ts <= 0) return ""
                            return "Updated " + Math.round(Date.now() / 1000 - ts) + "s ago"
                        }
                        color: Theme.surfaceTextMedium
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    StyledText {
                        width: parent.width
                        visible: !root.usageData || (!root.fetchFailed && root.openCodeProviders().length === 0 && !root.deepSeekBalance())
                        text: root.fetchFailed
                            ? "Could not fetch usage data."
                            : "Loading usage..."
                        wrapMode: Text.WordWrap
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
            }
        }
    }
}
