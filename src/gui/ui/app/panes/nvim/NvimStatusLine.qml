pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The status line of the whole editor, drawn by telar over the row Neovim draws it on: what the
// configuration puts there, lualine's or any other, in telar's type and on the editor's own
// surface. The cells on a background of their own become pills of that color, as lualine's
// sections are; the icons are drawn with the bundled symbols; the two sides keep the gap Neovim
// put between them. A line that opens with the name of the mode Neovim is in shows it as the
// mode's pill, in the theme's color for that mode, unless the line gives it a color of its own.
Item {
    id: root

    // {visible, row, tokens [{text, color, bold, italic, icon, gap}], left and right
    // [{first, count, background, pill}]}.
    required property var status
    // Neovim's name for its mode: "normal", "insert", "visual", "cmdline_normal"...
    property string mode
    required property var colors
    required property var typography
    required property real cellHeight
    property real ratio: 1
    readonly property var tokens: status.tokens ?? []
    readonly property real gap: 6 * ratio
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
    // The token that names the mode: the line's first, in capitals, of the mode's letter, on the
    // line's own background; -1 for none.
    readonly property int modeToken: {
        const first = (status.left ?? [])[0];
        const token = tokens[0];

        if (!modeFamily || !first || first.pill || first.first !== 0 || !token || token.icon)
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

    component Piece: Item {
        id: piece

        required property var record
        readonly property bool pill: record.pill ?? false
        readonly property real padding: (pill ? 9 : 3) * root.ratio

        width: words.implicitWidth + 2 * padding
        height: root.height

        NativeRoundedRectangle {
            visible: piece.pill
            y: Math.round((root.height - height) / 2)
            width: parent.width
            height: Math.min(root.height - 8 * root.ratio, Math.round(root.typography.small * 1.85))
            radius: ChromeStyle.controlRadius * root.ratio
            color: (piece.record.background ?? "").length > 0 ? piece.record.background : Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
        }

        Row {
            id: words
            x: piece.padding
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
                    readonly property real inset: moded ? 9 * root.ratio : 0

                    width: lead + (icon ? glyph.width : label.implicitWidth + 2 * inset)
                    height: root.height

                    // The mode's pill, when the line gives the mode no color of its own.
                    NativeRoundedRectangle {
                        visible: word.moded
                        x: word.lead
                        y: Math.round((root.height - height) / 2)
                        width: label.implicitWidth + 2 * word.inset
                        height: Math.min(root.height - 8 * root.ratio, Math.round(root.typography.small * 1.85))
                        radius: ChromeStyle.controlRadius * root.ratio
                        color: Qt.alpha(word.tint, 0.16)
                    }

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
                        x: word.lead + word.inset
                        height: root.height
                        verticalAlignment: Text.AlignVCenter
                        text: word.icon ? "" : word.token.text ?? ""
                        color: word.tint
                        font.pixelSize: root.typography.small
                        font.bold: word.moded || (word.token.bold ?? false)
                        font.italic: word.token.italic ?? false
                        textFormat: Text.PlainText
                    }
                }
            }
        }
    }

    // The side Neovim puts after its gap, at the line's end.
    Row {
        id: trailing
        objectName: "editorStatusRight"
        x: parent.width - width - root.gap
        height: root.height
        spacing: root.gap

        Repeater {
            model: (root.status.right ?? []).length

            delegate: Piece {
                required property int index
                record: (root.status.right ?? [])[index] ?? ({})
            }
        }
    }

    // The first side, cut where it would run under the other.
    Item {
        x: root.gap
        width: Math.max(0, trailing.x - x - root.gap)
        height: root.height
        clip: true

        Row {
            objectName: "editorStatusLeft"
            height: root.height
            spacing: root.gap

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
