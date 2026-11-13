import QtQuick

Rectangle {
    id: root

    required property var preview
    required property var colors

    visible: preview.visible === true
    x: preview.x ?? 0
    y: preview.y ?? 0
    width: preview.width ?? 0
    height: preview.height ?? 0
    radius: preview.radius ?? 0
    color: colors.surface
    border.color: colors.border
    border.width: 1
    clip: true
    z: 10

    Repeater {
        model: root.preview.lines ?? []

        Text {
            required property int index
            required property string modelData

            x: root.preview.inset
            y: root.preview.inset + index * root.preview.rowHeight
            width: root.width - 2 * root.preview.inset
            height: root.preview.rowHeight
            font: root.preview.font
            textFormat: Text.PlainText
            text: modelData
            color: root.colors.foreground
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignLeft
        }
    }
}
