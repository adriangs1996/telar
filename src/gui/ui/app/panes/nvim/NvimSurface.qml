pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The surface of what floats over an editor's text: telar's dialog surface on a base that
// hides the cells under it, so nothing of the text shows through a translucent theme. A tint
// edges it in a color of its own, as the command line does in each of its modes.
Item {
    id: root

    required property var colors
    property real ratio: 1
    property color tint: "transparent"

    readonly property color base: root.colors.terminalBackground

    Rectangle {
        anchors.fill: parent
        radius: ChromeStyle.dialogRadius * root.ratio
        color: Qt.rgba(root.base.r, root.base.g, root.base.b, 1)
        antialiasing: true
    }

    DialogSurface {
        anchors.fill: parent
        colors: root.colors
        ratio: root.ratio
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        visible: root.tint.a > 0
        color: "transparent"
        radius: ChromeStyle.dialogRadius * root.ratio
        borderWidth: Math.max(1, root.ratio) / Screen.devicePixelRatio
        borderColor: root.tint
        borderAlpha: 0.5
    }
}
