pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// An editor pane: a Neovim the runtime runs, each of its grids drawn natively where Neovim
// places it. A float gets the surface, the shadow and the entrance of telar's own dialogs,
// in place of a border made of characters.
NvimEditor {
    id: root

    required property var colors
    required property var typography
    property real ratio: 1
    // How far a float's surface reaches past its cells.
    readonly property real floatInset: 6 * ratio

    Repeater {
        model: root.grids

        delegate: Item {
            id: cell

            required property var record
            readonly property bool floating: record.kind === "float"
            // A float comes in as a dialog does: a short fade and a rise of a few units.
            property real reveal: floating ? 0 : 1

            x: record.x
            y: record.y + (1 - reveal) * 6 * root.ratio
            z: record.layer
            width: record.width
            height: record.height
            opacity: reveal

            NumberAnimation on reveal {
                running: cell.floating
                to: 1
                duration: 140
                easing.type: Easing.OutCubic
            }

            DialogSurface {
                visible: cell.floating
                x: -root.floatInset
                y: -root.floatInset
                width: cell.width + 2 * root.floatInset
                height: cell.height + 2 * root.floatInset
                colors: root.colors
                ratio: root.ratio
            }

            NvimGrid {
                anchors.fill: parent
                editor: root
                gridId: cell.record.gridId
            }
        }
    }
}
