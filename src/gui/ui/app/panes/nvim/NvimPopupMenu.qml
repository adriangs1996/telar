pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// Neovim's completion menu as a list of telar's own: the word, what kind of thing it is as a
// chip, and its note, hung from the cell Neovim names. Neovim owns the selection; this shows
// the rows around it. The menu of the command line is part of the line's surface instead: it
// stands in the room the line docks it in, as tall rows that give a file or a folder its icon
// and keep the folder of a path quieter than its name.
Item {
    id: root

    // The editor's menu: visible, selected, first, total, items [{word, runs, kind, menu, icon,
    // iconTone}], x, y. An item's icon says its kind; its runs mark the letters typed of it.
    required property var menu
    required property var colors
    required property var typography
    property real ratio: 1
    // The cell the menu hangs from, in the parent's coordinates, and the cell's size.
    // An item was clicked: its place among the items the menu was sent.
    signal picked(int index)

    required property point anchor
    required property real cellHeight
    // Inside the command line's surface, in the room `dock` gives it, the chosen row in `tone`.
    property bool embedded: false
    property rect dock
    property color tone: colors.accent
    readonly property var items: menu.items ?? []
    readonly property int selected: (menu.selected ?? -1) - (menu.first ?? 0)
    readonly property bool shown: (menu.visible ?? false) && items.length > 0
    // What the selected item says of itself, shown beside the list.
    readonly property string info: (menu.info ?? "").trim()
    readonly property real infoWidth: Math.min(300 * ratio, parent.width * 0.4)
    readonly property bool infoRight: x + width + 6 * ratio + infoWidth <= parent.width - 8 * ratio
    readonly property int visibleRows: Math.min(items.length, embedded ? 8 : 10)
    readonly property real rowHeight: (embedded ? 32 : 26) * ratio
    // The column of the kinds' chips, kept for every row once one item says its kind.
    readonly property bool kinded: items.some(item => (item.kind ?? "").length > 0)
    // The height the menu takes, shown or not, which a command line makes room for.
    readonly property real fullHeight: visibleRows * rowHeight + 2 * padding
    readonly property real iconSide: Math.round(typography.body * 1.05)
    readonly property real chipWidth: 26 * ratio
    readonly property real padding: (embedded ? 6 : 4) * ratio
    // The first row shown: the selection is kept in view.
    readonly property int firstRow: Math.max(0, Math.min(items.length - visibleRows, selected - Math.floor(visibleRows / 2)))
    readonly property bool above: !embedded && anchor.y + cellHeight + height + 8 * ratio > parent.height && anchor.y - height > 0
    property real reveal: shown ? 1 : 0

    // A word's pieces as drawn: the letters typed in the tone, and the folder of a path before
    // its name quieter, when the menu is the command line's.
    function pieces(item, chosen) {
        const runs = item.runs ?? [{text: item.word ?? "", matched: false}];
        const word = item.word ?? "";
        const slash = embedded ? word.replace(/\/$/, "").lastIndexOf("/") + 1 : 0;
        const kept = [];
        let at = 0;

        for (const run of runs) {
            const cut = Math.max(0, Math.min(run.text.length, slash - at));
            const parts = cut > 0 && cut < run.text.length ? [run.text.slice(0, cut), run.text.slice(cut)] : [run.text];

            for (const part of parts) {
                const folder = at < slash;
                const color = run.matched ? (embedded ? tone : colors.text) : folder ? Qt.alpha(colors.text, 0.42) : chosen ? colors.text : colors.subtext0;

                kept.push({text: part, matched: run.matched, color: color});
                at += part.length;
            }
        }

        return kept;
    }

    width: embedded ? dock.width : Math.min(parent.width - 16 * ratio, 420 * ratio)
    height: fullHeight
    x: embedded ? dock.x : Math.round(Math.max(8 * ratio, Math.min(anchor.x - 10 * ratio, parent.width - width - 8 * ratio)))
    y: embedded ? dock.y : Math.round(above ? anchor.y - height - 4 * ratio : anchor.y + cellHeight + 4 * ratio)
    opacity: reveal
    visible: reveal > 0

    Behavior on reveal {
        NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
    }

    NvimSurface {
        anchors.fill: parent
        colors: root.colors
        ratio: root.ratio
        visible: !root.embedded
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
                readonly property color tone: root.colors[item.iconTone ?? "accent"] ?? root.colors.accent

                y: index * root.rowHeight
                width: parent.width
                height: root.rowHeight

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: ChromeStyle.controlRadius * root.ratio
                    color: root.embedded && row.chosen ? Qt.alpha(root.tone, 0.16) : Qt.alpha(root.colors.text, row.chosen ? ChromeStyle.selectionAlpha : ChromeStyle.selectionAlpha / 2)
                    visible: row.chosen || pointer.containsMouse
                }

                // On the command line a kind is its icon alone, in the row's color.
                ChromeIcon {
                    x: 10 * root.ratio
                    width: Math.round(root.typography.body * 1.05)
                    height: parent.height
                    glyph: row.item.icon ?? ""
                    pixelSize: width
                    color: row.chosen ? root.tone : Qt.alpha(root.colors.subtext0, 0.85)
                    visible: root.embedded && glyph.length > 0
                }

                ActionPointer {
                    id: pointer
                    anchors.fill: parent
                    identity: String(row.itemIndex)
                    onActivated: root.picked(row.itemIndex)
                }

                // What kind of thing the word is, first, as a chip in the kind's color: its icon, or
                // its name when telar has no icon for it.
                Item {
                    id: kindChip
                    readonly property string label: row.item.kind ?? ""
                    readonly property bool iconed: (row.item.icon ?? "").length > 0
                    x: 6 * root.ratio
                    y: Math.round((parent.height - height) / 2)
                    width: root.chipWidth
                    height: 18 * root.ratio
                    visible: label.length > 0 && !root.embedded

                    NativeRoundedRectangle {
                        anchors.fill: parent
                        radius: ChromeStyle.smallRadius * root.ratio
                        color: Qt.alpha(row.tone, 0.16)
                    }

                    ChromeIcon {
                        anchors.centerIn: parent
                        width: root.iconSide
                        height: root.iconSide
                        glyph: row.item.icon ?? ""
                        pixelSize: root.iconSide
                        color: row.tone
                        visible: kindChip.iconed
                    }

                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 4 * root.ratio
                        horizontalAlignment: Text.AlignHCenter
                        text: kindChip.label
                        color: row.tone
                        font.pixelSize: root.typography.small
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        visible: !kindChip.iconed
                    }
                }

                // The word, the letters of it that were typed marked.
                Row {
                    id: word
                    x: root.embedded ? (root.kinded ? 20 * root.ratio + Math.round(root.typography.body * 1.05) : 12 * root.ratio) : root.kinded ? 14 * root.ratio + root.chipWidth : 8 * root.ratio
                    height: parent.height
                    width: Math.min(implicitWidth, Math.max(0, parent.width - x - detail.implicitWidth - 20 * root.ratio))
                    clip: true

                    Repeater {
                        model: root.pieces(row.item, row.chosen)

                        delegate: CellText {
                            required property var modelData
                            height: word.height
                            text: modelData.text
                            grid: root.typography.grid
                            bold: modelData.matched
                            color: modelData.color
                        }
                    }
                }

                // What the item adds of itself, as its type, at the row's end.
                ChromeText {
                    id: detail
                    x: Math.max(word.x + word.width + 12 * root.ratio, parent.width - width - 10 * root.ratio)
                    width: Math.min(implicitWidth, Math.max(0, parent.width - word.x - word.width - 22 * root.ratio))
                    height: parent.height
                    text: row.item.menu ?? ""
                    pixelSize: root.typography.small
                    color: Qt.alpha(root.colors.text, 0.5)
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

    // The documentation of the item selected: beside the list, on the side that has room.
    Item {
        x: root.infoRight ? root.width + 6 * root.ratio : -width - 6 * root.ratio
        width: root.infoWidth
        height: Math.min(note.implicitHeight + 20 * root.ratio, 260 * root.ratio)
        visible: root.shown && root.info.length > 0 && (root.infoRight || root.x - width - 6 * root.ratio >= 8 * root.ratio)

        NvimSurface {
            anchors.fill: parent
            colors: root.colors
            ratio: root.ratio
        }

        Text {
            id: note
            x: 12 * root.ratio
            y: 10 * root.ratio
            width: parent.width - 24 * root.ratio
            height: parent.height - 20 * root.ratio
            text: root.info
            color: root.colors.subtext0
            font.pixelSize: root.typography.small
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            clip: true
            lineHeight: 1.25
        }
    }
}
