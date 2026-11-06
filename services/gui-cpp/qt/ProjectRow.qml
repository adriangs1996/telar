import QtQuick

Rectangle {
    id: root

    required property var record
    required property var colors
    required property var typography
    property real ratio: 1
    signal selected(string key)

    readonly property real rowInset: 12 * ratio
    readonly property real titleInset: 10 * ratio
    readonly property real iconSide: 18 * ratio
    readonly property real iconGap: 9 * ratio
    readonly property real rowRadius: 6 * ratio
    readonly property real attentionGap: 8 * ratio
    readonly property real textLeft: icon.x + icon.width + iconGap
    readonly property real textWidth: Math.max(0, width - rowInset - textLeft)
    readonly property color inactiveInk: "#737373"

    radius: rowRadius
    color: pointer.containsMouse ? colors.surface1 : "transparent"

    ChromeIcon {
        id: icon
        x: root.rowInset
        y: (parent.height - height) / 2
        width: root.iconSide
        height: width
        glyph: "\uf07b"
        primaryFamily: root.typography.primaryFamily ?? ""
        primaryStyle: root.typography.primaryStyle ?? ""
        color: root.record.selected ? root.colors.text : root.inactiveInk
        pixelSize: root.typography.body
    }

    ChromeText {
        id: title
        objectName: "projectTitle"
        x: root.textLeft
        y: root.titleInset
        width: Math.max(0, root.textWidth - (attention.visible ? attention.width + root.attentionGap : 0))
        height: root.typography.bodyRow
        text: root.record.name
        color: root.record.selected ? root.colors.text : root.inactiveInk
        emphasized: true
        pixelSize: root.typography.body
    }

    ChromeText {
        id: attention
        objectName: "projectAttention"
        x: root.textLeft + root.textWidth - width
        y: title.y
        width: Math.min(root.textWidth, implicitWidth)
        height: title.height
        text: root.record.attention ?? ""
        color: root.record.selected ? root.colors[root.record.attentionColor ?? "overlay1"] : root.inactiveInk
        pixelSize: root.typography.small
        elide: Text.ElideNone
        visible: text.length > 0
    }

    ChromeText {
        objectName: "projectDetail"
        x: root.textLeft
        y: title.y + title.height
        width: root.textWidth
        height: root.typography.smallRow
        text: root.record.detail ?? root.record.path
        color: root.record.selected ? root.colors.subtext0 : root.inactiveInk
        pixelSize: root.typography.small
    }

    MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.selected(root.record.key)
    }

    Accessible.role: Accessible.ListItem
    Accessible.name: record.name + " " + (record.detail ?? record.path)
    Accessible.selected: record.selected
    Accessible.onPressAction: root.selected(record.key)
}
