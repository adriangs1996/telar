pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The surface of what floats over an editor's text: telar's dialog surface on a base that
// hides the cells under it, so nothing of the text shows through a translucent theme.
Item {
    id: root

    required property var colors
    property real ratio: 1

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
}
