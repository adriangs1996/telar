pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var samples
    required property color color
    required property color trackColor
    property real ratio: 1

    readonly property int maximumColumns: 9
    readonly property real columnWidth: 2 * ratio
    readonly property real columnGap: 1 * ratio
    readonly property real chartHeight: 12 * ratio
    readonly property real minimumColumnHeight: 2 * ratio
    readonly property real fullPercent: 100
    readonly property real density: Screen.devicePixelRatio
    readonly property int shownColumns: Math.min(samples.length, maximumColumns)
    readonly property int firstSample: samples.length - shownColumns

    implicitWidth: shownColumns > 0 ? shownColumns * columnWidth + (shownColumns - 1) * columnGap : 0

    Repeater {
        model: root.shownColumns

        delegate: Item {
            id: column

            required property int index
            readonly property real fillHeight: Math.max(root.minimumColumnHeight, Math.round(root.chartHeight * root.density * root.samples[root.firstSample + index] / root.fullPercent) / root.density)

            x: index * (root.columnWidth + root.columnGap)
            y: (root.height - root.chartHeight) / 2
            width: root.columnWidth
            height: root.chartHeight

            NativeRoundedRectangle {
                anchors.fill: parent
                radius: root.columnWidth / 4
                color: root.trackColor
            }

            NativeRoundedRectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: column.fillHeight
                radius: root.columnWidth / 4
                color: root.color
            }
        }
    }
}
