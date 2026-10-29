import QtQuick
import QtQuick.Controls

Item {
    id: root

    required property var geometry
    required property var colors
    required property var typography
    property real ratio: 1
    signal selected(string key)

    readonly property real markSide: 20 * ratio
    readonly property real markRadius: 5 * ratio
    readonly property real buttonRadius: 10 * ratio
    readonly property real accentWidth: 3 * ratio
    readonly property real accentHeight: 20 * ratio
    readonly property real selectedAlpha: 0.3
    readonly property real idleAlpha: 0.22
    readonly property real idleLetterAlpha: 0.8

    Repeater {
        model: root.geometry.marks ?? []

        delegate: Item {
            id: mark
            objectName: "workspaceRailMark"
            required property var modelData
            readonly property var record: modelData.record
            readonly property color hue: root.colors[record.markHue]
            readonly property bool emphasized: record.selected || pointer.containsMouse

            x: modelData.bounds.x
            y: modelData.bounds.y
            width: modelData.bounds.width
            height: modelData.bounds.height

            Rectangle {
                anchors.fill: parent
                radius: root.buttonRadius
                color: mark.record.selected ? root.colors.surface1 : pointer.containsMouse ? root.colors.surface0 : "transparent"
            }

            Rectangle {
                x: -mark.x - root.accentWidth
                y: (parent.height - height) / 2
                width: root.accentWidth * 2
                height: Math.min(root.accentHeight, parent.height)
                radius: root.accentWidth
                color: root.colors.accent
                visible: mark.record.selected
            }

            Rectangle {
                anchors.centerIn: parent
                width: Math.min(root.markSide, parent.width)
                height: width
                radius: root.markRadius
                color: mark.hue
                opacity: mark.emphasized ? root.selectedAlpha : root.idleAlpha
                visible: mark.record.initial.length > 0
            }

            ChromeText {
                anchors.fill: parent
                text: mark.record.initial
                pixelSize: root.typography.body
                emphasized: true
                color: mark.hue
                opacity: mark.emphasized ? 1 : root.idleLetterAlpha
                horizontalAlignment: Text.AlignHCenter
            }

            ChromeIcon {
                anchors.centerIn: parent
                width: root.markSide
                height: width
                glyph: "\uf07b"
                primaryFamily: root.typography.primaryFamily ?? ""
                primaryStyle: root.typography.primaryStyle ?? ""
                color: mark.emphasized ? root.colors.text : root.colors.subtext0
                pixelSize: root.typography.body
                visible: mark.record.initial.length === 0
            }

            MouseArea {
                id: pointer
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.selected(mark.record.key)
            }

            ToolTip.visible: pointer.containsMouse
            ToolTip.text: record.name
            Accessible.role: Accessible.PageTab
            Accessible.name: record.name
            Accessible.selected: record.selected
            Accessible.onPressAction: root.selected(record.key)
        }
    }

    ChromeButton {
        x: root.geometry.previousBounds?.x ?? 0
        y: root.geometry.previousBounds?.y ?? 0
        width: root.geometry.previousBounds?.width ?? 0
        height: root.geometry.previousBounds?.height ?? 0
        visible: Boolean(root.geometry.previousKey)
        colors: root.colors
        pixelSize: root.typography.small
        cornerRadius: root.markRadius
        text: "+" + root.geometry.previousCount
        Accessible.name: "Previous hidden workspace"
        onClicked: root.selected(root.geometry.previousKey)
    }

    ChromeButton {
        x: root.geometry.nextBounds?.x ?? 0
        y: root.geometry.nextBounds?.y ?? 0
        width: root.geometry.nextBounds?.width ?? 0
        height: root.geometry.nextBounds?.height ?? 0
        visible: Boolean(root.geometry.nextKey)
        colors: root.colors
        pixelSize: root.typography.small
        cornerRadius: root.markRadius
        text: "+" + root.geometry.nextCount
        Accessible.name: "Next hidden workspace"
        onClicked: root.selected(root.geometry.nextKey)
    }
}
