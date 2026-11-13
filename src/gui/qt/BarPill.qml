import QtQuick
import Telar.Gui

// The outline of a bar item that does something when clicked. An alert inside
// it tints the outline: 1 warning, 2 danger.
NativeRoundedRectangle {
    id: root

    required property var colors
    property int severity: 0
    property real ratio: 1

    readonly property color tone: severity === 2 ? colors.red : colors.yellow

    objectName: "barPill"
    color: severity === 2 ? Qt.alpha(tone, 0.10) : severity === 1 ? Qt.alpha(tone, 0.08) : "transparent"
    borderColor: severity === 2 ? Qt.alpha(tone, 0.6) : severity === 1 ? Qt.alpha(tone, 0.45) : colors.surface1
    borderWidth: ratio
    radius: height / 2
}
