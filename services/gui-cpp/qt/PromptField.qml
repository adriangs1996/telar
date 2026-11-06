pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// A dialog's rounded text field, outlined in the accent while it has focus.
// Tab, the arrows, Enter and Escape become signals for the dialog to route.
Item {
    id: root

    required property var colors
    required property var typography
    property real ratio: 1
    property alias input: input
    property alias text: input.text
    property alias placeholderText: input.placeholderText
    property string inputName: ""
    readonly property real padding: 9 * ratio
    readonly property real cornerRadius: ChromeStyle.controlRadius * ratio
    readonly property real focusOutline: 1 / Screen.devicePixelRatio

    signal edited()
    signal submitted()
    signal cancelled()
    signal tabbed(bool backward)
    signal moved(int delta)

    implicitHeight: (typography.bodyRow ?? 0) + 2 * padding

    NativeRoundedRectangle {
        anchors.fill: parent
        color: root.colors.surface0
        radius: root.cornerRadius
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        color: "transparent"
        radius: root.cornerRadius
        borderWidth: root.focusOutline
        borderColor: input.activeFocus ? root.colors.accent : root.colors.text
        borderAlpha: input.activeFocus ? ChromeStyle.focusAlpha : ChromeStyle.outlineAlpha
    }

    FormTextField {
        id: input
        objectName: root.inputName
        anchors.fill: parent
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        Accessible.name: placeholderText
        onTextEdited: root.edited()
        Keys.onReturnPressed: root.submitted()
        Keys.onEnterPressed: root.submitted()
        Keys.onEscapePressed: {
            if (!input.cancelComposition()) {
                root.cancelled();
            }
        }
        Keys.onTabPressed: root.tabbed(false)
        Keys.onBacktabPressed: root.tabbed(true)
        Keys.onUpPressed: root.moved(-1)
        Keys.onDownPressed: root.moved(1)
    }
}
