pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// Neovim's command line as a surface of telar's own: what is typed after `:`, a search or a
// prompt, with the caret where Neovim has it. Neovim edits the line; this only shows it.
Item {
    id: root

    // The editor's command line: visible, first, prompt, text, position, indent, level, block.
    required property var line
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property bool shown: line.visible ?? false
    readonly property string first: line.first ?? ""
    readonly property string leading: (line.prompt ?? "").length > 0 ? line.prompt : first
    readonly property bool searching: first === "/" || first === "?"
    readonly property var blockLines: (line.block ?? "").length > 0 ? line.block.replace(/\n$/, "").split("\n") : []
    readonly property real inset: 14 * ratio
    readonly property real rowHeight: 40 * ratio
    readonly property real footerHeight: 30 * ratio
    // The room the key that leaves the line takes at its end.
    readonly property real leaveWidth: 44 * ratio
    readonly property real cellWidth: typography.grid?.cellWidth ?? 8
    // The height of the editor's rows: the surface sits on a row's edge, so it never cuts a
    // line of text in half.
    property real cellHeight: 0
    readonly property real place: Math.min(parent.height * 0.16, parent.height - height - 16 * ratio)
    readonly property real rest: cellHeight > 0 ? Math.round(place / cellHeight) * cellHeight : Math.round(place)
    // Where a completion menu hangs from: under the character the caret is on.
    readonly property real caretX: field.x + caret.x
    property real reveal: shown ? 1 : 0

    width: Math.min(parent.width - 32 * ratio, 620 * ratio)
    height: rowHeight + blockColumn.height + footerHeight
    x: Math.round((parent.width - width) / 2)
    y: rest - (1 - reveal) * 8 * ratio
    opacity: reveal
    visible: reveal > 0

    Behavior on reveal {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    NvimSurface {
        anchors.fill: parent
        colors: root.colors
        ratio: root.ratio
    }

    // A function or a loop being typed: the lines above the one Neovim edits.
    Column {
        id: blockColumn
        x: root.inset
        y: root.blockLines.length > 0 ? 8 * root.ratio : 0
        width: root.width - 2 * root.inset

        Repeater {
            model: root.blockLines

            delegate: CellText {
                required property string modelData
                width: blockColumn.width
                height: 22 * root.ratio
                text: modelData
                grid: root.typography.grid
                color: root.colors.subtext0
                clip: true
            }
        }
    }

    Item {
        y: blockColumn.height
        width: root.width
        height: root.rowHeight

        // What opened the line stands as the key it was.
        Rectangle {
            x: root.inset - 7 * root.ratio
            y: Math.round((parent.height - height) / 2)
            width: Math.max(glass.width, lead.width) + 14 * root.ratio
            height: 24 * root.ratio
            radius: 6 * root.ratio
            color: Qt.alpha(root.colors.text, 0.07)
            border.width: Math.max(1, root.ratio) / Screen.devicePixelRatio
            border.color: Qt.alpha(root.colors.text, 0.14)
            visible: glass.visible || lead.visible
        }

        // What opened the line: a command's prompt or the search glass as icons, or the prompt
        // Neovim gave.
        ChromeIcon {
            id: glass
            x: root.inset
            width: visible ? 18 * root.ratio : 0
            height: parent.height
            glyph: root.searching ? "\uea6d" : "\uea85"
            pixelSize: root.typography.body
            color: root.colors.accent
            visible: (root.searching || root.first === ":") && (root.line.prompt ?? "").length === 0
        }

        CellText {
            id: lead
            x: root.inset
            height: parent.height
            width: visible ? implicitWidth : 0
            text: root.leading
            grid: root.typography.grid
            color: root.colors.accent
            bold: true
            visible: !glass.visible && root.leading.length > 0
        }

        Item {
            id: field
            x: root.inset + Math.max(glass.width, lead.width) + 18 * root.ratio + (root.line.indent ?? 0) * root.cellWidth
            width: Math.max(0, root.width - x - root.inset - root.leaveWidth)
            height: parent.height
            clip: true

            CellText {
                id: typed
                // The line follows its caret once it is longer than the field.
                x: Math.min(0, field.width - 2 * root.cellWidth - (root.line.position ?? 0) * root.cellWidth)
                height: parent.height
                width: implicitWidth
                text: root.line.text ?? ""
                grid: root.typography.grid
                color: root.colors.text
            }

            Rectangle {
                id: caret
                x: typed.x + (root.line.position ?? 0) * root.cellWidth
                y: Math.round((parent.height - height) / 2)
                width: Math.max(1.5 * root.ratio, 1)
                height: Math.round(18 * root.ratio)
                radius: width / 2
                color: root.colors.accent
            }
        }

        ChromeText {
            x: root.width - width - root.inset
            width: root.leaveWidth - 8 * root.ratio
            height: parent.height
            horizontalAlignment: Text.AlignRight
            text: "esc"
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, 0.45)
        }
    }

    KeyHintBar {
        y: root.height - root.footerHeight
        width: root.width
        height: root.footerHeight
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        hints: root.searching ? [] : [{keys: ["⇥"], word: "Complete"}]
        trailing: ({keys: ["↵"], word: root.searching ? "Search" : "Run"})
    }
}
