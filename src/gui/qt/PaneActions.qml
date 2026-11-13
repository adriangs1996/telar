pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Row {
    id: root
    objectName: "paneActions"

    required property GuiController controller
    required property string paneKey
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property real side: 24 * ratio

    spacing: 2 * ratio

    function execute(action) {
        controller.execute(GuiController.Action.focus_pane, paneKey);
        controller.execute(action);
    }

    Repeater {
        model: [
            {label: "Split right", divider: "vertical", action: GuiController.Action.split_horizontal},
            {label: "Split below", divider: "horizontal", action: GuiController.Action.split_vertical},
            {label: "Expand pane", glyph: "", action: GuiController.Action.fullscreen},
            {label: "Close pane", glyph: "", action: GuiController.Action.close_pane}
        ]

        delegate: ChromeButton {
            id: action
            required property var modelData
            readonly property color ink: hovered ? root.colors.chromeText : root.colors.text
            objectName: "paneAction"
            width: root.side
            height: root.side
            colors: root.colors
            pixelSize: root.typography.body
            cornerRadius: ChromeStyle.controlRadius * root.ratio
            contentItem: Item {
                // Font split glyphs lose their divider at this size, so these two are drawn.
                NativeRoundedRectangle {
                    id: outline
                    anchors.centerIn: parent
                    width: 13 * root.ratio
                    height: 11 * root.ratio
                    radius: 2 * root.ratio
                    color: "transparent"
                    borderColor: action.ink
                    borderWidth: root.ratio
                    visible: action.modelData.divider !== undefined
                }

                Rectangle {
                    anchors.centerIn: outline
                    width: action.modelData.divider === "vertical" ? root.ratio : outline.width
                    height: action.modelData.divider === "vertical" ? outline.height : root.ratio
                    color: action.ink
                    visible: outline.visible
                }

                ChromeIcon {
                    anchors.fill: parent
                    glyph: action.modelData.glyph ?? ""
                    color: action.ink
                    pixelSize: 14 * root.ratio
                    visible: action.modelData.glyph !== undefined
                }
            }
            Accessible.name: modelData.label
            onClicked: root.execute(modelData.action)
        }
    }
}
