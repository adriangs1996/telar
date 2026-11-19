pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// A floating overlay's surface. On dark themes a soft shadow barely shows, so a dark hairline
// outside the edge and a light one inside it separate the surface from whatever is below.
Item {
    id: root

    required property var colors
    property real ratio: 1
    readonly property real cornerRadius: ChromeStyle.dialogRadius * ratio
    readonly property real outlineAlpha: ChromeStyle.outlineAlpha
    readonly property real hairline: 1 / Screen.devicePixelRatio
    readonly property real ringAlpha: 0.45

    ElevationShadow {
        anchors.fill: parent
        ratio: root.ratio
        cornerRadius: root.cornerRadius
        layers: 4
        step: 3 * root.ratio
        offset: 6 * root.ratio
        strength: 0.06
    }

    NativeRoundedRectangle {
        x: -root.hairline
        y: -root.hairline
        width: root.width + 2 * root.hairline
        height: root.height + 2 * root.hairline
        color: Qt.rgba(0, 0, 0, root.ringAlpha)
        radius: root.cornerRadius + root.hairline
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
        borderWidth: root.hairline
        borderColor: root.colors.text
        borderAlpha: root.outlineAlpha
    }
}
