import QtQuick

Item {
    id: root

    property real percentage: 0
    property color ringColor: Theme.primary
    property real diameter: 18
    property real thickness: 2.5

    width: diameter
    height: diameter

    Canvas {
        id: canvas
        anchors.fill: parent

        property real pct: root.percentage
        property color color: root.ringColor

        onPctChanged: requestPaint()
        onColorChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            var cx = width / 2
            var cy = height / 2
            var r = Math.min(cx, cy) - root.thickness
            var startAngle = -Math.PI / 2
            var endAngle = startAngle + (2 * Math.PI * Math.min(pct, 100) / 100)

            ctx.reset()

            // Background track.
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, 2 * Math.PI)
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.1)
            ctx.lineWidth = root.thickness
            ctx.lineCap = "round"
            ctx.stroke()

            // Progress arc.
            if (pct > 0) {
                ctx.beginPath()
                ctx.arc(cx, cy, r, startAngle, endAngle)
                ctx.strokeStyle = root.color
                ctx.lineWidth = root.thickness
                ctx.lineCap = "round"
                ctx.stroke()
            }
        }
    }
}
