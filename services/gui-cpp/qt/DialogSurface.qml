pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var colors
    property real ratio: 1
    readonly property real cornerRadius: ChromeStyle.dialogRadius * ratio
    readonly property real outlineAlpha: ChromeStyle.outlineAlpha

    ElevationShadow {
        anchors.fill: parent
        ratio: root.ratio
        cornerRadius: root.cornerRadius
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        color: root.colors.panel_bg
        radius: root.cornerRadius
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        color: "transparent"
        radius: root.cornerRadius
        borderWidth: 1 / Screen.devicePixelRatio
        borderColor: root.colors.text
        borderAlpha: root.outlineAlpha
    }
}
