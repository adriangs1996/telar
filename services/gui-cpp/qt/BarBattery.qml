pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property real percent
    required property color outlineColor
    required property color fillColor
    property real ratio: 1

    readonly property real bodyWidth: 15 * ratio
    readonly property real bodyHeight: 10 * ratio
    readonly property real tipWidth: 2 * ratio
    readonly property real outlineWidth: 1 * ratio
    readonly property real outlineRadius: 2.5 * ratio
    readonly property real fillInset: 2 * ratio
    readonly property real fillRadius: 1.2 * ratio
    readonly property real capTop: 0.3
    readonly property real capHeight: 0.4
    readonly property real capWidth: 0.75
    readonly property real fullPercent: 100
    readonly property real density: Screen.devicePixelRatio

    implicitWidth: bodyWidth + tipWidth

    Item {
        id: body

        y: Math.round((root.height - root.bodyHeight) * root.density / 2) / root.density
        width: root.bodyWidth
        height: root.bodyHeight

        NativeRoundedRectangle {
            anchors.fill: parent
            radius: root.outlineRadius
            color: "transparent"
            borderWidth: root.outlineWidth
            borderColor: root.outlineColor
        }

        NativeRoundedRectangle {
            x: body.width
            y: body.height * root.capTop
            width: root.tipWidth * root.capWidth
            height: body.height * root.capHeight
            radius: width / 2
            color: root.outlineColor
        }

        NativeRoundedRectangle {
            x: root.fillInset
            y: root.fillInset
            width: Math.max(root.outlineWidth, (body.width - 2 * root.fillInset) * root.percent / root.fullPercent)
            height: body.height - 2 * root.fillInset
            radius: root.fillRadius
            color: root.fillColor
            visible: root.percent > 0
        }
    }
}
