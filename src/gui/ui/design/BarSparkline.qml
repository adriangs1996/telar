pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var samples
    required property color color
    required property color trackColor
    property real ratio: 1

    // The top bar's sparkline unless a host asks for a larger one.
    property int maximumColumns: 9
    property real columnWidth: 2 * ratio
    property real columnGap: 1 * ratio
    property real chartHeight: 12 * ratio
    // A function from a sample to its column's color; every column takes `color` without one.
    property var columnColor: null
    // The columns before the first sample show as empty tracks, so a history that is still short
    // reads as one.
    property bool showEmpty: false
    readonly property real minimumColumnHeight: 2 * ratio
    readonly property real fullPercent: 100
    readonly property real density: Screen.devicePixelRatio
    readonly property int shownColumns: Math.min(samples.length, maximumColumns)
    readonly property int firstSample: samples.length - shownColumns
    readonly property int columns: showEmpty ? maximumColumns : shownColumns
    readonly property int emptyColumns: columns - shownColumns

    implicitWidth: columns > 0 ? columns * columnWidth + (columns - 1) * columnGap : 0

    Repeater {
        model: root.columns

        delegate: Item {
            id: column

            required property int index
            readonly property bool empty: index < root.emptyColumns
            readonly property real sample: empty ? 0 : root.samples[root.firstSample + index - root.emptyColumns]
            readonly property real fillHeight: Math.max(root.minimumColumnHeight, Math.round(root.chartHeight * root.density * sample / root.fullPercent) / root.density)

            x: index * (root.columnWidth + root.columnGap)
            y: (root.height - root.chartHeight) / 2
            width: root.columnWidth
            height: root.chartHeight

            NativeRoundedRectangle {
                anchors.fill: parent
                radius: root.columnWidth / 4
                color: root.trackColor
                opacity: column.empty ? 0.5 : 1
            }

            NativeRoundedRectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: column.fillHeight
                radius: root.columnWidth / 4
                color: root.columnColor ? root.columnColor(column.sample) : root.color
                visible: !column.empty
            }
        }
    }
}
