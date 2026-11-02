pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "suggestionPanel"

    required property var state
    required property var regions
    required property var colors
    required property var typography
    property real ratio: 1
    signal submitted(string revision)
    signal backRequested()

    ChromeText {
        x: root.regions.title.x
        y: root.regions.title.y
        width: root.regions.title.width
        height: root.regions.title.height
        text: "Suggest a command"
        pixelSize: root.typography.small
        color: Qt.alpha(root.colors.text, root.regions.titleAlpha)
        elide: Text.ElideNone
    }

    PaletteButton {
        objectName: "suggestionBack"
        x: root.regions.back.x
        y: root.regions.back.y
        width: root.regions.back.width
        height: root.regions.back.height
        visible: root.state.hasParent
        colors: root.colors
        pixelSize: root.typography.body
        ratio: root.ratio
        text: "‹"
        accessibleLabel: "Back to actions"
        identity: root.state.revision
        onActivated: root.backRequested()
    }

    ChromeText {
        x: root.regions.heading.x
        y: root.regions.heading.y
        width: root.regions.heading.width
        height: root.regions.heading.height
        text: root.state.heading
        pixelSize: root.typography.body
        emphasized: true
        color: root.state.failed ? root.colors.red : root.colors.text
        elide: Text.ElideNone
    }

    NativeRoundedRectangle {
        x: root.regions.body.x
        y: root.regions.body.y
        width: root.regions.body.width
        height: root.regions.body.height
        radius: root.regions.previewRadius
        color: root.colors.surface0
        visible: root.state.ready
    }

    ChromeText {
        x: root.regions.message.x
        y: root.regions.message.y
        width: root.regions.message.width
        height: root.regions.message.height
        text: root.state.message
        pixelSize: root.typography.body
        color: Qt.alpha(root.colors.text, root.regions.messageAlpha)
        visible: !root.state.ready
        elide: Text.ElideNone
    }

    Repeater {
        model: root.regions.lines
        delegate: Item {
            id: line
            required property var modelData
            x: modelData.bounds.x
            y: modelData.bounds.y
            width: modelData.bounds.width
            height: modelData.bounds.height
            clip: true

            CellText {
                anchors.fill: parent
                text: line.modelData.text
                grid: root.regions.grid
                color: root.colors.text
                visible: !line.modelData.shortened
            }

            ChromeText {
                anchors.fill: parent
                text: line.modelData.text
                pixelSize: root.typography.small
                color: Qt.alpha(root.colors.text, root.regions.messageAlpha)
                visible: line.modelData.shortened
                elide: Text.ElideNone
            }
        }
    }

    Rectangle {
        x: root.regions.separator.x
        y: root.regions.separator.y
        width: root.regions.separator.width
        height: root.regions.separator.height
        color: root.colors.surface1
    }

    ChromeText {
        x: root.regions.footer.x
        y: root.regions.footer.y
        width: root.regions.footer.width
        height: root.regions.footer.height
        text: root.state.footer
        pixelSize: root.typography.small
        color: Qt.alpha(root.colors.text, root.regions.messageAlpha)
        elide: Text.ElideNone
    }

    PaletteButton {
        objectName: "suggestionSubmit"
        x: root.regions.button.x
        y: root.regions.button.y
        width: root.regions.button.width
        height: root.regions.button.height
        text: root.state.button
        colors: root.colors
        pixelSize: root.typography.body
        ratio: root.ratio
        interactive: root.state.canSubmit
        identity: root.state.revision
        onActivated: root.submitted(root.state.revision)
    }
}
