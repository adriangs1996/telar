pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// A key as overlays name it: a filled cap, sized to its label, centred in its height.
Item {
    id: root

    required property var colors
    required property var typography
    required property string text
    property real ratio: 1
    // Filled with the accent: the key of what Enter does.
    property bool primary: false
    readonly property real minimumHeight: 20 * ratio
    readonly property real minimumWidth: 20 * ratio
    readonly property real horizontalPadding: 5 * ratio
    readonly property real verticalPadding: 4 * ratio
    readonly property real cornerRadius: ChromeStyle.smallRadius * ratio
    readonly property real textAlpha: 0.75
    readonly property real boxHeight: Math.min(height, Math.max(minimumHeight, typography.smallRow + verticalPadding))
    property alias textAdvance: label.implicitWidth

    implicitWidth: Math.max(minimumWidth, label.implicitWidth + 2 * horizontalPadding)
    implicitHeight: boxHeight

    NativeRoundedRectangle {
        width: root.width
        height: root.boxHeight
        y: (root.height - height) / 2
        color: root.primary ? root.colors.accent : root.colors.surface0
        radius: root.cornerRadius
    }

    ChromeText {
        id: label
        anchors.fill: parent
        text: root.text
        pixelSize: root.typography.small
        emphasized: root.primary
        color: root.primary ? root.colors.background : Qt.alpha(root.colors.text, root.textAlpha)
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideNone
    }
}
