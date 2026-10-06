import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "aiQuotas"

    property string displayMode: pluginData.displayMode || "remaining"
    property bool showResetTime: pluginData.showResetTime !== false
    property bool showResetCountdown: pluginData.showResetCountdown === true
    property string pluginDir: {
        var url = Qt.resolvedUrl(".")
        var path = url.toString()
        if (path.indexOf("file://") === 0) path = path.substring(7)
        return path
    }

    property var usageData: null
    property var pinState: ({})
    property string selectedProvider: "claude"

    // Providers in display order. The ids match the keys in fetch-usage.sh output
    // and the assets/<id>-logo.svg file names. "limits" providers report usage
    // windows in data.entries. "balance" providers report money in data.balances.
    // When any window in blockingWindows is used up, the provider is blocked, so
    // the pill shows it as used up.
    readonly property var providers: [
        { id: "claude", label: "Claude", title: "Claude", enabledKey: "claudeEnabled", kind: "limits", defaultPins: ["5h"], blockingWindows: ["5h", "Weekly"] },
        { id: "codex", label: "Codex", title: "Codex", enabledKey: "codexEnabled", kind: "limits", defaultPins: ["5h"], blockingWindows: ["5h", "Weekly"] },
        { id: "opencode", label: "OpenCode", title: "OpenCode Go", enabledKey: "openCodeEnabled", kind: "limits", defaultPins: ["Rolling"], blockingWindows: ["Rolling", "Weekly", "Monthly"] },
        { id: "deepseek", label: "DeepSeek", title: "DeepSeek API balance", enabledKey: "deepSeekEnabled", kind: "balance", defaultPins: ["balance"], blockingWindows: [] },
        { id: "openrouter", label: "OpenRouter", title: "OpenRouter credit balance", enabledKey: "openRouterEnabled", kind: "balance", defaultPins: ["balance"], blockingWindows: [] },
        { id: "grok", label: "Grok", title: "Grok", enabledKey: "grokEnabled", kind: "limits", defaultPins: ["Billing"], blockingWindows: [] },
        { id: "antigravity", label: "Antigravity", title: "Antigravity", enabledKey: "antigravityEnabled", kind: "limits", defaultPins: ["Gemini Models - Five Hour Limit Remaining"], blockingWindows: [] }
    ]

    function loadUsageData() {
        try {
            var c = pluginService.loadPluginState("aiQuotas", "lastData", null)
            if (c) root.usageData = c
        } catch (e) {}
    }

    Component.onCompleted: {
        root.loadPinState()
        root.ensureSelectedProvider()
        root.loadUsageData()
    }

    // PluginComponent injects pluginData after child completion during startup.
    Connections {
        target: root
        function onPluginDataChanged() {
            if (root.pluginData && Object.keys(root.pluginData).length > 0) {
                Qt.callLater(function () {
                    root.loadPinState()
                    root.ensureSelectedProvider()
                })
            }
        }
    }

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === "aiQuotas") {
                Qt.callLater(function () {
                    root.loadPinState()
                    root.ensureSelectedProvider()
                })
            }
        }
    }

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null
        function onPluginStateChanged(changedPluginId) {
            if (changedPluginId === "aiQuotas")
                root.loadUsageData()
        }
    }

    // --- Providers ---

    function provider(id) {
        for (var i = 0; i < providers.length; i++) {
            if (providers[i].id === id) return providers[i]
        }
        return null
    }

    function providerEnabled(id) {
        var p = provider(id)
        return p !== null && pluginData[p.enabledKey] !== false
    }

    function enabledProviders() {
        return providers.filter(function (p) { return pluginData[p.enabledKey] !== false })
    }

    function ensureSelectedProvider() {
        if (providerEnabled(selectedProvider)) return
        var enabled = enabledProviders()
        if (enabled.length > 0) selectedProvider = enabled[0].id
    }

    function providerData(id) {
        return usageData && usageData[id] ? usageData[id] : null
    }

    function capitalize(text) {
        text = String(text)
        return text.charAt(0).toUpperCase() + text.slice(1)
    }

    function providerTitle(id) {
        var p = provider(id)
        var data = providerData(id)
        if (p.kind === "limits" && data && data.plan && id !== "antigravity")
            return p.title + " (" + capitalize(data.plan) + ")"
        return p.title
    }

    // An extra status line under the provider title, or null.
    function providerNotice(id) {
        var data = providerData(id)
        if (!data) return null
        if (id === "claude" && data.stale === true) {
            return {
                text: data.capturedAt > 0
                    ? "Updated " + clockTime(new Date(data.capturedAt * 1000)) + " - may be stale"
                    : "Claude usage data is stale",
                color: Theme.warning
            }
        }
        if (id === "deepseek" && data.isAvailable !== true) {
            return data.isAvailable === false
                ? { text: "Insufficient balance for API calls", color: Theme.error }
                : { text: "Availability unknown", color: Theme.primary }
        }
        return null
    }

    // The message shown when a provider has no rows.
    function providerMessage(id) {
        if (!usageData) return "Loading..."
        var data = providerData(id)
        if (data && data.error) return data.error
        return "No " + provider(id).label + " usage data."
    }

    function providerMessageColor(id) {
        var data = providerData(id)
        return data && (data.reason === "not_authenticated" || data.reason === "auth_expired")
            ? Theme.warning : Theme.surfaceVariantText
    }

    // --- Rows: one usage window or balance, shared by the pill and the popout ---

    function limitLabel(id, entry) {
        var name = entry.name
        if (id === "antigravity") {
            var parts = name.split(" - ")
            return parts.length > 1 ? parts[1] : name
        }
        if (id === "grok") {
            if (entry.kind === "on_demand") return "On-demand spending cap"
            if (entry.kind === "plan") return "Weekly usage limit"
            return name
        }
        if (id === "opencode" && name === "Rolling") return "Rolling (5h)"
        if (id === "opencode") return name
        if (name === "5h") return "5 hour usage limit"
        if (name === "Weekly") return id === "claude" ? "Weekly usage limit (all models)" : "Weekly usage limit"
        if (name === "Code Review") return "Code review usage limit"
        return name + " usage limit"
    }

    function balanceDetails(id, balance) {
        var details = []
        function add(label, value) {
            if (parseFloat(value) > 0) details.push(label + fmtMoney(value, balance.currency))
        }
        if (id === "deepseek") {
            add("Granted (unexpired): ", balance.granted)
            add("Top-up (paid): ", balance.toppedUp)
        } else {
            add("Purchased: ", balance.purchased)
            add("Used: ", balance.used)
        }
        return details
    }

    function providerRows(id) {
        var data = providerData(id)
        if (!data || data.status !== "ok") return []
        if (provider(id).kind === "balance") {
            return (data.balances || []).map(function (balance) {
                return {
                    provider: id,
                    pinKey: "balance",
                    isBalance: true,
                    label: "Available balance",
                    value: fmtMoney(balance.total, balance.currency),
                    shortValue: balance.total !== undefined ? (parseFloat(balance.total) || 0).toFixed(0) : "--",
                    details: balanceDetails(id, balance),
                    percentUsed: 0,
                    resetAt: 0
                }
            })
        }
        return (data.entries || []).map(function (entry) {
            var used = entry.percentUsed || 0
            return {
                provider: id,
                pinKey: entry.name,
                group: id === "antigravity" && entry.name.indexOf(" - ") >= 0
                    ? entry.name.split(" - ")[0] : "",
                isBalance: false,
                label: limitLabel(id, entry),
                value: pctStr(used),
                shortValue: Math.round(pctVal(used)) + "%",
                details: [],
                percentUsed: used,
                resetAt: entry.resetAt || 0
            }
        })
    }

    // Popout cards. Antigravity gets one card per model group.
    function providerSections(id) {
        var rows = providerRows(id)
        if (rows.length === 0) return []
        if (id !== "antigravity")
            return [{ title: providerTitle(id), notice: providerNotice(id), rows: rows }]
        var sections = []
        var byGroup = {}
        for (var i = 0; i < rows.length; i++) {
            var group = rows[i].group || "Antigravity Models"
            if (!byGroup[group]) {
                byGroup[group] = { title: group, notice: null, rows: [] }
                sections.push(byGroup[group])
            }
            byGroup[group].rows.push(rows[i])
        }
        return sections
    }

    function providerBlocked(id) {
        var blocking = provider(id).blockingWindows
        return providerRows(id).some(function (row) {
            return blocking.indexOf(row.pinKey) >= 0 && row.percentUsed >= 100
        })
    }

    // Pinned rows for the bar pill, with a separator before each new provider.
    // A blocked provider shows every pinned window as used up.
    function pillItems() {
        var out = []
        var enabled = enabledProviders()
        for (var i = 0; i < enabled.length; i++) {
            var pins = effectivePins(enabled[i].id)
            var rows = providerRows(enabled[i].id).filter(function (row) {
                return pins.indexOf(row.pinKey) >= 0
            })
            var blocked = providerBlocked(enabled[i].id)
            for (var j = 0; j < rows.length; j++) {
                rows[j].separator = out.length > 0 && j === 0
                if (blocked && !rows[j].isBalance) rows[j].shortValue = Math.round(pctVal(100)) + "%"
                out.push(rows[j])
            }
        }
        return out
    }

    // --- Pins ---

    function defaultPinState() {
        var defaults = {}
        for (var i = 0; i < providers.length; i++)
            defaults[providers[i].id] = providers[i].defaultPins.slice()
        defaults.opencode = [savedSetting("pinnedWindow", "Rolling") || "Rolling"]
        return defaults
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
        for (var i = 0; i < providers.length; i++) {
            var id = providers[i].id
            next[id] = raw && Array.isArray(raw[id]) ? raw[id] : defaults[id]
        }
        // Migrate old Grok API-status and plan-period pins to the stable billing pin.
        if (next.grok.length === 1 && (next.grok[0] === "status" || next.grok[0] === "Weekly"))
            next.grok = defaults.grok
        pinState = next
    }

    function savePinState() {
        if (pluginService && pluginService.savePluginData)
            pluginService.savePluginData("aiQuotas", "pinnedLimits", JSON.stringify(pinState))
    }

    // Saved pins that match the current data. When a provider has pins but none
    // of them exist (for example "5h" on a Codex plan with only a weekly window),
    // its first window takes their place. An empty pin list stays empty.
    function effectivePins(id) {
        var saved = pinState[id] || []
        var keys = providerRows(id).map(function (row) { return row.pinKey })
        var pins = saved.filter(function (name) { return keys.indexOf(name) >= 0 })
        if (pins.length === 0 && saved.length > 0 && keys.length > 0) pins = [keys[0]]
        return pins
    }

    function isPinned(id, name) {
        return effectivePins(id).indexOf(name) >= 0
    }

    function togglePin(id, name) {
        var next = {}
        for (var key in pinState) next[key] = pinState[key].slice()
        // Keep saved pins for windows that are missing right now, unless the
        // fallback pin is on display. Then the fallback becomes a real pin.
        var saved = next[id] || []
        var keys = providerRows(id).map(function (row) { return row.pinKey })
        var pins = saved.some(function (pin) { return keys.indexOf(pin) >= 0 }) ? saved : effectivePins(id)
        var index = pins.indexOf(name)
        if (index < 0) pins.push(name)
        else {
            pins.splice(index, 1)
            // Unpinning the last visible window hides the provider, without a fallback.
            if (!pins.some(function (pin) { return keys.indexOf(pin) >= 0 })) pins = []
        }
        next[id] = pins
        pinState = next
        savePinState()
    }

    // --- Formatting ---

    function cdown(t) {
        var d = t - Date.now() / 1000
        if (d <= 0) return "now"
        var days = Math.floor(d / 86400)
        var h = Math.floor((d % 86400) / 3600)
        var m = Math.floor((d % 3600) / 60)
        if (days > 0) return days + "d " + h + "h"
        return h > 0 ? h + "h " + m + "m" : m + "m"
    }

    function resetLabel(t) {
        if (!t) return "Reset time unavailable"
        if (t <= Date.now() / 1000) return "Resets now"
        if (showResetCountdown) return "Resets in " + cdown(t)
        var d = new Date(t * 1000)
        if (d.toDateString() === new Date().toDateString()) return "Resets " + clockTime(d)
        return "Resets " + d.toLocaleDateString(Qt.locale("en_US"), "MMM d, yyyy") + " " + clockTime(d)
    }

    // English text, like the rest of the plugin. The 12 or 24-hour clock follows DMS.
    function clockTime(date) {
        return date.toLocaleTimeString(Qt.locale("en_US"), SettingsData.use24HourClock ? "HH:mm" : "h:mm AP")
    }

    function fmtMoney(value, currency) {
        var amount = parseFloat(value)
        if (!isFinite(amount)) return "--"
        var suffix = currency === "USD" ? "$" : (currency === "CNY" ? "¥" : (currency || ""))
        return amount.toFixed(2) + suffix
    }

    function pctVal(pct) {
        return displayMode === "used" ? pct : 100 - pct
    }

    // Round to two decimals so values such as 35.09999999 read as 35.1.
    function pctStr(pct) {
        return Math.round(pctVal(pct) * 100) / 100 + (displayMode === "used" ? "% used" : "% remaining")
    }

    // --- Bar Pills ---

    // Same text size as the native DMS bar widgets.
    readonly property real barTextSize: Theme.barTextSize(barThickness, barConfig?.fontScale, barConfig?.maximizeWidgetText)

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

                // Placeholder until the first fetch finishes
                StyledText {
                    visible: !root.usageData
                    text: "✳ -"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: root.barTextSize
                }

                Repeater {
                    model: root.pillItems()
                    delegate: Row {
                        anchors.verticalCenter: parent.verticalCenter
                        // 8px between limits of one provider. A centered separator between providers.
                        leftPadding: index === 0 ? 0 : (modelData.separator ? Theme.spacingXS : Theme.spacingS)
                        spacing: Theme.spacingXS

                        Rectangle {
                            visible: modelData.separator
                            width: 1
                            height: pill.height - 8
                            color: Theme.outlineVariant
                            opacity: 0.4
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Image {
                            source: root.pluginDir + "assets/" + modelData.provider + "-logo.svg"
                            sourceSize.width: Theme.iconSizeSmall
                            sourceSize.height: Theme.iconSizeSmall
                            width: Theme.iconSizeSmall; height: Theme.iconSizeSmall
                            fillMode: Image.PreserveAspectFit
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: modelData.isBalance ? modelData.value : modelData.shortValue
                            color: Theme.surfaceText
                            font.pixelSize: root.barTextSize
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
                    text: "✳"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                }

                Repeater {
                    model: root.pillItems()
                    delegate: Column {
                        spacing: Theme.spacingXXS
                        Image {
                            source: root.pluginDir + "assets/" + modelData.provider + "-logo.svg"
                            sourceSize.width: Theme.iconSizeSmall
                            sourceSize.height: Theme.iconSizeSmall
                            width: Theme.iconSizeSmall; height: Theme.iconSizeSmall
                            fillMode: Image.PreserveAspectFit
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: modelData.shortValue
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

    // Measures tab labels so the popout can grow until every provider tab fits.
    FontMetrics {
        id: tabLabelMetrics
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
    }

    readonly property real tabWidth: Theme.iconSizeSmall + Theme.spacingM * 2
    // Fits the longest enabled label, so the popout keeps its width when the tab changes.
    readonly property real selectedTabWidth: {
        var widest = 0
        var enabled = enabledProviders()
        for (var i = 0; i < enabled.length; i++)
            widest = Math.max(widest, tabLabelMetrics.advanceWidth(enabled[i].label))
        return tabWidth + Theme.spacingXS + Math.ceil(widest)
    }

    popoutWidth: {
        var count = enabledProviders().length
        var tabs = count === 0 ? 0 : selectedTabWidth + (count - 1) * (tabWidth + Theme.spacingXS)
        // PluginPopout adds spacingS on each side. The content column adds spacingM.
        return Math.max(420, Math.ceil(tabs + (Theme.spacingS + Theme.spacingM) * 2))
    }
    popoutHeight: 700
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
                    height: Theme.iconSize + Theme.spacingM
                    spacing: Theme.spacingXS

                    Repeater {
                        model: root.enabledProviders()
                        delegate: Rectangle {
                            readonly property bool selected: root.selectedProvider === modelData.id
                            // The selected tab is 1.8 times wider, and never narrower than its label.
                            width: {
                                var count = root.enabledProviders().length
                                var available = providerTabsRow.width - Theme.spacingXS * (count - 1)
                                var selectedWidth = Math.max(1.8 * available / (count + 0.8), root.selectedTabWidth)
                                if (count < 2) return available
                                return selected ? selectedWidth : (available - selectedWidth) / (count - 1)
                            }
                            height: providerTabsRow.height
                            radius: Theme.cornerRadius
                            color: selected ? Theme.surfaceSelected
                                : (tabMouse.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHigh)
                            border.color: selected ? Theme.outlineMedium : Theme.outlineVariant
                            border.width: 1
                            clip: true

                            Behavior on width {
                                NumberAnimation { duration: 180; easing.type: Easing.InOutQuad }
                            }

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                Image {
                                    source: root.pluginDir + "assets/" + modelData.id + "-logo.svg"
                                    sourceSize.width: Theme.iconSizeSmall
                                    sourceSize.height: Theme.iconSizeSmall
                                    width: Theme.iconSizeSmall; height: Theme.iconSizeSmall
                                    fillMode: Image.PreserveAspectFit
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    visible: selected
                                    text: modelData.label
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
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

                Repeater {
                    id: sectionRepeater
                    model: root.providerSections(root.selectedProvider)
                    delegate: StyledRect {
                        id: card
                        readonly property var section: modelData
                        width: parent.width
                        height: cardColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            id: cardColumn
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            StyledText {
                                text: card.section.title
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                            }

                            StyledText {
                                visible: card.section.notice !== null
                                text: card.section.notice ? card.section.notice.text : ""
                                color: card.section.notice ? card.section.notice.color : Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            Repeater {
                                model: card.section.rows
                                delegate: Column {
                                    id: limitRow
                                    readonly property bool pinned: root.isPinned(modelData.provider, modelData.pinKey)
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    Row {
                                        width: parent.width
                                        spacing: Theme.spacingM

                                        Image {
                                            source: root.pluginDir + "assets/" + modelData.provider + "-logo.svg"
                                            sourceSize.width: Theme.iconSize + Theme.spacingXS
                                            sourceSize.height: Theme.iconSize + Theme.spacingXS
                                            width: Theme.iconSize + Theme.spacingXS; height: width
                                            fillMode: Image.PreserveAspectFit
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        Column {
                                            width: parent.width - (Theme.iconSize + Theme.spacingXS) * 2 - Theme.spacingM * 2
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Theme.spacingXXS

                                            StyledText {
                                                width: parent.width
                                                elide: Text.ElideRight
                                                text: modelData.label
                                                color: Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                            }
                                            StyledText {
                                                text: modelData.value
                                                color: Theme.surfaceText
                                                font.pixelSize: Theme.fontSizeLarge
                                                font.weight: Font.Bold
                                            }
                                            Repeater {
                                                model: modelData.details
                                                delegate: StyledText {
                                                    text: modelData
                                                    color: Theme.surfaceVariantText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                }
                                            }
                                        }

                                        Rectangle {
                                            width: Theme.iconSize + Theme.spacingXS; height: width
                                            radius: Theme.cornerRadius
                                            color: limitRow.pinned ? Theme.surfaceSelected
                                                : (pinArea.containsMouse ? Theme.surfaceHover : Theme.surfaceContainerHighest)
                                            border.color: limitRow.pinned ? Theme.outlineMedium : Theme.outlineVariant
                                            border.width: 1
                                            anchors.verticalCenter: parent.verticalCenter

                                            MouseArea {
                                                id: pinArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.togglePin(modelData.provider, modelData.pinKey)
                                            }

                                            DankIcon {
                                                anchors.centerIn: parent
                                                name: "push_pin"
                                                size: Theme.iconSizeSmall
                                                color: limitRow.pinned ? Theme.primary : Theme.surfaceVariantText
                                                rotation: limitRow.pinned ? 0 : 45
                                            }
                                        }
                                    }

                                    Rectangle {
                                        id: progressTrack
                                        visible: !modelData.isBalance
                                        width: parent.width
                                        height: Theme.spacingS
                                        radius: Math.min(Theme.cornerRadius, height / 2)
                                        color: Theme.outlineVariant

                                        Rectangle {
                                            width: progressTrack.width * Math.max(0, Math.min(100, root.pctVal(modelData.percentUsed))) / 100
                                            height: parent.height
                                            radius: parent.radius
                                            color: Theme.primary
                                        }
                                    }

                                    StyledText {
                                        visible: !modelData.isBalance && root.showResetTime && modelData.resetAt > 0
                                        text: root.resetLabel(modelData.resetAt)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }
                        }
                    }
                }

                StyledRect {
                    visible: sectionRepeater.count === 0
                    width: parent.width
                    height: messageText.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    StyledText {
                        id: messageText
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        wrapMode: Text.WordWrap
                        text: root.providerMessage(root.selectedProvider)
                        color: root.providerMessageColor(root.selectedProvider)
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
            }
        }
    }
}
