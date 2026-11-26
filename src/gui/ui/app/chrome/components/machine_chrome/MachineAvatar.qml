pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// A machine's initial in a neutral disc. The hues belong to the workspaces, so a machine never
// fills with one: the color its owner gave it rings the disc, and a machine without one keeps a
// plain rim. The switch in the bar and the rows of its menu draw the same avatar.
NativeRoundedRectangle {
    id: root

    required property var colors
    required property string initial
    required property real pixelSize
    // The machine's own color, transparent when it has none.
    property color ink: "transparent"
    // The name tests and tools find the initial by, which differs between the bar and the menu.
    property string initialName: "machineAvatarInitial"
    readonly property bool tinted: ink.a > 0
    readonly property real hairline: 1 / Screen.devicePixelRatio

    radius: width / 2
    color: Qt.alpha(colors.chromeText, 0.1)
    borderColor: tinted ? ink : colors.chromeText
    borderAlpha: tinted ? 1 : 0.22
    borderWidth: tinted ? Math.max(hairline, Math.round(width / 14)) : hairline

    ChromeText {
        objectName: root.initialName
        anchors.fill: parent
        text: root.initial
        color: root.colors.chromeText
        pixelSize: root.pixelSize
        emphasized: true
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideNone
        Accessible.ignored: true
    }
}
