pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

ChromeButton {
    id: root
    objectName: "paneActionsButton"

    required property GuiController controller
    required property string paneKey
    required property var typography
    property real ratio: 1
    text: "\u22ef"
    pixelSize: typography.body + 3 * ratio
    Accessible.name: "Pane actions"
    ToolTip.visible: hovered
    ToolTip.delay: 700
    ToolTip.text: "Pane actions"
    onClicked: menu.open()

    function execute(action) {
        controller.execute(GuiController.Action.focus_pane, paneKey);
        controller.execute(action);
    }

    Menu {
        id: menu
        objectName: "paneActionsMenu"
        y: root.height + 4 * root.ratio
        x: root.width - width
        width: 190 * root.ratio
        padding: 5 * root.ratio
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: NativeRoundedRectangle {
            color: root.colors.surface0
            radius: ChromeStyle.surfaceRadius * root.ratio
            borderColor: root.colors.text
            borderAlpha: ChromeStyle.outlineAlpha
            borderWidth: 1 / Screen.devicePixelRatio
        }

        Repeater {
            model: [
                {label: "Split right", action: GuiController.Action.split_horizontal},
                {label: "Split below", action: GuiController.Action.split_vertical},
                {label: "Expand pane", action: GuiController.Action.fullscreen},
                {label: "Close pane", action: GuiController.Action.close_pane}
            ]

            delegate: MenuItem {
                id: entry
                objectName: "paneActionEntry"
                required property var modelData
                text: modelData.label
                readonly property bool destructive: modelData.action === GuiController.Action.close_pane
                height: (destructive ? 40 : 32) * root.ratio
                topPadding: destructive ? 8 * root.ratio : 0
                leftPadding: 8 * root.ratio
                onTriggered: root.execute(modelData.action)
                contentItem: ChromeText {
                    text: entry.text
                    pixelSize: root.typography.body + root.ratio
                    color: entry.destructive ? root.colors.red : root.colors.chromeText
                }
                Rectangle {
                    x: 8 * root.ratio
                    y: 2 * root.ratio
                    width: Math.max(0, entry.width - 16 * root.ratio)
                    height: 1 / Screen.devicePixelRatio
                    color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
                    visible: entry.destructive
                }
                background: NativeRoundedRectangle {
                    y: entry.topPadding
                    height: entry.height - y
                    color: Qt.alpha(root.colors.text, entry.highlighted ? ChromeStyle.selectionAlpha : 0)
                    radius: ChromeStyle.controlRadius * root.ratio
                }
            }
        }
    }
}
