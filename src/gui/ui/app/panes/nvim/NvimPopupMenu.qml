pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// Neovim's completion menu as a list of telar's own: the word, what kind of thing it is as a
// chip, and its note, hung from the cell Neovim names. Neovim owns the selection; this shows
// the rows around it.
Item {
    id: root

    // The editor's menu: visible, selected, first, total, items [{word, kind, menu}], x, y.
    required property var menu
    required property var colors
    required property var typography
    property real ratio: 1
    // The cell the menu hangs from, in the parent's coordinates, and the cell's size.
    required property point anchor
    required property real cellHeight
    readonly property var items: menu.items ?? []
    readonly property int selected: (menu.selected ?? -1) - (menu.first ?? 0)
    readonly property bool shown: (menu.visible ?? false) && items.length > 0
    readonly property int visibleRows: Math.min(items.length, 10)
    readonly property real rowHeight: 26 * ratio
    readonly property real padding: 4 * ratio
    // The first row shown: the selection is kept in view.
    readonly property int firstRow: Math.max(0, Math.min(items.length - visibleRows, selected - Math.floor(visibleRows / 2)))
    readonly property bool above: anchor.y + cellHeight + height + 8 * ratio > parent.height && anchor.y - height > 0
    property real reveal: shown ? 1 : 0

    width: Math.min(parent.width - 16 * ratio, 420 * ratio)
    height: visibleRows * rowHeight + 2 * padding
    x: Math.round(Math.max(8 * ratio, Math.min(anchor.x - 10 * ratio, parent.width - width - 8 * ratio)))
    y: Math.round(above ? anchor.y - height - 4 * ratio : anchor.y + cellHeight + 4 * ratio)
    opacity: reveal
    visible: reveal > 0

    Behavior on reveal {
        NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
    }

    NvimSurface {
        anchors.fill: parent
        colors: root.colors
        ratio: root.ratio
    }

    Item {
        x: root.padding
        y: root.padding
        width: root.width - 2 * root.padding
        height: root.visibleRows * root.rowHeight
        clip: true

        Repeater {
            model: root.visibleRows

            delegate: Item {
                id: row

                required property int index
                readonly property int itemIndex: root.firstRow + index
                readonly property var item: root.items[itemIndex] ?? ({})
                readonly property bool chosen: itemIndex === root.selected

                y: index * root.rowHeight
                width: parent.width
                height: root.rowHeight

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: ChromeStyle.controlRadius * root.ratio
                    color: Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
                    visible: row.chosen
                }

                CellText {
                    id: word
                    x: 8 * root.ratio
                    height: parent.height
                    width: Math.min(implicitWidth, Math.max(0, parent.width - x - kindChip.width - 16 * root.ratio))
                    text: row.item.word ?? ""
                    grid: root.typography.grid
                    color: row.chosen ? root.colors.text : root.colors.subtext0
                    clip: true
                }

                ChromeText {
                    x: word.x + word.width + 12 * root.ratio
                    width: Math.max(0, kindChip.x - x - 8 * root.ratio)
                    height: parent.height
                    text: row.item.menu ?? ""
                    pixelSize: root.typography.small
                    color: Qt.alpha(root.colors.text, 0.5)
                }

                // What kind of thing the word is: a function, a field, a snippet.
                Item {
                    id: kindChip
                    readonly property string label: row.item.kind ?? ""
                    visible: label.length > 0
                    width: visible ? kindLabel.implicitWidth + 12 * root.ratio : 0
                    height: 18 * root.ratio
                    x: parent.width - width - 6 * root.ratio
                    y: Math.round((parent.height - height) / 2)

                    NativeRoundedRectangle {
                        anchors.fill: parent
                        radius: ChromeStyle.smallRadius * root.ratio
                        color: Qt.alpha(root.colors.accent, 0.14)
                    }

                    Text {
                        id: kindLabel
                        anchors.centerIn: parent
                        text: kindChip.label
                        color: root.colors.accent
                        font.pixelSize: root.typography.small
                        textFormat: Text.PlainText
                    }
                }
            }
        }
    }

    // How far down a long menu the rows shown are.
    Rectangle {
        visible: root.items.length > root.visibleRows
        x: root.width - 3 * root.ratio - width
        width: 2 * root.ratio
        radius: width / 2
        color: Qt.alpha(root.colors.text, 0.25)
        height: Math.max(12 * root.ratio, (root.height - 2 * root.padding) * root.visibleRows / Math.max(1, root.items.length))
        y: root.padding + (root.height - 2 * root.padding - height) * (root.firstRow / Math.max(1, root.items.length - root.visibleRows))
    }
}
