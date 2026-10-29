pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var colors
    property real ratio: 1
    readonly property int shadowLayers: 3
    readonly property real shadowStep: 4 * ratio
    readonly property real shadowOffset: 5 * ratio
    readonly property real shadowAlpha: 0.07
    readonly property real cornerRadius: 12 * ratio
    readonly property real outlineAlpha: 0.09

    Repeater {
        model: root.shadowLayers
        delegate: NativeRoundedRectangle {
            required property int index
            readonly property real spread: (root.shadowLayers - index) * root.shadowStep
            x: -spread
            y: -spread + root.shadowOffset
            width: root.width + spread * 2
            height: root.height + spread * 2
            radius: root.cornerRadius + spread
            color: Qt.rgba(0, 0, 0, root.shadowAlpha)
        }
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
        borderWidth: root.ratio
        borderColor: Qt.alpha(root.colors.text, root.outlineAlpha)
    }
}
