pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var colors
    required property var typography
    required property string text
    property real ratio: 1
    readonly property real minimumHeight: 20 * ratio
    readonly property real verticalPadding: 4 * ratio
    readonly property real cornerRadius: ChromeStyle.smallRadius * ratio
    readonly property real outlineAlpha: 0.2
    readonly property real textAlpha: 0.7
    readonly property real boxHeight: Math.min(height, Math.max(minimumHeight, typography.smallRow + verticalPadding))
    property alias textAdvance: label.implicitWidth

    NativeRoundedRectangle {
        width: root.width
        height: root.boxHeight
        y: (root.height - height) / 2
        color: "transparent"
        borderColor: Qt.alpha(root.colors.text, root.outlineAlpha)
        borderWidth: root.ratio
        radius: root.cornerRadius
    }

    ChromeText {
        id: label
        anchors.fill: parent
        text: root.text
        pixelSize: root.typography.small
        color: Qt.alpha(root.colors.text, root.textAlpha)
        horizontalAlignment: Text.AlignHCenter
    }
}
