pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The bar's ring. With `fraction` set it shows one value over a track in the
// first colour; otherwise it splits into one arc per colour, clockwise from
// the top, with a gap between arcs.
Item {
    id: root

    property var segments: []
    property real fraction: -1
    property color trackColor: "transparent"
    property real ratio: 1

    // 16 px at the default chrome text; callers scale it with their text.
    property real side: 16 * ratio
    readonly property real stroke: side * 3 / 16
    readonly property real gap: side / 8
    readonly property bool value: fraction >= 0
    // Arc ends are round and reach half a stroke past their angle, so the gap reserves a stroke too.
    readonly property real gapTurns: segments.length > 1 ? (gap + stroke) / (Math.PI * (side - stroke)) : 0

    implicitWidth: side
    implicitHeight: side

    NativeProgressRing {
        anchors.fill: parent
        visible: root.value
        color: root.segments[0] ?? "transparent"
        trackColor: root.trackColor
        strokeWidth: root.stroke
        fraction: Math.max(0, root.fraction)
    }

    Repeater {
        model: root.value ? 0 : root.segments.length

        delegate: NativeProgressRing {
            required property int index
            objectName: "barRingArc"
            anchors.fill: parent
            color: root.segments[index]
            trackColor: "transparent"
            strokeWidth: root.stroke
            fraction: Math.max(0, 1 / root.segments.length - root.gapTurns)
            turns: index / root.segments.length + root.gapTurns / 2
        }
    }
}
