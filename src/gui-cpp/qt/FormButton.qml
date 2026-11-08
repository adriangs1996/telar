pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

KeyboardAction {
    id: root

    required property var colors
    required property real pixelSize
    required property real radius
    required property real disabledAlpha
    required property real pressedAlpha
    required property string text
    property string identity: ""
    property bool usePresentedHover: false
    property bool presentedHover: false
    readonly property bool hovered: root.usePresentedHover ? root.presentedHover : pointer.containsMouse
    property bool primary: false
    property bool quiet: false
    property string accessibleLabel: text
    property color labelColor: colors.text
    readonly property real textAdvance: label.implicitWidth
    opacity: interactive ? 1 : disabledAlpha
    Accessible.role: Accessible.Button
    Accessible.name: accessibleLabel
    Accessible.onPressAction: if (interactive)
        root.activated()

    NativeRoundedRectangle {
        anchors.fill: parent
        color: root.primary ? root.colors.accent : Qt.alpha(root.colors.text, root.hovered || pointer.pressed || root.activeFocus ? ChromeStyle.selectionAlpha : ChromeStyle.hoverAlpha)
        radius: root.radius
        borderColor: root.activeFocus ? root.colors.accent : root.colors.text
        borderAlpha: root.activeFocus ? ChromeStyle.focusAlpha : ChromeStyle.outlineAlpha
        borderWidth: !root.primary && (!root.quiet || root.activeFocus) ? 1 / Screen.devicePixelRatio : 0
        visible: !root.quiet || root.hovered || pointer.pressed || root.activeFocus
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
