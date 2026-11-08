import QtQuick
import QtQuick.Controls
import Telar.Gui

AbstractButton {
    id: root

    required property var colors
    required property real pixelSize
    property real cornerRadius: ChromeStyle.controlRadius
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
        color: root.colors.chromeText ?? root.colors.text
        opacity: root.enabled ? 1 : 0.45
        horizontalAlignment: Text.AlignHCenter
        wholePixelCentering: true
    }

    background: NativeRoundedRectangle {
        color: Qt.alpha(root.colors.text, root.down ? ChromeStyle.selectionAlpha : root.pointerHovered || root.visualFocus ? ChromeStyle.hoverAlpha : 0)
        radius: root.cornerRadius
        borderColor: root.colors.accent
        borderAlpha: ChromeStyle.focusAlpha
        borderWidth: root.visualFocus ? 1 / Screen.devicePixelRatio : 0
    }
}
