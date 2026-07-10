import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "codexbar"

    readonly property int warnPct: 70
    readonly property int critPct: 90
    readonly property int staleMinutes: 60

    readonly property int refreshInterval: pluginData.refreshInterval || 60
    readonly property int maxBarProviders: pluginData.maxBarProviders || 3
    readonly property string displayStyle: pluginData.displayStyle || "rings"
    readonly property bool showCredits: pluginData.showCredits !== false
    readonly property bool showResetTime: pluginData.showResetTime !== false
    readonly property string providers: pluginData.providers || "all"

    property var usageData: null
    property bool fetchFailed: false
    property real now: Date.now() / 1000

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
            "CODEXBAR_PROVIDERS='" + root.providers + "' " +
            "CODEXBAR_USAGE_MOCK=${CODEXBAR_USAGE_MOCK:-} " +
            "sh '" + Qt.resolvedUrl("fetch-usage.sh") + "'"
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
                if (line.trim()) console.warn("codexbar:", line)
            }
        }
        onExited: code => {
            if (code !== 0 && !root.usageData) root.fetchFailed = true
        }
    }

    function sortedProviders() {
        if (!usageData) return []
        var list = []
        for (var i = 0; i < usageData.length; i++) {
            var p = usageData[i]
            var pct = 0
            if (p.usage && p.usage.primary) pct = p.usage.primary.usedPercent || 0
            list.push({ data: p, pct: pct })
        }
        list.sort(function (a, b) { return b.pct - a.pct })
        var out = []
        for (var j = 0; j < list.length; j++) out.push(list[j].data)
        return out
    }

    function topProviders() {
        return sortedProviders().slice(0, maxBarProviders)
    }

    function providerName(p) {
        var names = {
            codex: "Codex", openai: "OpenAI", claude: "Claude",
            cursor: "Cursor", copilot: "Copilot", gemini: "Gemini",
            grok: "Grok", groqcloud: "Groq", deepseek: "DeepSeek",
            opencode: "OpenCode", windsurf: "Windsurf", zed: "Zed",
            kilo: "Kilo", kiro: "Kiro", elevenlabs: "11Labs",
            openrouter: "OpenRouter", vertexai: "Vertex",
            augment: "Augment", litellm: "LiteLLM", deepgram: "Deepgram"
        }
        return names[p.provider] || p.provider
    }

    function statusColor(p) {
        if (!p.status) return "none"
        return p.status.indicator || "none"
    }

    function color(pct) {
        return pct >= critPct ? Theme.error : pct >= warnPct ? Theme.warning : Theme.primary
    }

    function countdown(resetsAt) {
        if (!resetsAt) return "--"
        var diff = resetsAt - now
        if (diff <= 0) return "now"
        var h = Math.floor(diff / 3600)
        var m = Math.floor((diff % 3600) / 60)
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }

    function creditsText(p) {
        if (!p.credits || p.credits.remaining === undefined) return ""
        return Math.round(p.credits.remaining) + " left"
    }

    function sessionPct(p) {
        if (p.usage && p.usage.primary) return p.usage.primary.usedPercent || 0
        return 0
    }

    function weeklyPct(p) {
        if (p.usage && p.usage.secondary) return p.usage.secondary.usedPercent || 0
        return 0
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
                    model: root.usageData && root.displayStyle === "rings" ? root.topProviders() : []
                    delegate: Row {
                        spacing: 4
                        Layout.alignment: Qt.AlignVCenter
                        UsageRing {
                            percentage: root.sessionPct(modelData)
                            ringColor: root.color(root.sessionPct(modelData))
                            diameter: Math.max(12, Math.min(pill.height - 9, 18))
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        StyledText {
                            text: root.sessionPct(modelData) + "%"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                StyledText {
                    visible: root.usageData && root.displayStyle === "numbers"
                    text: {
                        var top = root.topProviders()
                        if (top.length === 0) return ""
                        var parts = []
                        for (var i = 0; i < top.length; i++) {
                            parts.push(root.sessionPct(top[i]) + "%")
                        }
                        return "\u2733 " + parts.join(" \u00b7 ")
                    }
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
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
                    model: root.usageData ? root.topProviders() : []
                    delegate: Column {
                        spacing: 1
                        Layout.alignment: Qt.AlignHCenter
                        UsageRing {
                            percentage: root.sessionPct(modelData)
                            ringColor: root.color(root.sessionPct(modelData))
                            diameter: Math.max(12, Math.min(pillV.width - 8, 18))
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                        StyledText {
                            text: root.sessionPct(modelData) + "%"
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
    popoutHeight: 420
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "CodexBar Usage"
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingM

                Repeater {
                    model: root.sortedProviders()
                    delegate: Column {
                        width: parent.width
                        spacing: Theme.spacingXS

                        Row {
                            width: parent.width
                            spacing: Theme.spacingM

                            UsageRing {
                                percentage: root.sessionPct(modelData)
                                ringColor: root.color(root.sessionPct(modelData))
                                diameter: 32
                                thickness: 3.5
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                width: parent.width - 44
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                Row {
                                    spacing: Theme.spacingS
                                    StyledText {
                                        text: root.providerName(modelData)
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                    }
                                    StyledText {
                                        visible: root.statusColor(modelData) !== "none" && root.statusColor(modelData) !== "none"
                                        text: root.statusColor(modelData) === "critical" ? "\u26a0" : ""
                                        color: Theme.error
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                    StyledText {
                                        visible: root.showCredits && root.creditsText(modelData) !== ""
                                        text: root.creditsText(modelData)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }

                                Row {
                                    spacing: Theme.spacingS
                                    StyledText {
                                        text: "Session: " + root.sessionPct(modelData) + "%"
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                    StyledText {
                                        visible: root.weeklyPct(modelData) > 0
                                        text: " | Weekly: " + root.weeklyPct(modelData) + "%"
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }

                                StyledText {
                                    visible: {
                                        var u = modelData.usage
                                        return root.showResetTime && u && u.primary && u.primary.resetsAt
                                    }
                                    property real resetAt: {
                                        var u = modelData.usage
                                        if (u && u.primary && u.primary.resetsAt) return u.primary.resetsAt
                                        return 0
                                    }
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

                StyledText {
                    width: parent.width
                    visible: !root.usageData || root.usageData.length === 0
                    text: root.fetchFailed
                        ? "Could not fetch usage. Is codexbar installed and configured?"
                        : "Loading usage..."
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    width: parent.width
                    visible: root.usageData && root.usageData.length > 0
                    text: "Updated " + Math.round((Date.now() / 1000 - (root.usageData && root.usageData[0] ? (root.usageData[0].captured_at || 0) : 0))) + "s ago"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }
}
