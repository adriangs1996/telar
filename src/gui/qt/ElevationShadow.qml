pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The one soft shadow recipe, drawn behind whichever surface it fills.
Item {
    id: root

    property real ratio: 1
    property real cornerRadius: 0
    property int layers: 3
    property real step: 4 * ratio
    property real offset: 5 * ratio
    property real strength: 0.07

    Repeater {
        model: root.layers
        delegate: NativeRoundedRectangle {
            required property int index
            readonly property real spread: (root.layers - index) * root.step
            x: -spread
            y: -spread + root.offset
            width: root.width + spread * 2
            height: root.height + spread * 2
            radius: root.cornerRadius + spread
            color: Qt.rgba(0, 0, 0, root.strength)
        }
    }
}
