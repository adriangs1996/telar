pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// Neovim's command line as a surface of telar's own: what is typed after `:`, a search or a
// prompt, with the caret where Neovim has it. Neovim edits the line; this only shows it.
//
// The line names what is being written as a mode: a command, a search, a shell command, Lua,
// help, an expression or the question of a prompt. Each has its label, its icon and its color,
// which tints the edge, the caret and the completion chosen, and the keys that leave it say what
// they do. The prefix that opens a mode, as `lua ` or `!`, is hidden while the caret is past
// it: the label says it.
Item {
    id: root

    // The editor's command line: visible, first, prompt, text, runs, position, indent, level,
    // block.
    required property var line
    required property var colors
    required property var typography
    property real ratio: 1
    // The room the completion menu takes inside the surface while it completes this line, and
    // whether one of its items is chosen.
    property real menuHeight: 0
    property bool menuChosen: false
    readonly property bool shown: line.visible ?? false
    readonly property string first: line.first ?? ""
    readonly property string prompt: (line.prompt ?? "").trim()
    readonly property string written: line.text ?? ""
    readonly property int caretAt: line.position ?? 0
    readonly property var blockLines: (line.block ?? "").length > 0 ? line.block.replace(/\n$/, "").split("\n") : []
    readonly property var mode: modeOf(first, prompt, written)
    // The characters of the prefix hidden: none while the caret is in it.
    readonly property int hidden: caretAt >= mode.prefix ? mode.prefix : 0
    readonly property color tone: mode.tone
    readonly property real inset: 16 * ratio
    readonly property real inputHeight: 52 * ratio
    readonly property real footerHeight: 34 * ratio
    // Where the completion menu stands in the surface.
    readonly property real menuTop: blockColumn.height + inputHeight
    readonly property real cellWidth: typography.grid?.cellWidth ?? 8
    // The height of the editor's rows: the surface sits on a row's edge, so it never cuts a
    // line of text in half.
    property real cellHeight: 0
    readonly property real place: Math.min(parent.height * 0.16, parent.height - height - 16 * ratio)
    readonly property real rest: cellHeight > 0 ? Math.round(place / cellHeight) * cellHeight : Math.round(place)
    property real reveal: shown ? 1 : 0

    // What is being written, by what opened the line and how its text starts: the modes of
    // noice.nvim, which telar's window replaces.
    function modeOf(first, prompt, text) {
        const make = (label, glyph, tone, prefix, run) => ({label: label, glyph: glyph, tone: tone, prefix: prefix, run: run});

        if (first === "/" || first === "?")
            return make(first === "/" ? "Search ↓" : "Search ↑", "\uea6d", root.colors.yellow, 0, "Search");
        if (first === "=")
            return make("Expression", "\ueb64", root.colors.peach, 0, "Evaluate");
        if (first !== ":")
            return make(prompt.replace(/[:?]\s*$/, "").trim() || "Input", "\uea73", root.colors.peach, 0, "Accept");

        let found = /^\s*!/.exec(text);
        if (found)
            return make("Shell", "\uebc4", root.colors.green, found[0].length, "Run in shell");
        found = /^\s*(lua\s*=\s*|lua\s+|=\s*)/.exec(text);
        if (found)
            return make("Lua", "\udb82\udcb1", root.colors.teal, found[0].length, "Run Lua");
        found = /^\s*he?l?p?\s+/.exec(text);
        if (found)
            return make("Help", "\ueb32", root.colors.mauve, found[0].length, "Open help");
        return make("Command", "\uea85", root.colors.accent, 0, "Run");
    }

    // The runs of the text after the hidden prefix.
    function shownRuns(runs, text, hidden) {
        const all = runs.length > 0 ? runs : [{text: text, color: "", bold: false}];
        let skip = hidden;
        const kept = [];

        for (const run of all) {
            if (skip >= run.text.length) {
                skip -= run.text.length;
                continue;
            }

            kept.push({text: run.text.slice(skip), color: run.color, bold: run.bold});
            skip = 0;
        }

        return kept;
    }

    width: Math.min(parent.width - 32 * ratio, 640 * ratio)
    height: blockColumn.height + inputHeight + menuHeight + footerHeight
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
        tint: root.tone
    }

    // A function or a loop being typed: the lines above the one Neovim edits.
    Column {
        id: blockColumn
        x: root.inset
        y: root.blockLines.length > 0 ? 10 * root.ratio : 0
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
        id: input
        y: blockColumn.height
        width: root.width
        height: root.inputHeight

        // What is being written, as a chip in the mode's color.
        Rectangle {
            id: chip
            objectName: "cmdlineMode"
            readonly property string label: root.mode.label
            x: root.inset - 4 * root.ratio
            y: Math.round((parent.height - height) / 2)
            width: Math.min(chipRow.implicitWidth + 18 * root.ratio, root.width * 0.42)
            height: 26 * root.ratio
            radius: 7 * root.ratio
            color: Qt.alpha(root.tone, 0.14)

            Row {
                id: chipRow
                x: 8 * root.ratio
                height: parent.height
                spacing: 7 * root.ratio

                ChromeIcon {
                    width: Math.round(root.typography.body * 1.05)
                    height: parent.height
                    glyph: root.mode.glyph
                    pixelSize: width
                    color: root.tone
                }

                ChromeText {
                    width: Math.min(implicitWidth, chip.width - x - 10 * root.ratio)
                    height: parent.height
                    text: root.mode.label
                    pixelSize: root.typography.small
                    emphasized: true
                    color: root.tone
                }
            }
        }

        Item {
            id: field
            x: chip.x + chip.width + 12 * root.ratio + (root.line.indent ?? 0) * root.cellWidth
            width: Math.max(0, leaveKey.x - x - 12 * root.ratio)
            height: parent.height
            clip: true

            // The line as it is colored, run after run, after its hidden prefix.
            Row {
                id: typed
                // The line follows its caret once it is longer than the field.
                x: Math.min(0, field.width - 2 * root.cellWidth - (root.caretAt - root.hidden) * root.cellWidth)
                height: parent.height

                Repeater {
                    model: root.shownRuns(root.line.runs ?? [], root.written, root.hidden)

                    delegate: CellText {
                        required property var modelData
                        height: typed.height
                        text: modelData.text
                        grid: root.typography.grid
                        bold: modelData.bold ?? false
                        color: (modelData.color ?? "").length > 0 ? modelData.color : root.colors.text
                    }
                }
            }

            Rectangle {
                id: caret
                x: typed.x + (root.caretAt - root.hidden) * root.cellWidth
                y: Math.round((parent.height - height) / 2)
                width: Math.max(2 * root.ratio, 1)
                height: Math.round(20 * root.ratio)
                radius: width / 2
                color: root.tone
            }
        }

        ChromeText {
            id: leaveKey
            x: root.width - width - root.inset
            width: implicitWidth
            height: parent.height
            text: "esc"
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, 0.4)
        }
    }

    Rectangle {
        y: root.menuTop
        width: root.width
        height: Math.max(1, root.ratio) / Screen.devicePixelRatio
        color: Qt.alpha(root.colors.text, 0.08)
        visible: root.menuHeight > 0
    }

    KeyHintBar {
        y: root.height - root.footerHeight
        width: root.width
        height: root.footerHeight
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        hints: root.menuChosen ? [{keys: ["⇥"], word: "Next"}, {keys: ["⇧⇥"], word: "Previous"}]
            : root.first === "/" || root.first === "?" ? [{keys: ["⌃G"], word: "Next match"}, {keys: ["⌃T"], word: "Previous"}]
            : root.first === ":" ? [{keys: ["⇥"], word: "Complete"}] : []
        trailing: ({keys: ["↵"], word: root.mode.run})
    }
}
