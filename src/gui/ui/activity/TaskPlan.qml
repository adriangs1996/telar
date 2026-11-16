pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var record
    required property var colors
    required property var typography
    required property var geometry
    readonly property real cellsWidth: record.planCells * (geometry.planCellWidth + geometry.planCellGap)

    implicitWidth: cellsWidth + geometry.planCellGap + countLabel.implicitWidth + geometry.gap

    Repeater {
        model: root.record.planCells

        NativeRoundedRectangle {
            objectName: "taskPlanCell"
            required property int index
            x: index * (root.geometry.planCellWidth + root.geometry.planCellGap)
            y: (root.height - height) / 2
            width: root.geometry.planCellWidth
            height: root.geometry.planCellHeight
            radius: height / 2
            color: index < root.record.planFilled ? root.colors.teal : root.colors.surface1
        }
    }

    ChromeText {
        id: countLabel
        objectName: "taskPlanCount"
        x: root.cellsWidth + root.geometry.planCellGap
        width: implicitWidth
        height: root.height
        text: root.record.planCount
        color: root.colors.subtext0
        pixelSize: root.typography.small
        elide: Text.ElideNone
    }
}
