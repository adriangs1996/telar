pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// A dialog's footer: a keyboard hint, Cancel and the primary action.
Item {
    id: root

    required property var colors
    required property var typography
    property real ratio: 1
    property string hint: ""
    property string submitText: ""
    property bool submittable: true
    readonly property real buttonHeight: 32 * ratio
    readonly property real buttonPadding: 16 * ratio
    readonly property real buttonGap: 8 * ratio
    readonly property real buttonRadius: ChromeStyle.controlRadius * ratio
    readonly property real disabledAlpha: 0.45
    readonly property real pressedAlpha: 0.75
    readonly property real hintAlpha: 0.8

    signal submitted()
    signal cancelled()

    implicitHeight: buttonHeight

    ChromeText {
        anchors.left: parent.left
        anchors.right: buttons.left
        height: parent.height
        text: root.hint
        color: Qt.alpha(root.colors.subtext0, root.hintAlpha)
        pixelSize: root.typography.small ?? 1
    }

    Row {
        id: buttons
        anchors.right: parent.right
        height: parent.height
        spacing: root.buttonGap

        FormButton {
            objectName: "promptCancel"
            width: textAdvance + 2 * root.buttonPadding
            height: parent.height
            text: "Cancel"
            colors: root.colors
            pixelSize: root.typography.body ?? 1
            radius: root.buttonRadius
            disabledAlpha: root.disabledAlpha
            pressedAlpha: root.pressedAlpha
            onActivated: root.cancelled()
        }

        FormButton {
            objectName: "promptSubmit"
            width: textAdvance + 2 * root.buttonPadding
            height: parent.height
            text: root.submitText
            primary: true
            interactive: root.submittable
            colors: root.colors
            pixelSize: root.typography.body ?? 1
            radius: root.buttonRadius
            disabledAlpha: root.disabledAlpha
            pressedAlpha: root.pressedAlpha
            onActivated: root.submitted()
        }
    }
}
