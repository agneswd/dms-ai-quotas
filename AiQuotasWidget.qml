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
    property bool codexEnabled: pluginData.codexEnabled !== false
    property bool openCodeEnabled: pluginData.openCodeEnabled !== false
    property bool deepSeekEnabled: pluginData.deepSeekEnabled !== false
    property bool showRolling: pluginData.showRolling !== false
    property bool showWeekly: pluginData.showWeekly !== false
    property bool showMonthly: pluginData.showMonthly !== false
    property string pinnedWindow: pluginData.pinnedWindow || "Rolling"
    property string deepSeekApiKey: pluginData.deepSeekApiKey || ""
    property string openCodeWorkspaceId: pluginData.openCodeWorkspaceId || ""
    property string openCodeAuthCookie: pluginData.openCodeAuthCookie || ""
    property string displayMode: pluginData.displayMode || "remaining"
    property bool showResetTime: pluginData.showResetTime !== false
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
        triggeredOnStart: false
        onTriggered: { try { fetchProcess.running = true } catch (e) {} }
    }

    Process {
        id: fetchProcess
        command: ["sh", "-c",
            "AIQ_CODEX_ENABLED='" + (root.codexEnabled ? "1" : "0") + "' " +
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
        // Fetch immediately on startup.
        try { fetchProcess.running = true } catch (e) {}
    }

    function codexEntries() {
        try {
            if (!usageData || !usageData.codex) return []
            if (usageData.codex.status !== "ok") return []
            return usageData.codex.entries || []
        } catch (e) { return [] }
    }

    function codexEntry(name) {
        var entries = codexEntries()
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].name === name) return entries[i]
        }
        return null
    }

    function codexPrimary() {
        return codexEntry("5h")
    }

    function codexPct() {
        try {
            var e = codexPrimary()
            if (!e || e.percentUsed === undefined || e.percentUsed === null) return -1
            return e.percentUsed
        } catch (e) { return -1 }
    }

    function hasCodex() {
        return codexEnabled && codexPct() >= 0
    }

    function hasOpenCode() {
        return openCodeEnabled && pinnedPct() >= 0
    }

    function hasDeepSeek() {
        return deepSeekEnabled && dsBalance() != null
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

    function findEntry(name) {
        var entries = ocEntries()
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].name === name) return entries[i]
        }
        return null
    }

    function pinnedEntry() {
        return findEntry(pinnedWindow)
    }

    function visibleWindows() {
        var out = []
        if (showRolling) { var e = findEntry("Rolling"); if (e) out.push(e) }
        if (showWeekly) { var e = findEntry("Weekly"); if (e) out.push(e) }
        if (showMonthly) { var e = findEntry("Monthly"); if (e) out.push(e) }
        return out
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
            var days = Math.floor(d / 86400)
            var h = Math.floor((d % 86400) / 3600)
            var m = Math.floor((d % 3600) / 60)
            if (days > 0) return days + "d " + h + "h"
            return h > 0 ? h + "h " + m + "m" : m + "m"
        } catch (e) { return "--" }
    }

    function fmtBal(b) {
        try {
            if (!b) return "--"
            return b.currency + " " + (parseFloat(b.total) || 0).toFixed(2)
        } catch (e) { return "--" }
    }

    function pctStr(pct) {
        try {
            if (pct < 0) return "--"
            return displayMode === "used" ? pct + "% used" : (100 - pct) + "% remaining"
        } catch (e) { return "--" }
    }

    function pctVal(pct) {
        try {
            if (pct < 0) return -1
            return displayMode === "used" ? pct : 100 - pct
        } catch (e) { return -1 }
    }

    function pinnedPct() {
        try {
            var e = pinnedEntry()
            if (!e) return -1
            return e.percentUsed || 0
        } catch (e) { return -1 }
    }

    // --- Bar Pills ---

    horizontalBarPill: Component {
        StyledRect {
            id: pill
            implicitWidth: hRow.implicitWidth + Theme.spacingXS * 2
            height: parent.widgetThickness
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Row {
                id: hRow
                anchors.centerIn: parent
                spacing: Theme.spacingS

                // Placeholder when nothing configured
                StyledText {
                    visible: !root.usageData
                    text: "\u2733 -"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                // Codex 5-hour limit
                Repeater {
                    model: root.hasCodex() ? [1] : []
                    delegate: Row {
                        spacing: 4
                        UsageRing {
                            percentage: root.codexPct()
                            ringColor: root.clr(root.codexPct())
                            diameter: Math.max(16, Math.min(pill.height - 6, 24))
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: "C " + Math.round(root.pctVal(root.codexPct())) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // Separator before OpenCode or DeepSeek
                Rectangle {
                    visible: root.hasCodex() && (root.hasOpenCode() || root.hasDeepSeek())
                    width: 1
                    height: pill.height - 8
                    color: Theme.outlineVariant
                    opacity: 0.4
                    anchors.verticalCenter: parent.verticalCenter
                }

                // OpenCode pinned ring only
                Repeater {
                    model: root.hasOpenCode() ? [1] : []
                    delegate: Row {
                        spacing: 4
                        UsageRing {
                            percentage: root.pinnedPct()
                            ringColor: root.clr(root.pinnedPct())
                            diameter: Math.max(16, Math.min(pill.height - 6, 24))
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: Math.round(root.pctVal(root.pinnedPct())) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // Separator between OpenCode and DeepSeek
                Rectangle {
                    visible: root.hasOpenCode() && root.hasDeepSeek()
                    width: 1
                    height: pill.height - 8
                    color: Theme.outlineVariant
                    opacity: 0.4
                    anchors.verticalCenter: parent.verticalCenter
                }

                // DeepSeek balance
                Repeater {
                    model: root.hasDeepSeek() ? [1] : []
                    delegate: Row {
                        spacing: 4
                        Image {
                            source: root.pluginDir + "deepseek-logo.svg"
                            sourceSize.width: 14
                            sourceSize.height: 14
                            width: 14; height: 14
                            fillMode: Image.PreserveAspectFit
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
            implicitHeight: vCol.implicitHeight + Theme.spacingXS * 2
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
                    model: root.hasCodex() ? [1] : []
                    delegate: Column {
                        spacing: 1
                        UsageRing {
                            percentage: root.codexPct()
                            ringColor: root.clr(root.codexPct())
                            diameter: Math.max(16, Math.min(pillV.width - 4, 24))
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: "C " + Math.round(root.pctVal(root.codexPct())) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                Repeater {
                    model: root.hasOpenCode() ? [1] : []
                    delegate: Column {
                        spacing: 1
                        UsageRing {
                            percentage: root.pinnedPct()
                            ringColor: root.clr(root.pinnedPct())
                            diameter: Math.max(16, Math.min(pillV.width - 4, 24))
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: Math.round(root.pctVal(root.pinnedPct())) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                Repeater {
                    model: root.hasDeepSeek() ? [1] : []
                    delegate: Column {
                        spacing: 1
                        Image {
                            source: root.pluginDir + "deepseek-logo.svg"
                            sourceSize.width: 12
                            sourceSize.height: 12
                            width: 12; height: 12
                            fillMode: Image.PreserveAspectFit
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
    popoutHeight: 620
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "AI Quotas"
            showCloseButton: true
            closePopout: function () { popout.visible = false }

            Column {
                    width: parent.width - Theme.spacingM * 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.spacingM

                    // --- Codex card ---
                    StyledRect {
                        visible: root.codexEnabled
                        width: parent.width
                        height: codexCard.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            id: codexCard
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            StyledText {
                                visible: root.codexEntries().length > 0
                                text: root.usageData && root.usageData.codex && root.usageData.codex.plan
                                    ? "Codex (" + root.usageData.codex.plan + ")" : "Codex"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                            }

                            Repeater {
                                model: root.codexEntries()
                                delegate: Row {
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
                                            text: modelData.name + ": " + root.pctStr(modelData.percentUsed || 0)
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                        }
                                        StyledText {
                                            visible: root.showResetTime && modelData.resetAt > 0
                                            text: "Resets in " + root.cdown(modelData.resetAt)
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall
                                        }
                                    }
                                }
                            }

                            StyledText {
                                visible: root.codexEntries().length === 0
                                width: parent.width
                                wrapMode: Text.WordWrap
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                text: {
                                    if (!root.usageData) return "Loading..."
                                    var c = root.usageData.codex
                                    if (c && c.error) return c.error
                                    return "No Codex usage data."
                                }
                            }
                        }
                    }

                    // --- OpenCode card ---
                    StyledRect {
                        visible: root.openCodeEnabled
                        width: parent.width
                        height: ocCard.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            id: ocCard
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            StyledText {
                                visible: root.ocEntries().length > 0
                                text: "OpenCode Go"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                            }

                            // OpenCode windows
                            Repeater {
                                model: root.ocEntries().length > 0 ? root.visibleWindows() : []
                                delegate: Row {
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
                                            text: root.pctStr(modelData.percentUsed || 0)
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                        }
                                        StyledText {
                                            visible: root.showResetTime && modelData.resetAt > 0
                                            text: "Resets in " + root.cdown(modelData.resetAt)
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall
                                        }
                                    }
                                }
                            }

                            // OpenCode unavailable
                            StyledText {
                                visible: root.ocEntries().length === 0
                                width: parent.width
                                wrapMode: Text.WordWrap
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                text: {
                                    if (!root.usageData) return "Loading..."
                                    var o = root.usageData.opencode
                                    if (o && o.error) return o.error
                                    if (o && o.status === "unavailable") return "Set OpenCode credentials in plugin settings."
                                    return "No OpenCode data."
                                }
                            }
                        }
                    }

                    // --- DeepSeek card ---
                    StyledRect {
                        visible: root.deepSeekEnabled
                        width: parent.width
                        height: dsCard.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            id: dsCard
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            StyledText {
                                visible: root.dsBalance() != null
                                text: "DeepSeek API"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                            }

                            // DeepSeek balance
                            Repeater {
                                model: root.dsBalance() ? [root.dsBalance()] : []
                                delegate: Row {
                                    width: parent.width
                                    spacing: Theme.spacingM
                                    Rectangle {
                                        width: 28; height: 28; radius: 14
                                        color: Theme.surfaceContainerHighest
                                        anchors.verticalCenter: parent.verticalCenter
                                        Image {
                                            anchors.centerIn: parent
                                            source: root.pluginDir + "deepseek-logo.svg"
                                            sourceSize.width: 20
                                            sourceSize.height: 20
                                            fillMode: Image.PreserveAspectFit
                                        }
                                    }
                                    Column {
                                        width: parent.width - 40
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        StyledText { text: "Balance: " + root.fmtBal(modelData); color: Theme.surfaceText; font.pixelSize: Theme.fontSizeMedium }
                                        StyledText {
                                            visible: parseFloat(modelData.granted) > 0
                                            text: "Granted: " + modelData.currency + " " + parseFloat(modelData.granted).toFixed(2)
                                            color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall
                                        }
                                        StyledText {
                                            visible: parseFloat(modelData.toppedUp) > 0
                                            text: "Top-up: " + modelData.currency + " " + parseFloat(modelData.toppedUp).toFixed(2)
                                            color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall
                                        }
                                    }
                                }
                            }

                            // DeepSeek unavailable
                            StyledText {
                                visible: !root.dsBalance() && root.deepSeekApiKey.length === 0
                                width: parent.width
                                wrapMode: Text.WordWrap
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                text: "Set DeepSeek API key in plugin settings."
                            }
                        }
                    }
        }
    }
}
}
