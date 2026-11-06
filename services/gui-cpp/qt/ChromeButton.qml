import QtQuick
import QtQuick.Controls

AbstractButton {
    id: root

    required property var colors
    required property real pixelSize
    property real cornerRadius: 8
    property bool emphasized: false
    property bool pointerHovered: hovered

    padding: 0
    hoverEnabled: true
    focusPolicy: Qt.TabFocus

    HoverHandler { cursorShape: Qt.PointingHandCursor }

    contentItem: ChromeText {
        text: root.text
        pixelSize: root.pixelSize
        emphasized: root.emphasized
        color: root.emphasized || root.pointerHovered || root.visualFocus ? root.colors.text : root.colors.subtext0
        horizontalAlignment: Text.AlignHCenter
        wholePixelCentering: true
    }

    background: Rectangle {
        color: root.pointerHovered || root.visualFocus ? root.colors.surface0 : "transparent"
        radius: root.cornerRadius
    }
}
