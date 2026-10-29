pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var colors
    required property real pixelSize
    required property real radius
    required property real disabledAlpha
    required property real pressedAlpha
    required property string text
    property string identity: ""
    property bool primary: false
    property bool quiet: false
    property string accessibleLabel: text
    property bool interactive: true
    property color labelColor: colors.text
    readonly property real textAdvance: label.implicitWidth
    signal activated()

    opacity: interactive ? 1 : disabledAlpha
    Accessible.role: Accessible.Button
    Accessible.name: accessibleLabel
    Accessible.onPressAction: if (interactive) root.activated()

    NativeRoundedRectangle {
        anchors.fill: parent
        color: root.primary ? root.colors.accent : (pointer.containsMouse || pointer.pressed ? root.colors.surface1 : root.colors.surface0)
        radius: root.radius
        visible: !root.quiet || pointer.containsMouse || pointer.pressed
    }

    ChromeText {
        id: label
        anchors.fill: parent
        text: root.text
        color: root.primary ? root.colors.surface_dim : root.labelColor
        opacity: pointer.pressed && root.interactive ? root.pressedAlpha : 1
        pixelSize: root.pixelSize
        emphasized: root.primary
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideNone
    }

    ActionPointer {
        id: pointer
        anchors.fill: parent
        enabled: root.interactive
        identity: root.identity
        onActivated: root.activated()
    }
}
