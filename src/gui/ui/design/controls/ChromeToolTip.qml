import QtQuick
import QtQuick.Controls
import Telar.Gui

// A plain-text hint that appears once the pointer rests on its parent.
ToolTip {
    id: root

    required property var colors
    required property var typography
    property real ratio: 1

    delay: 500
    contentItem: Text {
        text: root.text
        textFormat: Text.PlainText
        color: root.colors.text
        font.pixelSize: root.typography.small
    }
    background: NativeRoundedRectangle {
        radius: ChromeStyle.controlRadius * root.ratio
        color: root.colors.panel_bg
        borderColor: root.colors.text
        borderAlpha: ChromeStyle.outlineAlpha
        borderWidth: 1 / Screen.devicePixelRatio
    }
}
