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
    property bool fetchQueued: false
    property var pinState: ({})
    property string selectedProvider: "codex"

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
                    root.fetchFailed = false
                } catch (e) {}
            }
        }
        stderr: SplitParser { onRead: line => {} }
        onExited: code => {
            if (code !== 0 && !root.usageData) root.fetchFailed = true
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

    Component.onCompleted: {
        root.loadPinState()
        root.ensureSelectedProvider()
        try {
            var c = pluginService.loadPluginState("aiQuotas", "lastData", null)
            if (c) root.usageData = c
        } catch (e) {}
        // PluginComponent loads pluginData after child completion; defer the first request.
        Qt.callLater(root.requestFetch)
    }

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === "aiQuotas") {
                Qt.callLater(function () {
                    root.loadPinState()
                    root.ensureSelectedProvider()
                    root.requestFetch()
                })
            }
        }
    }

    function defaultPinState() {
        var openCodePin = savedSetting("pinnedWindow", "Rolling") || "Rolling"
        return { codex: ["5h"], opencode: [openCodePin], deepseek: ["balance"] }
    }

    function savedSetting(key, fallback) {
        try {
            if (pluginService && pluginService.loadPluginData) {
                var value = pluginService.loadPluginData("aiQuotas", key, fallback)
                return value === undefined || value === null ? fallback : value
            }
        } catch (e) {}
        return pluginData && pluginData[key] !== undefined && pluginData[key] !== null
            ? pluginData[key] : fallback
    }

    function loadPinState() {
        var raw = savedSetting("pinnedLimits", null)
        if (typeof raw === "string") {
            try { raw = JSON.parse(raw) } catch (e) { raw = null }
        }
        var defaults = defaultPinState()
        var next = {}
        var providers = ["codex", "opencode", "deepseek"]
        for (var i = 0; i < providers.length; i++) {
            var provider = providers[i]
            next[provider] = raw && Array.isArray(raw[provider]) ? raw[provider] : defaults[provider]
        }
        pinState = next
    }

    function savePinState() {
        if (pluginService && pluginService.savePluginData)
            pluginService.savePluginData("aiQuotas", "pinnedLimits", JSON.stringify(pinState))
    }

    function isPinned(provider, name) {
        var pins = pinState[provider] || []
        return pins.indexOf(name) >= 0
    }

    function togglePin(provider, name) {
        var next = {}
        var providers = ["codex", "opencode", "deepseek"]
        for (var i = 0; i < providers.length; i++)
            next[providers[i]] = (pinState[providers[i]] || []).slice()
        var pins = next[provider] || []
        var index = pins.indexOf(name)
        if (index >= 0) pins.splice(index, 1)
        else pins.push(name)
        next[provider] = pins
        pinState = next
        savePinState()
    }

    function pinnedEntries(provider, entries) {
        var out = []
        var pins = pinState[provider] || []
        for (var i = 0; i < entries.length; i++) {
            if (pins.indexOf(entries[i].name) >= 0) out.push(entries[i])
        }
        return out
    }

    function pinnedCodexEntries() { return pinnedEntries("codex", codexEntries()) }
    function pinnedOpenCodeEntries() { return pinnedEntries("opencode", ocEntries()) }
    function deepSeekPinned() { return isPinned("deepseek", "balance") }

    function providerEnabled(provider) {
        if (provider === "codex") return codexEnabled
        if (provider === "opencode") return openCodeEnabled
        if (provider === "deepseek") return deepSeekEnabled
        return false
    }

    function providerTabs() {
        var out = []
        if (codexEnabled) out.push({ id: "codex", label: "Codex", icon: "assets/codex-logo.svg" })
        if (openCodeEnabled) out.push({ id: "opencode", label: "OpenCode", icon: "assets/opencode-logo.svg" })
        if (deepSeekEnabled) out.push({ id: "deepseek", label: "DeepSeek", icon: "assets/deepseek-logo.svg" })
        return out
    }

    function ensureSelectedProvider() {
        if (providerEnabled(selectedProvider)) return
        var providers = ["codex", "opencode", "deepseek"]
        for (var i = 0; i < providers.length; i++) {
            if (providerEnabled(providers[i])) {
                selectedProvider = providers[i]
                return
            }
        }
    }

    function codexEntries() {
        try {
            if (!usageData || !usageData.codex) return []
            if (usageData.codex.status !== "ok") return []
            return usageData.codex.entries || []
        } catch (e) { return [] }
    }

    function hasDeepSeek() {
        return deepSeekEnabled && deepSeekPinned() && dsBalance() != null
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
            var balances = dsBalances()
            return balances.length > 0 ? balances[0] : null
        } catch (e) { return null }
    }

    function dsBalances() {
        try {
            if (!usageData || !usageData.deepseek) return []
            if (usageData.deepseek.status !== "ok") return []
            return usageData.deepseek.balances || []
        } catch (e) { return [] }
    }

    function dsAvailabilityLabel() {
        try {
            if (!usageData || !usageData.deepseek) return "Waiting for balance data"
            if (usageData.deepseek.isAvailable === true) return "Available for API calls"
            if (usageData.deepseek.isAvailable === false) return "Insufficient balance for API calls"
            return "Availability unknown"
        } catch (e) { return "Availability unknown" }
    }

    function dsAvailabilityColor() {
        try {
            return usageData && usageData.deepseek && usageData.deepseek.isAvailable === false
                ? Theme.error : Theme.primary
        } catch (e) { return Theme.surfaceVariantText }
    }

    function findEntry(name) {
        var entries = ocEntries()
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].name === name) return entries[i]
        }
        return null
    }

    function visibleWindows() {
        return ocEntries()
    }

    function ocLabel(entry) {
        try {
            return entry.name === "Rolling" ? "Rolling (5h)" : entry.name
        } catch (e) { return "OpenCode" }
    }

    function codexLabel(entry) {
        try {
            if (entry.name === "5h") return "5 hour usage limit"
            if (entry.name === "Weekly") return "Weekly usage limit"
            if (entry.name === "Code Review") return "Code review usage limit"
            return entry.name + " usage limit"
        } catch (e) { return "Codex usage limit" }
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

    function resetLabel(t) {
        try {
            if (!t) return "Reset time unavailable"
            if (t <= Date.now() / 1000) return "Resets now"
            var d = new Date(t * 1000)
            var h = d.getHours()
            var suffix = h >= 12 ? "PM" : "AM"
            h = h % 12 || 12
            var minutes = ("0" + d.getMinutes()).slice(-2)
            var time = h + ":" + minutes + " " + suffix
            var today = new Date()
            if (d.toDateString() === today.toDateString()) return "Resets " + time
            var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            return "Resets " + months[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear() + " " + time
        } catch (e) { return "Resets in " + cdown(t) }
    }

    function fmtBal(b) {
        try {
            if (!b) return "--"
            return fmtMoney(b.total, b.currency)
        } catch (e) { return "--" }
    }

    function fmtMoney(value, currency) {
        try {
            var amount = parseFloat(value)
            if (!isFinite(amount)) return "--"
            var suffix = currency === "USD" ? "$" : (currency === "CNY" ? "¥" : (currency || ""))
            return amount.toFixed(2) + suffix
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

    function limitProgress(pct) {
        try {
            return Math.max(0, Math.min(100, pctVal(pct)))
        } catch (e) { return 0 }
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
                    model: root.pinnedCodexEntries()
                    delegate: Row {
                        spacing: 4
                        Image {
                            source: root.pluginDir + "assets/codex-logo.svg"
                            sourceSize.width: 16
                            sourceSize.height: 16
                            width: 16; height: 16
                            fillMode: Image.PreserveAspectFit
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: Math.round(root.pctVal(modelData.percentUsed || 0)) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // Separator before OpenCode or DeepSeek
                Rectangle {
                    visible: root.pinnedCodexEntries().length > 0 && (root.pinnedOpenCodeEntries().length > 0 || root.hasDeepSeek())
                    width: 1
                    height: pill.height - 8
                    color: Theme.outlineVariant
                    opacity: 0.4
                    anchors.verticalCenter: parent.verticalCenter
                }

                // OpenCode pinned ring only
                Repeater {
                    model: root.pinnedOpenCodeEntries()
                    delegate: Row {
                        spacing: 4
                        Image {
                            source: root.pluginDir + "assets/opencode-logo.svg"
                            sourceSize.width: 16
                            sourceSize.height: 16
                            width: 16; height: 16
                            fillMode: Image.PreserveAspectFit
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: Math.round(root.pctVal(modelData.percentUsed || 0)) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // Separator between OpenCode and DeepSeek
                Rectangle {
                    visible: root.pinnedOpenCodeEntries().length > 0 && root.hasDeepSeek()
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
                            source: root.pluginDir + "assets/deepseek-logo.svg"
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
                    model: root.pinnedCodexEntries()
                    delegate: Column {
                        spacing: 1
                        Image {
                            source: root.pluginDir + "assets/codex-logo.svg"
                            sourceSize.width: 16
                            sourceSize.height: 16
                            width: 16; height: 16
                            fillMode: Image.PreserveAspectFit
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: Math.round(root.pctVal(modelData.percentUsed || 0)) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                Repeater {
                    model: root.pinnedOpenCodeEntries()
                    delegate: Column {
                        spacing: 1
                        Image {
                            source: root.pluginDir + "assets/opencode-logo.svg"
                            sourceSize.width: 16
                            sourceSize.height: 16
                            width: 16; height: 16
                            fillMode: Image.PreserveAspectFit
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: Math.round(root.pctVal(modelData.percentUsed || 0)) + "%"
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
                            source: root.pluginDir + "assets/deepseek-logo.svg"
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

                    Row {
                        id: providerTabsRow
                        width: parent.width
                        height: 36
                        spacing: Theme.spacingXS

                        Repeater {
                            model: root.providerTabs()
                            delegate: Rectangle {
                                width: (providerTabsRow.width - Theme.spacingXS * (root.providerTabs().length - 1)) / root.providerTabs().length
                                height: providerTabsRow.height
                                radius: Theme.cornerRadius
                                color: root.selectedProvider === modelData.id
                                    ? Theme.surfaceSelected
                                    : (tabMouse.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHigh)
                                border.color: root.selectedProvider === modelData.id
                                    ? Theme.outlineMedium : Theme.outlineVariant
                                border.width: 1

                                Image {
                                    id: tabIcon
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    source: root.pluginDir + modelData.icon
                                    sourceSize.width: 17
                                    sourceSize.height: 17
                                    width: 17; height: 17
                                    fillMode: Image.PreserveAspectFit
                                }

                                StyledText {
                                    anchors.left: tabIcon.right
                                    anchors.leftMargin: Theme.spacingXS
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingXS
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.label
                                    color: root.selectedProvider === modelData.id
                                        ? Theme.surfaceText : Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                }

                                MouseArea {
                                    id: tabMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.selectedProvider = modelData.id
                                }
                            }
                        }
                    }

                    // --- Codex card ---
                    StyledRect {
                        visible: root.selectedProvider === "codex" && root.codexEnabled
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
                                delegate: Column {
                                    width: parent.width
                                    spacing: Theme.spacingS
                                    Row {
                                        width: parent.width
                                        spacing: Theme.spacingM
                                        Image {
                                            source: root.pluginDir + "assets/codex-logo.svg"
                                            sourceSize.width: 28
                                            sourceSize.height: 28
                                            width: 28; height: 28
                                            fillMode: Image.PreserveAspectFit
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Column {
                                            width: parent.width - 40 - 28 - Theme.spacingM
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 2
                                            StyledText {
                                                text: root.codexLabel(modelData)
                                                color: Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                            }
                                            StyledText {
                                                text: root.pctStr(modelData.percentUsed || 0)
                                                color: Theme.surfaceText
                                                font.pixelSize: Theme.fontSizeLarge
                                                font.weight: Font.Bold
                                            }
                                        }
                                        Rectangle {
                                            width: 28; height: 28; radius: 14
                                            color: root.isPinned("codex", modelData.name)
                                                ? Theme.surfaceSelected
                                                : (codexPinArea.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHighest)
                                            border.color: root.isPinned("codex", modelData.name)
                                                ? Theme.outlineMedium : Theme.outlineVariant
                                            border.width: 1
                                            anchors.verticalCenter: parent.verticalCenter

                                            MouseArea {
                                                id: codexPinArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.togglePin("codex", modelData.name)
                                            }

                                            DankIcon {
                                                anchors.centerIn: parent
                                                name: "push_pin"
                                                size: 17
                                                color: root.isPinned("codex", modelData.name)
                                                    ? Theme.primary : Theme.surfaceVariantText
                                                rotation: root.isPinned("codex", modelData.name) ? 0 : 45
                                            }
                                        }
                                    }
                                    Rectangle {
                                        id: codexProgressTrack
                                        width: parent.width
                                        height: 8
                                        radius: 4
                                        color: Theme.outlineVariant
                                        Rectangle {
                                            width: codexProgressTrack.width * root.limitProgress(modelData.percentUsed || 0) / 100
                                            height: parent.height
                                            radius: parent.radius
                                            color: Theme.primary
                                        }
                                    }
                                    StyledText {
                                        visible: root.showResetTime && modelData.resetAt > 0
                                        text: root.resetLabel(modelData.resetAt)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }

                            StyledText {
                                visible: root.codexEntries().length === 0
                                width: parent.width
                                wrapMode: Text.WordWrap
                                color: {
                                    var c = root.usageData && root.usageData.codex
                                    return c && (c.reason === "not_authenticated" || c.reason === "auth_expired")
                                        ? Theme.warning : Theme.surfaceVariantText
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                text: {
                                    if (!root.usageData) return "Loading..."
                                    var c = root.usageData.codex
                                    if (c && c.reason === "not_authenticated")
                                        return "Codex is not connected.\nRun codex login in a terminal, then wait for the next refresh."
                                    if (c && c.reason === "auth_expired")
                                        return "Codex login expired.\nRun codex login again, then wait for the next refresh."
                                    if (c && c.error) return c.error
                                    return "No Codex usage data."
                                }
                            }
                        }
                    }

                    // --- OpenCode card ---
                    StyledRect {
                        visible: root.selectedProvider === "opencode" && root.openCodeEnabled
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
                                delegate: Column {
                                    width: parent.width
                                    spacing: Theme.spacingS
                                    Row {
                                        width: parent.width
                                        spacing: Theme.spacingM
                                        Image {
                                            source: root.pluginDir + "assets/opencode-logo.svg"
                                            sourceSize.width: 28
                                            sourceSize.height: 28
                                            width: 28; height: 28
                                            fillMode: Image.PreserveAspectFit
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Column {
                                            width: parent.width - 40 - 28 - Theme.spacingM
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 2
                                            StyledText {
                                                text: root.ocLabel(modelData)
                                                color: Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                            }
                                            StyledText {
                                                text: root.pctStr(modelData.percentUsed || 0)
                                                color: Theme.surfaceText
                                                font.pixelSize: Theme.fontSizeLarge
                                                font.weight: Font.Bold
                                            }
                                        }
                                        Rectangle {
                                            width: 28; height: 28; radius: 14
                                            color: root.isPinned("opencode", modelData.name)
                                                ? Theme.surfaceSelected
                                                : (openCodePinArea.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHighest)
                                            border.color: root.isPinned("opencode", modelData.name)
                                                ? Theme.outlineMedium : Theme.outlineVariant
                                            border.width: 1
                                            anchors.verticalCenter: parent.verticalCenter

                                            MouseArea {
                                                id: openCodePinArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.togglePin("opencode", modelData.name)
                                            }

                                            DankIcon {
                                                anchors.centerIn: parent
                                                name: "push_pin"
                                                size: 17
                                                color: root.isPinned("opencode", modelData.name)
                                                    ? Theme.primary : Theme.surfaceVariantText
                                                rotation: root.isPinned("opencode", modelData.name) ? 0 : 45
                                            }
                                        }
                                    }
                                    Rectangle {
                                        id: openCodeProgressTrack
                                        width: parent.width
                                        height: 8
                                        radius: 4
                                        color: Theme.outlineVariant
                                        Rectangle {
                                            width: openCodeProgressTrack.width * root.limitProgress(modelData.percentUsed || 0) / 100
                                            height: parent.height
                                            radius: parent.radius
                                            color: Theme.primary
                                        }
                                    }
                                    StyledText {
                                        visible: root.showResetTime && modelData.resetAt > 0
                                        text: root.resetLabel(modelData.resetAt)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
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
                        visible: root.selectedProvider === "deepseek" && root.deepSeekEnabled
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
                                text: "DeepSeek API balance"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                            }

                            StyledText {
                                visible: root.dsBalance() != null
                                    && (!root.usageData.deepseek || root.usageData.deepseek.isAvailable !== true)
                                text: root.dsAvailabilityLabel()
                                color: root.dsAvailabilityColor()
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            // DeepSeek balance
                            Repeater {
                                model: root.dsBalances()
                                delegate: Row {
                                    width: parent.width
                                    spacing: Theme.spacingM
                                    Image {
                                            source: root.pluginDir + "assets/deepseek-logo.svg"
                                        sourceSize.width: 28
                                        sourceSize.height: 28
                                        width: 28; height: 28
                                        fillMode: Image.PreserveAspectFit
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Column {
                                        width: parent.width - 40 - 28 - Theme.spacingM
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2
                                        StyledText { text: "Available balance"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
                                        StyledText { text: root.fmtBal(modelData); color: Theme.surfaceText; font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Bold }
                                        StyledText {
                                            visible: parseFloat(modelData.granted) > 0
                                            text: "Granted (unexpired): " + root.fmtMoney(modelData.granted, modelData.currency)
                                            color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall
                                        }
                                        StyledText {
                                            visible: parseFloat(modelData.toppedUp) > 0
                                            text: "Top-up (paid): " + root.fmtMoney(modelData.toppedUp, modelData.currency)
                                            color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall
                                        }
                                    }
                                    Rectangle {
                                        width: 28; height: 28; radius: 14
                                        color: root.isPinned("deepseek", "balance")
                                            ? Theme.surfaceSelected
                                            : (deepSeekPinArea.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHighest)
                                        border.color: root.isPinned("deepseek", "balance")
                                            ? Theme.outlineMedium : Theme.outlineVariant
                                        border.width: 1
                                        anchors.verticalCenter: parent.verticalCenter

                                        MouseArea {
                                            id: deepSeekPinArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.togglePin("deepseek", "balance")
                                        }

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: "push_pin"
                                            size: 17
                                            color: root.isPinned("deepseek", "balance")
                                                ? Theme.primary : Theme.surfaceVariantText
                                            rotation: root.isPinned("deepseek", "balance") ? 0 : 45
                                        }
                                    }
                                }
                            }

                            // DeepSeek unavailable
                            StyledText {
                                visible: !root.dsBalance()
                                width: parent.width
                                wrapMode: Text.WordWrap
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                text: {
                                    if (!root.usageData) return "Loading..."
                                    var d = root.usageData.deepseek
                                    if (d && d.error) return d.error
                                    if (root.deepSeekApiKey.length === 0) return "Set DeepSeek API key in plugin settings."
                                    return "No DeepSeek balance data."
                                }
                            }
                        }
                    }
        }
    }
}
}
