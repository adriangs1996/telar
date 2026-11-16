pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

NativeRoundedRectangle {
    id: root

    required property string text
    required property color ink
    required property real pixelSize
    property real ratio: 1

    readonly property real padding: 6 * ratio
    readonly property real badgeHeight: 16 * ratio
    readonly property real badgeRadius: 4 * ratio
    readonly property real fillAlpha: 0.16

    implicitWidth: label.implicitWidth + 2 * padding
    implicitHeight: badgeHeight
    radius: badgeRadius
    color: Qt.alpha(ink, fillAlpha)

    ChromeText {
        id: label

        x: root.padding
        width: Math.max(0, parent.width - 2 * root.padding)
        height: parent.height
        text: root.text
        color: root.ink
        pixelSize: root.pixelSize
        emphasized: true
    }
}
