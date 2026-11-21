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

                // Neovim draws a window over whatever the grid under it holds: the window hides
                // it, as the pane's own background would.
                Rectangle {
                    readonly property color base: root.colors.terminalBackground

                    anchors.fill: parent
                    visible: !cell.floating && cell.record.kind !== "base"
                    color: Qt.rgba(base.r, base.g, base.b, 1)
                }

                NvimSurface {
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
                    editor: view
                    gridId: cell.record.gridId
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

        // The cursor's own layer: a mark that travels from where the cursor was to where it
        // is and fades as it arrives. The cursor itself is already there, drawn with the cells,
        // so nothing waits for the motion.
        Rectangle {
            id: trail

            readonly property rect target: view.cursorRect
            property real travel: 0

            z: 900
            width: target.width
            height: target.height
            radius: 2 * root.ratio
            color: root.colors.accent
            opacity: 0.28 * (1 - travel)
            visible: travel < 1 && view.activeFocus

            onTargetChanged: {
                // A step to the next cell needs no mark; a jump is followed by the eye.
                const far = Math.abs(target.x - x) > 2.5 * target.width || Math.abs(target.y - y) > 0.5 * target.height;
                if (far && width > 0 && travel >= 1) {
                    glide.from = Qt.point(x, y);
                    glide.restart();
                } else if (!glide.running) {
                    x = target.x;
                    y = target.y;
                }
            }

            ParallelAnimation {
                id: glide

                property point from

                NumberAnimation { target: trail; property: "x"; from: glide.from.x; to: trail.target.x; duration: 90; easing.type: Easing.OutCubic }
                NumberAnimation { target: trail; property: "y"; from: glide.from.y; to: trail.target.y; duration: 90; easing.type: Easing.OutCubic }
                NumberAnimation { target: trail; property: "travel"; from: 0; to: 1; duration: 150; easing.type: Easing.OutQuad }
            }

            Component.onCompleted: travel = 1
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
            messages: view.messages
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
        }

        NvimPrompt {
            id: ask
            z: 980
            prompt: view.prompt
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
