pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// An editor pane: a Neovim the runtime runs, each of its grids drawn natively where Neovim
// places it. What a terminal would draw with characters is drawn here with telar's own
// surfaces: floats, the command line, the completion menu, the messages, the tabs and what
// vim.ui asks.
FocusScope {
    id: root

    required property NvimController controller
    required property string paneId
    required property var colors
    required property var typography
    property real ratio: 1
    // How far a float's surface reaches past its cells.
    readonly property real floatInset: 6 * ratio
    readonly property alias editor: view
    // A button was pressed on the editor: its pane takes the focus.
    signal pressed()

    NvimTabline {
        id: tabs
        width: parent.width
        tabline: view.tabline
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        // Without entering the command line, which would flash its surface.
        onChosen: index => view.send("<Cmd>tabnext " + index + "<CR>")
        onClosed: index => view.send("<Cmd>" + index + "tabclose<CR>")
        onAdded: view.send("<Cmd>tabnew<CR>")
    }

    NvimEditor {
        id: view
        objectName: "paneEditor"
        y: tabs.height
        width: parent.width
        height: parent.height - tabs.height
        focus: true
        controller: root.controller
        paneId: root.paneId
        onPressed: root.pressed()

        Repeater {
            model: view.grids

            delegate: Item {
                id: cell

                required property var record
                readonly property bool floating: record.kind === "float"
                readonly property bool windowed: record.kind === "window"
                readonly property bool preview: record.preview ?? false
                // The room the picker leaves its preview, which the preview never draws past:
                // not while a new size is on its way to Neovim, nor while the picker moves.
                readonly property rect room: preview ? pick.previewArea : Qt.rect(0, 0, 0, 0)
                // A float comes in as a dialog does: a short fade and a rise of a few units. The
                // preview comes with its picker instead.
                property real reveal: floating && !preview ? 0 : 1

                x: record.x
                y: record.y + (1 - reveal) * 6 * root.ratio
                // The picker's preview is a float of Neovim's, drawn over the picker's surface.
                z: preview ? 995 : record.layer
                width: record.width
                height: record.height
                opacity: reveal

                NumberAnimation on reveal {
                    running: cell.floating && !cell.preview
                    to: 1
                    duration: 140
                    easing.type: Easing.OutCubic
                }

                // Neovim draws a window over whatever the grid under it holds: the window hides
                // it, as the pane's own background would.
                Rectangle {
                    readonly property color base: root.colors.terminalBackground

                    anchors.fill: parent
                    visible: !cell.floating && cell.record.kind !== "base"
                    color: Qt.rgba(base.r, base.g, base.b, 1)
                }

                // The sides of a float Neovim borders with characters: the window frames it
                // itself, and writes its title and its footer where those rows were.
                readonly property int border: floating ? (record.border ?? 0) : 0
                readonly property real cutTop: (border & 1) ? view.cellHeight : 0
                readonly property real cutRight: (border & 2) ? view.cellWidth : 0
                readonly property real cutBottom: (border & 4) ? view.cellHeight : 0
                readonly property real cutLeft: (border & 8) ? view.cellWidth : 0
                // A float without a border of its own gets room around its cells.
                readonly property real inset: border === 0 ? root.floatInset : 0

                NvimSurface {
                    visible: cell.floating && !cell.preview
                    x: -cell.inset
                    y: -cell.inset
                    width: cell.width + 2 * cell.inset
                    height: cell.height + 2 * cell.inset
                    colors: root.colors
                    ratio: root.ratio
                }

                Item {
                    id: shown

                    x: cell.preview ? Math.max(0, cell.room.x - cell.x) : cell.cutLeft
                    y: cell.preview ? Math.max(0, cell.room.y - cell.y) : cell.cutTop
                    width: Math.max(0, (cell.preview ? Math.min(cell.width, cell.room.x + cell.room.width - cell.x) : cell.width - cell.cutRight) - x)
                    height: Math.max(0, (cell.preview ? Math.min(cell.height, cell.room.y + cell.room.height - cell.y) : cell.height - cell.cutBottom) - y)
                    clip: cell.border !== 0 || cell.preview

                    NvimGrid {
                        x: -shown.x
                        y: -shown.y
                        width: cell.width
                        height: cell.height
                        editor: view
                        gridId: cell.record.gridId
                    }

                    // A line longer than the preview fades out at its edge, rather than stop in
                    // the middle of a word against the picker's border.
                    Rectangle {
                        id: fade

                        readonly property color base: root.colors.terminalBackground

                        visible: cell.preview
                        x: parent.width - width
                        width: Math.min(parent.width / 4, 3 * view.cellWidth)
                        height: parent.height
                        gradient: Gradient {
                            orientation: Gradient.Horizontal

                            GradientStop {
                                position: 0
                                color: Qt.rgba(fade.base.r, fade.base.g, fade.base.b, 0)
                            }

                            GradientStop {
                                position: 1
                                color: Qt.rgba(fade.base.r, fade.base.g, fade.base.b, 1)
                            }
                        }
                    }
                }

                ChromeText {
                    visible: cell.cutTop > 0 && text.length > 0
                    x: cell.cutLeft + 4 * root.ratio
                    width: cell.width - 2 * x
                    height: cell.cutTop
                    text: cell.record.title ?? ""
                    pixelSize: root.typography.small
                    emphasized: true
                    color: root.colors.text
                }

                ChromeText {
                    visible: cell.cutBottom > 0 && text.length > 0
                    x: cell.cutLeft + 4 * root.ratio
                    y: cell.height - cell.cutBottom
                    width: cell.width - 2 * x
                    height: cell.cutBottom
                    text: cell.record.footer ?? ""
                    pixelSize: root.typography.small
                    color: Qt.alpha(root.colors.text, 0.6)
                }

                // How far down its buffer a window is, from what Neovim says of its viewport:
                // shown while the text moves, then gone.
                Rectangle {
                    id: scrollbar

                    readonly property real lines: Math.max(1, cell.record.lineCount)
                    readonly property real span: Math.max(1, cell.record.bottomLine - cell.record.topLine)
                    readonly property real track: cell.height - cell.record.marginTop - cell.record.marginBottom - 4 * root.ratio
                    readonly property int moved: cell.record.scrolledLines

                    visible: cell.windowed && lines > span && opacity > 0
                    x: cell.width - width - 2 * root.ratio
                    y: cell.record.marginTop + 2 * root.ratio + (track - height) * Math.min(1, cell.record.topLine / Math.max(1, lines - span))
                    width: 3 * root.ratio
                    height: Math.max(18 * root.ratio, track * Math.min(1, span / lines))
                    radius: width / 2
                    color: Qt.alpha(root.colors.text, 0.32)
                    opacity: 0

                    onMovedChanged: {
                        opacity = 1;
                        rest.restart();
                    }

                    Behavior on opacity {
                        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                    }

                    Timer {
                        id: rest
                        interval: 900
                        onTriggered: scrollbar.opacity = 0
                    }
                }
            }
        }

        // Between two windows Neovim fills cells with a separator's character: a line of the
        // window's own stands over each. The cells stay Neovim's to drag.
        Repeater {
            model: view.separators

            delegate: Item {
                id: separator

                required property var modelData

                x: modelData.x
                y: modelData.y
                z: 0.5
                width: modelData.width
                height: modelData.height

                Rectangle {
                    readonly property color base: root.colors.terminalBackground

                    anchors.fill: parent
                    color: Qt.rgba(base.r, base.g, base.b, 1)
                }

                Rectangle {
                    x: separator.modelData.vertical ? Math.round((parent.width - width) / 2) : 0
                    y: separator.modelData.vertical ? 0 : Math.round((parent.height - height) / 2)
                    width: separator.modelData.vertical ? 1 : parent.width
                    height: separator.modelData.vertical ? parent.height : 1
                    color: root.colors.border
                }
            }
        }

        // Letters typed in insert mode over a slow link, shown where they will be before the
        // frame that carries them arrives. The frame replaces them, right or wrong.
        Item {
            id: ahead

            readonly property string letters: view.prediction
            visible: letters.length > 0
            x: view.predictionOrigin.x
            y: view.predictionOrigin.y
            z: 850
            width: letters.length * view.cellWidth
            height: view.cellHeight

            Rectangle {
                readonly property color base: root.colors.terminalBackground

                anchors.fill: parent
                color: Qt.rgba(base.r, base.g, base.b, 1)
            }

            CellText {
                anchors.fill: parent
                text: ahead.letters
                grid: root.typography.grid
                color: Qt.alpha(root.colors.text, 0.72)
            }

            // The mark of a guess: a line under the letters, gone when they are the editor's.
            Rectangle {
                y: parent.height - height
                width: parent.width
                height: Math.max(1, Math.round(root.ratio))
                color: Qt.alpha(root.colors.accent, 0.55)
            }
        }

        // The cursor, in a layer of its own over the cells, in the shape the mode Neovim is in
        // gives it. It slides to where it goes with telar's curve; a step to the next cell, as
        // typing makes, is taken at once, so the cursor is never behind what is typed. Moving or
        // blinking it draws none of the cells again. Without the keyboard it is hollow.
        Item {
            id: caret

            objectName: "editorCaret"
            readonly property rect target: view.cursorRect
            readonly property var look: view.caret ?? ({})
            readonly property string shape: look.shape ?? "block"
            readonly property real share: Math.max(0.1, (look.percentage ?? 100) / 100)
            readonly property bool focused: view.activeFocus
            readonly property color tint: look.color ?? root.colors.text

            z: 900
            width: target.width * ((look.wide ?? false) ? 2 : 1)
            height: target.height
            visible: (look.visible ?? false) && target.width > 0 && ((look.on ?? true) || !focused)

            onTargetChanged: {
                // A step along a row or to the next one is typing's; anything else is a jump.
                const step = Math.abs(target.y - y) < 0.5 * target.height && Math.abs(target.x - x) <= 1.5 * target.width;
                if (!step && width > 0 && glide.ready) {
                    glide.stop();
                    glide.from = Qt.point(x, y);
                    glide.start();
                } else {
                    glide.stop();
                    x = target.x;
                    y = target.y;
                }
            }

            ParallelAnimation {
                id: glide

                property point from
                // The first place it takes has nowhere to come from.
                property bool ready: false

                NumberAnimation { target: caret; property: "x"; from: glide.from.x; to: caret.target.x; duration: 90; easing.type: Easing.OutCubic }
                NumberAnimation { target: caret; property: "y"; from: glide.from.y; to: caret.target.y; duration: 90; easing.type: Easing.OutCubic }
            }

            Component.onCompleted: {
                x = target.x;
                y = target.y;
                glide.ready = true;
            }

            // A block covers its cell and draws the cell's text again in the cursor's text color;
            // a bar and an underline cover the share of it the mode asks for.
            Rectangle {
                visible: caret.focused
                x: 0
                y: caret.shape === "underline" ? caret.height * (1 - caret.share) : 0
                width: caret.shape === "bar" ? Math.max(1, Math.round(caret.width * caret.share)) : caret.width
                height: caret.shape === "underline" ? Math.max(1, Math.round(caret.height * caret.share)) : caret.height
                color: caret.tint

                CellText {
                    anchors.fill: parent
                    visible: caret.shape === "block" && (caret.look.text ?? "").length > 0
                    text: caret.look.text ?? ""
                    grid: root.typography.grid
                    color: caret.look.textColor ?? root.colors.background
                }
            }

            Rectangle {
                visible: !caret.focused
                anchors.fill: parent
                color: "transparent"
                border.width: Math.max(1, root.ratio) / Screen.devicePixelRatio
                border.color: caret.tint
            }
        }

        // What Neovim shows of its mode, of a command half typed and of the ruler, on the row it
        // leaves empty under the windows.
        Item {
            id: status

            readonly property var shown: view.messages
            z: 5
            x: 8 * root.ratio
            y: view.height - height
            width: view.width - 16 * root.ratio
            height: view.cellHeight
            visible: !line.shown

            ChromeText {
                width: parent.width / 2
                height: parent.height
                text: status.shown.mode ?? ""
                pixelSize: root.typography.small
                emphasized: true
                color: root.colors.accent
            }

            ChromeText {
                x: parent.width / 2
                width: parent.width / 2
                height: parent.height
                horizontalAlignment: Text.AlignRight
                text: [status.shown.command ?? "", status.shown.ruler ?? ""].filter(part => part.length > 0).join("   ")
                pixelSize: root.typography.small
                color: Qt.alpha(root.colors.text, 0.6)
            }
        }

        NvimMessages {
            z: 950
            // A picker has the pane: notices wait behind it, out of sight.
            visible: !(view.picker.open ?? false)
            messages: view.messages
            onHistory: view.send("<Cmd>messages<CR>")
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
        }

        NvimCmdline {
            id: line
            z: 960
            line: view.cmdline
            cellHeight: view.cellHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
        }

        NvimPopupMenu {
            z: 970
            menu: view.popupMenu
            // Under the cell Neovim names, or under the command line it completes.
            anchor: (view.popupMenu.onCmdline ?? false) ? Qt.point(line.x + line.caretX, line.y + line.height - view.cellHeight) : Qt.point(view.popupMenu.x ?? 0, view.popupMenu.y ?? 0)
            cellHeight: view.cellHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            onPicked: index => {
                view.chooseMenu((view.popupMenu.first ?? 0) + index);
                view.forceActiveFocus();
            }
        }

        NvimPicker {
            id: pick
            z: 990
            picker: view.picker
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            onSearched: query => view.searchPicker(query)
            onSourceChosen: source => view.pick(source)
            onAccepted: (index, where) => {
                view.acceptPicker(index, where);
                view.forceActiveFocus();
            }
            onListed: indices => {
                view.listPicker(indices);
                view.forceActiveFocus();
            }
            onPreviewed: (index, area) => view.previewPicker(index, area)
            onClosed: {
                view.closePicker();
                view.forceActiveFocus();
            }
            // Closed from elsewhere: the keys go back to the editor.
            onShownChanged: {
                if (!shown && activeFocus) {
                    view.forceActiveFocus();
                }
            }
        }

        NvimPrompt {
            id: ask
            z: 980
            prompt: view.prompt
            anchor: view.cursorRect
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            onAnswered: (accepted, index, text) => {
                view.answer(accepted, index, text);
                view.forceActiveFocus();
            }
            // Answered from another window, or withdrawn: the keys go back to the editor.
            onShownChanged: {
                if (!shown && activeFocus) {
                    view.forceActiveFocus();
                }
            }
        }
    }
}
