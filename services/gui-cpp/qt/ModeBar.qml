pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

NativeModeLayout {
    id: root

    required property var colors

    NativeRoundedRectangle {
        x: root.chip.x
        y: root.chip.y
        width: root.chip.width
        height: root.chip.height
        radius: root.chipRadius
        color: root.colors.accent
    }

    Repeater {
        model: root.labels

        delegate: CellText {
            required property var modelData

            x: modelData.bounds.x
            y: modelData.bounds.y
            width: modelData.bounds.width
            height: modelData.bounds.height
            text: modelData.text
            grid: root.grid
            color: root.colors[modelData.ink]
            bold: modelData.bold
        }
    }
}
