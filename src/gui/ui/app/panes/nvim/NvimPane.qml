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
                // The picker's preview is a float of Neovim's, drawn over the picker's surface.
                z: (record.preview ?? false) ? 995 : record.layer
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
                    visible: cell.floating && !(cell.record.preview ?? false)
                    x: -cell.inset
                    y: -cell.inset
                    width: cell.width + 2 * cell.inset
                    height: cell.height + 2 * cell.inset
                    colors: root.colors
                    ratio: root.ratio
                }

                Item {
                    x: cell.cutLeft
                    y: cell.cutTop
                    width: cell.width - cell.cutLeft - cell.cutRight
                    height: cell.height - cell.cutTop - cell.cutBottom
                    clip: cell.border !== 0

                    NvimGrid {
                        x: -cell.cutLeft
                        y: -cell.cutTop
                        width: cell.width
                        height: cell.height
                        editor: view
                        gridId: cell.record.gridId
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
