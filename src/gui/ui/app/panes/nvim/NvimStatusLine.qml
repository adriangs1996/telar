pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The status line of the whole editor, drawn by telar over the row Neovim draws it on: what the
// configuration puts there, lualine's or any other, in telar's type and on the editor's own
// surface. The line is flat: a row of one cell has no room for a shape around a word, so the
// sections a statusline draws on backgrounds of their own keep only their color and are parted
// by space; the icons are drawn with the bundled symbols, and the two sides keep the gap Neovim
// put between them. A line that opens with the name of the mode Neovim is in writes it in the
// theme's color for that mode.
Item {
    id: root

    // {visible, row, tokens [{text, color, bold, italic, icon, gap}], left and right
    // [{first, count}]}.
    required property var status
    // Neovim's name for its mode: "normal", "insert", "visual", "cmdline_normal"...
    property string mode
    required property var colors
    required property var typography
    required property real cellHeight
    property real ratio: 1
    readonly property var tokens: status.tokens ?? []
    // Between the line's edges and its words, and between two of its sections.
    readonly property real margin: 10 * ratio
    readonly property real sectionGap: 14 * ratio
    // Room the pane keeps on the line, before its last side, for what it writes there itself;
    // `reservedX` is where that room starts. The first side is cut before it.
    property real reserved: 0
    readonly property real reservedX: trailing.x - (trailing.width > 0 ? sectionGap : 0) - reserved
    // The first letter of the names statuslines give each mode, and the theme's color for it.
    readonly property var family: ({
            "normal": ["N", colors.accent],
            "insert": ["I", colors.green],
            "visual": ["V", colors.mauve],
            "visual_select": ["S", colors.mauve],
            "replace": ["R", colors.red],
            "cmdline_normal": ["C", colors.yellow],
            "cmdline_insert": ["C", colors.yellow],
            "cmdline_replace": ["C", colors.yellow],
            "operator": ["O", colors.peach],
            "terminal": ["T", colors.teal]
        })
    readonly property var modeFamily: family[mode] ?? null
    // The token that names the mode: the line's first, in capitals, of the mode's letter; -1 for
    // none.
    readonly property int modeToken: {
        const first = (status.left ?? [])[0];
        const token = tokens[0];

        if (!modeFamily || !first || first.first !== 0 || !token || token.icon)
            return -1;
        return /^[A-Z][A-Z-]{1,11}$/.test(token.text) && token.text[0] === modeFamily[0] ? 0 : -1;
    }

    visible: status.visible ?? false
    y: (status.row ?? 0) * cellHeight
    height: cellHeight

    // The editor's own surface, so the line is part of it and not a band of other cells.
    Rectangle {
        readonly property color base: root.colors.terminalBackground

        anchors.fill: parent
        color: Qt.rgba(base.r, base.g, base.b, 1)
    }

    Rectangle {
        width: parent.width
        height: 1
        color: root.colors.border
    }

    component Piece: Row {
        id: piece

        required property var record

        height: root.height

        Repeater {
            // A count, so a word that changes keeps its item and only its text is set again.
            model: piece.record.count ?? 0

            delegate: Item {
                id: word

                required property int index
                readonly property int at: piece.record.first + index
                readonly property var token: root.tokens[at] ?? ({})
                readonly property bool icon: token.icon ?? false
                readonly property bool moded: at === root.modeToken
                readonly property color tint: moded ? root.modeFamily[1] : (token.color ?? "").length > 0 ? token.color : root.colors.text
                // An icon goes with the word after it; words Neovim parted by more than one
                // blank cell are parted more.
                readonly property bool afterIcon: index > 0 && (root.tokens[at - 1]?.icon ?? false)
                readonly property int blanks: index > 0 ? token.gap ?? 0 : 0
                readonly property real lead: (blanks === 0 ? 0 : afterIcon ? 5 : blanks === 1 ? 5 : 12) * root.ratio

                width: lead + (icon ? glyph.width : label.implicitWidth)
                height: root.height

                ChromeIcon {
                    id: glyph
                    visible: word.icon
                    x: word.lead
                    y: Math.round((root.height - height) / 2)
                    width: visible ? Math.round(root.typography.small * 1.15) : 0
                    height: width
                    glyph: word.icon ? word.token.text : ""
                    pixelSize: width
                    color: word.tint
                }

                Text {
                    id: label
                    visible: !word.icon
                    x: word.lead
                    height: root.height
                    verticalAlignment: Text.AlignVCenter
                    text: word.icon ? "" : word.token.text ?? ""
                    color: word.tint
                    font.pixelSize: root.typography.small
                    font.weight: word.moded ? Font.DemiBold : (word.token.bold ?? false) ? Font.Bold : Font.Normal
                    font.italic: word.token.italic ?? false
                    font.letterSpacing: word.moded ? 0.6 * root.ratio : 0
                    textFormat: Text.PlainText
                }
            }
        }
    }

    // The side Neovim puts after its gap, at the line's end.
    Row {
        id: trailing
        objectName: "editorStatusRight"
        x: parent.width - width - root.margin
        height: root.height
        spacing: root.sectionGap

        Repeater {
            model: (root.status.right ?? []).length

            delegate: Piece {
                required property int index
                record: (root.status.right ?? [])[index] ?? ({})
            }
        }
    }

    // The first side, cut where it would run under the other, or under the room kept before it.
    Item {
        x: root.margin
        width: Math.max(0, (root.reserved > 0 ? root.reservedX : trailing.x) - x - root.sectionGap)
        height: root.height
        clip: true

        Row {
            objectName: "editorStatusLeft"
            height: root.height
            spacing: root.sectionGap

            Repeater {
                model: (root.status.left ?? []).length

                delegate: Piece {
                    required property int index
                    record: (root.status.left ?? [])[index] ?? ({})
                }
            }
        }
    }
}
