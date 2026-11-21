pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// One measure of a panel, in the terminal's font: its name, a bar of its share, and its value at
// the right. The bar takes its color from how full it is.
Item {
    id: root

    required property var colors
    required property var grid
    property string label
    property string value
    property real fraction: 0
    // normal, warm or hot.
    property string tone: "normal"
    property real labelWidth: 10 * cellWidth
    property real valueWidth: 12 * cellWidth
    property real ratio: 1

    readonly property real cellWidth: grid.cellWidth ?? 8
    readonly property real gap: cellWidth
    readonly property real barHeight: 6 * ratio

    implicitHeight: grid.cellHeight ?? 16

    CellText {
        width: root.labelWidth
        height: root.height
        text: root.label
        grid: root.grid
        color: root.colors.subtext0
        clip: true
    }

    Rectangle {
        id: track

        x: root.labelWidth + root.gap
        y: (root.height - height) / 2
        width: Math.max(0, root.width - root.labelWidth - root.valueWidth - 2 * root.gap)
        height: root.barHeight
        radius: height / 2
        color: root.colors.surface1

        Rectangle {
            width: Math.max(root.fraction > 0 ? track.height : 0, track.width * Math.max(0, Math.min(1, root.fraction)))
            height: parent.height
            radius: parent.radius
            color: root.tone === "hot" ? root.colors.red : root.tone === "warm" ? root.colors.yellow : root.colors.green
        }
    }

    CellText {
        x: root.width - width
        width: Math.min(implicitWidth, root.valueWidth)
        height: root.height
        text: root.value
        grid: root.grid
        color: root.colors.text
        clip: true
    }

    Accessible.role: Accessible.StaticText
    Accessible.name: label + " " + value
}
