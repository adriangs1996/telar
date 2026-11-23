pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick

// The explorer over the panes of the tab: the lenses and what a window follows, then its windows
// side by side with the preview of the selected row, the line that says what happened or takes
// what is typed, and the keys that apply now. Names, paths and diffs are set in the terminal's
// font; the controller gives every row its text, so QML only places it.
FocusScope {
    id: root

    required property ExplorerController controller
    required property var colors
    required property var typography
    property real ratio: 1

    readonly property var windows: controller.windows
    readonly property var line: controller.line
    readonly property var preview: controller.preview
    readonly property string mode: line.mode ?? "normal"
    readonly property bool typing: mode === "insert" || mode === "search" || mode === "command"
    // The terminal's font, and the same a step smaller for what a row says beside its name.
    readonly property var grid: typography.grid ?? ({})
    readonly property var smallGrid: scaled(grid, 0.92)
    readonly property var tinyGrid: scaled(grid, 0.84)
    readonly property real hairline: 1 / Screen.devicePixelRatio
    readonly property real rowHeight: Math.round(Math.max(22 * ratio, (grid.cellHeight ?? 16) + 3 * ratio))
    readonly property real statusHeight: Math.round(Math.max(20 * ratio, (smallGrid.cellHeight ?? 16) + 3 * ratio))
    readonly property real headHeight: Math.round(Math.max(34 * ratio, rowHeight + 10 * ratio))
    readonly property real barHeight: Math.round(Math.max(30 * ratio, typography.smallRow + 12 * ratio))
    readonly property real commandHeight: Math.round(Math.max(24 * ratio, (grid.cellHeight ?? 16) + 6 * ratio))
    readonly property real previewWidth: windows.length > 1 ? 0 : Math.round(Math.max(300 * ratio, body.width * 0.38))
    readonly property real indent: 14 * ratio
    readonly property real gutter: 10 * ratio

    objectName: "explorerOverlay"
    visible: controller.showing
    z: 40

    function scaled(grid, factor) {
        return {
            family: grid.family ?? "",
            style: grid.style ?? "",
            pixelHeight: Math.max(1, (grid.pixelHeight ?? 13) * factor),
            cellWidth: Math.max(1, (grid.cellWidth ?? 8) * factor),
            cellHeight: Math.max(1, (grid.cellHeight ?? 16) * factor),
            baseline: (grid.baseline ?? 12) * factor
        };
    }

    // The end of `text` that fits `width` in cells of `grid`, with a mark where it was cut.
    function tail(text, width, grid) {
        const cells = Math.max(1, Math.floor(width / Math.max(1, grid.cellWidth ?? 8)));

        return text.length <= cells ? text : "…" + text.slice(text.length - cells + 1);
    }

    function toneColor(tone) {
        return tone === "added" ? colors.green : tone === "removed" ? colors.red : tone === "hunk" ? colors.blue : colors.subtext0;
    }

    function modeColor(kind) {
        return kind === "visual" ? colors.mauve : kind === "insert" ? colors.teal : kind === "search" || kind === "command" ? colors.accent : colors.green;
    }

    // The field of the mode takes the keys while something is typed; the windows otherwise.
    function settleFocus() {
        if (!visible)
            return;
        if (mode === "search" || mode === "command") {
            commandField.text = line.prefill ?? "";
            commandField.forceActiveFocus();
        } else if (mode === "insert") {
            nameField.text = line.prefill ?? "";
            nameField.forceActiveFocus();
            nameField.selectAll();
        } else {
            keys.forceActiveFocus();
        }
    }

    onVisibleChanged: settleFocus()
    onModeChanged: settleFocus()

    // What is behind the explorer takes no pointer while it shows.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: mouse => {
            mouse.accepted = true;
            root.settleFocus();
        }
        onWheel: wheel => wheel.accepted = true
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            event.accepted = root.controller.key(event.key, event.text, event.modifiers);
        }
    }

    NativeRoundedRectangle {
        x: -root.hairline
        y: -root.hairline
        width: root.width + 2 * root.hairline
        height: root.height + 2 * root.hairline
        radius: 8 * root.ratio + root.hairline
        color: Qt.rgba(0, 0, 0, 0.45)
    }

    NativeRoundedRectangle {
        id: surface
        anchors.fill: parent
        radius: 8 * root.ratio
        color: root.colors.surface_dim
        borderWidth: Math.max(root.hairline, 1 * root.ratio)
        borderColor: root.colors.overlay0
        borderAlpha: 1
    }

    // The lenses of the current window, and what it follows.
    Item {
        id: bar
        x: root.gutter
        width: root.width - 2 * root.gutter
        height: root.barHeight

        Row {
            height: parent.height
            spacing: 2 * root.ratio

            Repeater {
                model: root.controller.lenses

                delegate: Item {
                    id: lens

                    required property var modelData
                    required property int index
                    readonly property bool on: modelData.current
                    readonly property real pad: 8 * root.ratio

                    width: number.implicitWidth + 4 * root.ratio + name.implicitWidth + (count.visible ? 3 * root.ratio + count.implicitWidth : 0) + 2 * pad
                    height: bar.height

                    NativeRoundedRectangle {
                        y: Math.round((parent.height - height) / 2)
                        width: parent.width
                        height: Math.round(root.typography.smallRow + 6 * root.ratio)
                        radius: 4 * root.ratio
                        color: root.colors.surface0
                        visible: lens.on
                    }

                    CellText {
                        id: number
                        x: lens.pad
                        width: implicitWidth
                        height: parent.height
                        text: String(lens.index + 1)
                        grid: root.tinyGrid
                        color: root.colors.overlay1
                    }

                    ChromeText {
                        id: name
                        x: number.x + number.width + 4 * root.ratio
                        width: implicitWidth
                        height: parent.height
                        text: lens.modelData.name
                        pixelSize: root.typography.small
                        color: lens.on ? root.colors.text : root.colors.subtext0
                        elide: Text.ElideNone
                    }

                    CellText {
                        id: count
                        x: name.x + name.width + 3 * root.ratio
                        y: -2 * root.ratio
                        width: implicitWidth
                        height: parent.height
                        visible: lens.modelData.counted
                        text: String(lens.modelData.count)
                        grid: root.tinyGrid
                        color: root.colors.overlay1
                    }

                    ActionPointer {
                        anchors.fill: parent
                        identity: "lens:" + lens.modelData.name
                        onActivated: root.controller.run(lens.modelData.name)
                    }
                }
            }
        }

        Row {
            anchors.right: parent.right
            height: parent.height
            spacing: 2 * root.ratio

            Repeater {
                model: [
                    {
                        keys: "gp",
                        name: "pane"
                    },
                    {
                        keys: "gw",
                        name: "workspace"
                    },
                    {
                        keys: "gh",
                        name: "machine"
                    }
                ]

                delegate: Item {
                    id: scope

                    required property var modelData
                    readonly property bool on: root.controller.scope === modelData.name
                    readonly property real pad: 8 * root.ratio

                    width: scopeKeys.implicitWidth + 4 * root.ratio + scopeName.implicitWidth + 2 * pad
                    height: bar.height

                    NativeRoundedRectangle {
                        y: Math.round((parent.height - height) / 2)
                        width: parent.width
                        height: Math.round(root.typography.smallRow + 6 * root.ratio)
                        radius: 4 * root.ratio
                        color: root.colors.surface0
                        visible: scope.on
                    }

                    CellText {
                        id: scopeKeys
                        x: scope.pad
                        width: implicitWidth
                        height: parent.height
                        text: scope.modelData.keys
                        grid: root.tinyGrid
                        color: root.colors.overlay1
                    }

                    ChromeText {
                        id: scopeName
                        x: scopeKeys.x + scopeKeys.width + 4 * root.ratio
                        width: implicitWidth
                        height: parent.height
                        text: scope.modelData.name
                        pixelSize: root.typography.small
                        color: scope.on ? root.colors.accent : root.colors.subtext0
                        elide: Text.ElideNone
                    }

                    ActionPointer {
                        anchors.fill: parent
                        identity: "scope:" + scope.modelData.name
                        onActivated: root.controller.type(scope.modelData.keys)
                    }
                }
            }
        }
    }

    Rectangle {
        y: bar.height
        width: root.width
        height: root.hairline
        color: root.colors.surface1
    }

    // The windows, each on a directory of a machine, and beside them the preview.
    Item {
        id: body
        y: bar.height + root.hairline
        width: root.width
        height: Math.max(0, root.height - y - command.height - hints.height)

        Repeater {
            // A window keeps its items while what it shows changes.
            model: root.windows.length

            delegate: Item {
                id: pane

                required property int index
                readonly property var modelData: root.windows[index] ?? ({})
                readonly property int count: root.windows.length
                readonly property bool sideBySide: root.controller.sideBySide
                readonly property real room: body.width - root.previewWidth
                readonly property bool current: modelData.current
                readonly property int visibleRows: Math.max(1, Math.floor(list.height / root.rowHeight))

                x: sideBySide ? Math.round(index * room / count) : 0
                y: sideBySide ? 0 : Math.round(index * body.height / count)
                width: sideBySide ? Math.round(room / count) : room
                height: sideBySide ? body.height : Math.round(body.height / count)
                clip: true

                // Told once the frame that measured it ends, not while it is being laid out.
                onVisibleRowsChanged: Qt.callLater(root.controller.setViewport, index, visibleRows)
                Component.onCompleted: Qt.callLater(root.controller.setViewport, index, visibleRows)

                // Between two windows.
                Rectangle {
                    visible: pane.index > 0
                    width: pane.sideBySide ? Math.max(root.hairline, 1 * root.ratio) : parent.width
                    height: pane.sideBySide ? parent.height : Math.max(root.hairline, 1 * root.ratio)
                    color: root.colors.overlay0
                    z: 2
                }

                // The machine, the root and the branch.
                Item {
                    id: head
                    x: root.gutter
                    width: parent.width - 2 * root.gutter
                    height: root.headHeight

                    NativeRoundedRectangle {
                        id: chip
                        y: Math.round((parent.height - height) / 2) + 1 * root.ratio
                        width: dot.width + 6 * root.ratio + machine.implicitWidth + 6 * root.ratio + where.implicitWidth + 16 * root.ratio
                        height: Math.round((root.smallGrid.cellHeight ?? 16) + 4 * root.ratio)
                        radius: height / 2
                        color: root.colors.surface0

                        Rectangle {
                            id: dot
                            x: 8 * root.ratio
                            y: Math.round((parent.height - height) / 2)
                            width: 6 * root.ratio
                            height: width
                            radius: width / 2
                            color: pane.modelData.local ? root.colors.green : root.colors.blue
                        }

                        CellText {
                            id: machine
                            x: dot.x + dot.width + 6 * root.ratio
                            width: implicitWidth
                            height: parent.height
                            text: pane.modelData.machine
                            grid: root.smallGrid
                            color: root.colors.text
                        }

                        CellText {
                            id: where
                            x: machine.x + machine.width + 6 * root.ratio
                            width: implicitWidth
                            height: parent.height
                            text: pane.modelData.local ? "local" : "remote"
                            grid: root.tinyGrid
                            color: root.colors.subtext0
                        }
                    }

                    // What git says of the repository, at the head's end.
                    Row {
                        id: git
                        anchors.right: parent.right
                        height: parent.height
                        spacing: 6 * root.ratio
                        visible: pane.modelData.repository

                        ChromeIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round((root.smallGrid.cellHeight ?? 16) * 0.9)
                            height: width
                            glyph: ""
                            pixelSize: width
                            color: root.colors.subtext0
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: pane.modelData.branch
                            grid: root.smallGrid
                            color: root.colors.text
                            bold: true
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            visible: pane.modelData.upstream && (pane.modelData.ahead > 0 || pane.modelData.behind > 0)
                            text: (pane.modelData.ahead > 0 ? "↑" + pane.modelData.ahead : "") + (pane.modelData.behind > 0 ? "↓" + pane.modelData.behind : "")
                            grid: root.tinyGrid
                            color: root.colors.subtext0
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: String(pane.modelData.staged)
                            grid: root.smallGrid
                            color: root.colors.green
                            bold: true
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: String(pane.modelData.unstaged)
                            grid: root.smallGrid
                            color: root.colors.yellow
                            bold: true
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: String(pane.modelData.untracked)
                            grid: root.smallGrid
                            color: root.colors.blue
                            bold: true
                        }
                    }

                    // The root, its last directory apart; a long one keeps its end.
                    Row {
                        id: crumbs
                        x: chip.width + 8 * root.ratio
                        width: Math.max(0, parent.width - x - (git.visible ? git.width + 8 * root.ratio : 0))
                        height: parent.height
                        clip: true

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: root.tail(pane.modelData.lead ?? "", crumbs.width - (pane.modelData.last ?? "").length * (root.smallGrid.cellWidth ?? 8), root.smallGrid)
                            grid: root.smallGrid
                            color: root.colors.subtext0
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: pane.modelData.last
                            grid: root.smallGrid
                            color: pane.current ? root.colors.text : root.colors.subtext0
                            bold: true
                        }
                    }
                }

                // The rows the window shows, and nothing past them.
                Item {
                    id: list
                    y: head.height
                    width: parent.width
                    height: Math.max(0, parent.height - head.height - root.statusHeight)
                    clip: true

                    Repeater {
                        model: root.controller.rows(pane.index)

                        delegate: Item {
                            id: row

                            required property var record
                            required property int index
                            readonly property bool entry: record.kind === "entry" || record.kind === "added" || record.kind === "change" || record.kind === "pane"
                            readonly property real leading: root.gutter + record.depth * root.indent
                            readonly property color nameColor: record.removed ? root.colors.red : record.added ? root.colors.green : record.renamed ? root.colors.yellow : record.ignored ? root.colors.overlay1 : record.directory ? root.colors.accent : root.colors.text

                            y: 4 * root.ratio + index * root.rowHeight
                            width: list.width - (scrollbar.visible ? scrollbar.width + 2 * root.ratio : 0)
                            height: root.rowHeight

                            // The selection: the row lit, and the accent at its edge.
                            Rectangle {
                                anchors.fill: parent
                                visible: row.record.selected || row.record.marked
                                color: row.record.marked ? Qt.alpha(root.colors.mauve, 0.17) : pane.current ? root.colors.surface1 : root.colors.surface0
                            }

                            Rectangle {
                                width: 2 * root.ratio
                                height: parent.height
                                visible: row.record.selected
                                color: row.record.marked ? root.colors.mauve : pane.current ? root.colors.accent : root.colors.overlay1
                            }

                            // A line of a diff, tinted by what it does.
                            Rectangle {
                                anchors.fill: parent
                                visible: row.record.kind === "diff" && (row.record.tone === "added" || row.record.tone === "removed")
                                color: Qt.alpha(row.record.tone === "added" ? root.colors.green : root.colors.red, 0.1)
                            }

                            CellText {
                                x: row.leading
                                width: 10 * root.ratio
                                height: parent.height
                                visible: row.entry
                                text: row.record.kind === "added" ? "+" : !row.record.directory ? "" : row.record.expanded ? "▾" : "▸"
                                grid: root.grid
                                color: row.record.kind === "added" ? root.colors.green : root.colors.overlay1
                            }

                            ChromeIcon {
                                id: icon
                                x: row.leading + 16 * root.ratio
                                y: Math.round((parent.height - height) / 2)
                                width: Math.round((root.grid.cellHeight ?? 16) * 0.82)
                                height: width
                                visible: row.entry && (row.record.icon ?? "").length > 0
                                glyph: row.record.icon ?? ""
                                pixelSize: width
                                color: root.colors[row.record.iconTone ?? "subtext0"] ?? root.colors.subtext0
                                opacity: row.record.removed || row.record.ignored ? 0.45 : 1
                            }

                            // The pane's place in the tab, in the panes lens.
                            CellText {
                                x: row.leading + 16 * root.ratio
                                width: implicitWidth
                                height: parent.height
                                visible: row.record.kind === "pane"
                                text: String((row.record.panes ?? [])[0] ?? "")
                                grid: root.smallGrid
                                color: root.colors.accent
                            }

                            // What the row says after its name, from the right: its size and its
                            // share, what git holds of it, the panes in it and its marks.
                            Row {
                                id: notes
                                anchors.right: parent.right
                                anchors.rightMargin: root.gutter
                                height: parent.height
                                spacing: 6 * root.ratio
                                visible: row.entry

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: (row.record.note ?? "").length > 0
                                    text: row.record.note ?? ""
                                    grid: root.tinyGrid
                                    color: row.record.removed ? root.colors.red : row.record.added ? root.colors.green : root.colors.yellow
                                }

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: (row.record.marks ?? "").length > 0
                                    text: row.record.marks ?? ""
                                    grid: root.tinyGrid
                                    color: root.colors.accent
                                }

                                Repeater {
                                    model: row.record.kind === "pane" ? [] : (row.record.panes ?? [])

                                    delegate: Item {
                                        id: here

                                        required property var modelData

                                        anchors.verticalCenter: parent.verticalCenter
                                        width: hereText.implicitWidth + 8 * root.ratio
                                        height: Math.round((root.tinyGrid.cellHeight ?? 14) + 2 * root.ratio)

                                        NativeRoundedRectangle {
                                            anchors.fill: parent
                                            radius: 3 * root.ratio
                                            color: "transparent"
                                            borderWidth: Math.max(root.hairline, 1 * root.ratio)
                                            borderColor: root.colors.overlay1
                                            borderAlpha: 1
                                        }

                                        CellText {
                                            id: hereText
                                            x: 4 * root.ratio
                                            width: implicitWidth
                                            height: parent.height
                                            text: "◂ " + here.modelData
                                            grid: root.tinyGrid
                                            color: root.colors.accent
                                        }
                                    }
                                }

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: row.record.below > 0
                                    text: "●" + row.record.below
                                    grid: root.tinyGrid
                                    color: root.colors.yellow
                                    bold: true
                                }

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: row.record.kind === "change" && (row.record.linesAdded > 0 || row.record.linesRemoved > 0)
                                    text: "+" + row.record.linesAdded
                                    grid: root.tinyGrid
                                    color: root.colors.green
                                }

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: row.record.kind === "change" && (row.record.linesAdded > 0 || row.record.linesRemoved > 0)
                                    text: "−" + row.record.linesRemoved
                                    grid: root.tinyGrid
                                    color: root.colors.red
                                }

                                // The index's column, then the working tree's, as `git status -s`.
                                Item {
                                    width: Math.round(2.4 * (root.smallGrid.cellWidth ?? 8))
                                    height: parent.height
                                    visible: row.record.kind !== "pane"

                                    CellText {
                                        width: implicitWidth
                                        height: parent.height
                                        text: row.record.staged ?? ""
                                        grid: root.smallGrid
                                        color: root.colors.green
                                        bold: true
                                    }

                                    CellText {
                                        x: Math.round(1.2 * (root.smallGrid.cellWidth ?? 8))
                                        width: implicitWidth
                                        height: parent.height
                                        text: row.record.unstaged ?? ""
                                        grid: root.smallGrid
                                        color: row.record.unstaged === "U" ? root.colors.blue : row.record.unstaged === "!" ? root.colors.red : root.colors.yellow
                                        bold: true
                                    }
                                }

                                // Its share of the largest beside it, and its size.
                                Item {
                                    width: 82 * root.ratio
                                    height: parent.height
                                    visible: row.record.kind === "entry" || row.record.kind === "added"

                                    Rectangle {
                                        id: track
                                        y: Math.round((parent.height - height) / 2)
                                        width: 32 * root.ratio
                                        height: 4 * root.ratio
                                        radius: height / 2
                                        color: root.colors.surface0
                                        visible: row.record.kind === "entry"

                                        Rectangle {
                                            width: Math.round(parent.width * Math.min(1, row.record.share ?? 0))
                                            height: parent.height
                                            radius: parent.radius
                                            color: Qt.alpha(root.colors.peach, 0.7)
                                        }
                                    }

                                    CellText {
                                        x: parent.width - width
                                        width: implicitWidth
                                        height: parent.height
                                        text: row.record.measured ? (row.record.size ?? "") + (row.record.partial ? "+" : "") : "…"
                                        grid: root.smallGrid
                                        color: row.record.measured ? root.colors.subtext0 : root.colors.overlay1
                                    }
                                }
                            }

                            // The name: in a flat list, the path that leads to it first.
                            Row {
                                id: label
                                x: row.entry ? row.leading + (row.record.kind === "pane" ? 34 : 38) * root.ratio : row.leading + 16 * root.ratio
                                width: Math.max(0, (row.entry ? notes.x - 8 * root.ratio : parent.width - root.gutter) - x)
                                height: parent.height
                                clip: true
                                visible: !row.record.editing

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: (row.record.lead ?? "").length > 0
                                    text: row.record.lead ?? ""
                                    grid: root.grid
                                    color: root.colors.overlay1
                                }

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    text: (row.record.name ?? "") + (row.record.directory && row.entry && row.record.kind !== "pane" && !(row.record.name ?? "").endsWith("/") ? "/" : "")
                                    grid: row.record.kind === "diff" || row.record.kind === "note" || row.record.kind === "header" ? root.smallGrid : root.grid
                                    color: row.record.kind === "diff" ? root.toneColor(row.record.tone) : row.record.kind === "header" ? root.colors.subtext0 : row.record.kind === "note" ? root.colors.overlay1 : row.nameColor
                                    bold: row.record.kind === "header"
                                }
                            }

                            // A removed row's name is struck through.
                            Rectangle {
                                x: label.x
                                y: Math.round(parent.height / 2)
                                width: Math.min(label.width, label.implicitWidth)
                                height: Math.max(root.hairline, 1 * root.ratio)
                                visible: row.record.removed && !row.record.editing
                                color: root.colors.red
                            }
                        }
                    }

                    // What the listing leaves out, or that it is still being read.
                    ChromeText {
                        x: root.gutter
                        y: 8 * root.ratio
                        width: parent.width - 2 * root.gutter
                        height: root.rowHeight
                        visible: pane.modelData.rows === 0
                        text: pane.modelData.loading ? "Reading…" : "Nothing listed here"
                        pixelSize: root.typography.small
                        color: root.colors.subtext0
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        readonly property int rowAt: -1

                        function rowOf(mouse) {
                            return pane.modelData.top + Math.floor((mouse.y - 4 * root.ratio) / root.rowHeight);
                        }

                        onPressed: mouse => {
                            const at = rowOf(mouse);
                            const extend = (mouse.modifiers & Qt.ShiftModifier) !== 0;
                            const pick = (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0;

                            if (root.typing)
                                root.controller.cancel();
                            root.controller.select(pane.index, at, extend, pick);
                            root.settleFocus();
                        }
                        onDoubleClicked: mouse => root.controller.activate(pane.index, rowOf(mouse))
                        onWheel: wheel => {
                            root.controller.scroll(pane.index, wheel.angleDelta.y > 0 ? -3 : 3);
                            wheel.accepted = true;
                        }
                    }

                    // Where the rows shown stand in the listing.
                    Rectangle {
                        id: scrollbar
                        readonly property real share: pane.modelData.rows > 0 ? Math.min(1, pane.modelData.page / pane.modelData.rows) : 1

                        x: parent.width - width - 2 * root.ratio
                        y: 4 * root.ratio + (pane.modelData.rows > 0 ? (parent.height - 8 * root.ratio) * pane.modelData.top / pane.modelData.rows : 0)
                        width: 4 * root.ratio
                        height: Math.max(16 * root.ratio, (parent.height - 8 * root.ratio) * share)
                        radius: width / 2
                        color: Qt.alpha(root.colors.text, 0.22)
                        visible: share < 1
                    }
                }

                // The status line, as Neovim's.
                Rectangle {
                    id: status
                    y: parent.height - height
                    width: parent.width
                    height: root.statusHeight
                    color: pane.current ? root.colors.surface0 : root.colors.surface_dim

                    Rectangle {
                        width: parent.width
                        height: root.hairline
                        color: root.colors.surface1
                    }

                    Rectangle {
                        id: modeChip
                        width: modeText.implicitWidth + 18 * root.ratio
                        height: parent.height
                        color: pane.current ? root.modeColor(pane.modelData.modeKind) : root.colors.surface0

                        CellText {
                            id: modeText
                            x: 9 * root.ratio
                            width: implicitWidth
                            height: parent.height
                            text: pane.modelData.mode
                            grid: root.smallGrid
                            color: pane.current ? root.colors.panel_bg : root.colors.subtext0
                            bold: true
                        }
                    }

                    Row {
                        id: statusEnd
                        anchors.right: parent.right
                        anchors.rightMargin: root.gutter
                        height: parent.height
                        spacing: 10 * root.ratio

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            visible: (pane.modelData.flags ?? "").length > 0
                            text: pane.modelData.flags ?? ""
                            grid: root.smallGrid
                            color: root.colors.accent
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: pane.modelData.total ?? ""
                            grid: root.smallGrid
                            color: root.colors.peach
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            visible: (pane.modelData.keys ?? "").length > 0
                            text: pane.modelData.keys ?? ""
                            grid: root.smallGrid
                            color: root.colors.accent
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            visible: pane.modelData.chosen > 0
                            text: pane.modelData.chosen + " sel"
                            grid: root.smallGrid
                            color: root.colors.subtext0
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: pane.modelData.position + "/" + pane.modelData.count
                            grid: root.smallGrid
                            color: root.colors.subtext0
                        }
                    }

                    Row {
                        id: statusStart
                        x: modeChip.width + 10 * root.ratio
                        width: Math.max(0, statusEnd.x - x - 10 * root.ratio)
                        height: parent.height
                        spacing: 10 * root.ratio
                        clip: true

                        CellText {
                            id: following
                            width: implicitWidth
                            height: parent.height
                            text: pane.modelData.following ?? ""
                            grid: root.smallGrid
                            color: pane.modelData.follows ? root.colors.green : root.colors.subtext0
                        }

                        CellText {
                            width: implicitWidth
                            height: parent.height
                            text: root.tail((pane.modelData.root ?? "") + (pane.modelData.pending ? " [+]" : ""), statusStart.width - following.width - statusStart.spacing, root.smallGrid)
                            grid: root.smallGrid
                            color: root.colors.text
                        }
                    }
                }
            }
        }

        // The preview of the selected row.
        Rectangle {
            id: previewPane
            x: body.width - width
            width: root.previewWidth
            height: parent.height
            visible: width > 0
            color: root.colors.panel_bg
            clip: true

            Rectangle {
                width: Math.max(root.hairline, 1 * root.ratio)
                height: parent.height
                color: root.colors.surface1
            }

            Column {
                x: 12 * root.ratio
                y: 10 * root.ratio
                width: parent.width - 24 * root.ratio
                spacing: 10 * root.ratio
                visible: root.preview.shown ?? false

                Item {
                    width: parent.width
                    height: Math.round((root.grid.cellHeight ?? 16) + 6 * root.ratio)

                    ChromeIcon {
                        id: previewIcon
                        y: Math.round((parent.height - height) / 2)
                        width: Math.round((root.grid.cellHeight ?? 16) * 1.05)
                        height: width
                        glyph: root.preview.icon ?? ""
                        pixelSize: width
                        color: root.colors[root.preview.iconTone ?? "subtext0"] ?? root.colors.subtext0
                    }

                    CellText {
                        x: previewIcon.width + 6 * root.ratio
                        width: parent.width - x
                        height: parent.height
                        text: (root.preview.name ?? "") + (root.preview.directory ? "/" : "")
                        grid: root.grid
                        color: root.colors.text
                        bold: true
                        clip: true
                    }
                }

                CellText {
                    width: parent.width
                    height: Math.round(root.tinyGrid.cellHeight ?? 14)
                    text: root.preview.path ?? ""
                    grid: root.tinyGrid
                    color: root.colors.overlay1
                    clip: true
                }

                // What is known of it.
                Column {
                    width: parent.width
                    spacing: 2 * root.ratio

                    Repeater {
                        model: root.preview.facts ?? []

                        delegate: Item {
                            id: fact

                            required property var modelData
                            readonly property real labelWidth: 96 * root.ratio
                            readonly property real line: Math.round(Math.max(root.typography.smallRow, (root.smallGrid.cellHeight ?? 16) + 2 * root.ratio))
                            readonly property bool detailed: (modelData.detail ?? "").length > 0 && modelData.label === "Last commit"

                            width: parent.width
                            height: detailed ? 2 * line : line

                            ChromeText {
                                width: fact.labelWidth
                                height: fact.line
                                text: fact.modelData.label
                                pixelSize: root.typography.small
                                color: root.colors.subtext0
                            }

                            Row {
                                x: fact.labelWidth
                                width: parent.width - x
                                height: fact.line
                                spacing: 6 * root.ratio
                                clip: true

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    text: fact.modelData.value ?? ""
                                    grid: root.smallGrid
                                    color: root.colors.text
                                }

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: !fact.detailed && (fact.modelData.detail ?? "").length > 0
                                    text: fact.modelData.detail ?? ""
                                    grid: root.smallGrid
                                    color: root.colors.overlay1
                                }

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: fact.modelData.added > 0 || fact.modelData.removed > 0
                                    text: "+" + fact.modelData.added
                                    grid: root.smallGrid
                                    color: root.colors.green
                                    bold: true
                                }

                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: fact.modelData.added > 0 || fact.modelData.removed > 0
                                    text: "−" + fact.modelData.removed
                                    grid: root.smallGrid
                                    color: root.colors.red
                                }
                            }

                            CellText {
                                x: fact.labelWidth
                                y: fact.line
                                width: parent.width - x
                                height: fact.line
                                visible: fact.detailed
                                text: fact.modelData.detail ?? ""
                                grid: root.smallGrid
                                color: root.colors.overlay1
                                clip: true
                            }
                        }
                    }
                }

                // The panes whose shell is in it.
                Column {
                    width: parent.width
                    spacing: 4 * root.ratio
                    visible: (root.preview.panes ?? []).length > 0

                    ChromeText {
                        width: parent.width
                        height: root.typography.smallRow
                        text: "PANES HERE"
                        pixelSize: root.typography.small * 0.88
                        emphasized: true
                        color: root.colors.subtext0
                    }

                    Repeater {
                        model: root.preview.panes ?? []

                        delegate: CellText {
                            required property var modelData

                            width: implicitWidth
                            height: Math.round(root.smallGrid.cellHeight ?? 16)
                            text: "◂ pane " + modelData
                            grid: root.smallGrid
                            color: root.colors.accent
                        }
                    }
                }

                ChromeText {
                    width: parent.width
                    height: root.typography.smallRow
                    visible: (root.preview.title ?? "").length > 0
                    text: root.preview.title ?? ""
                    pixelSize: root.typography.small * 0.88
                    emphasized: true
                    color: root.colors.subtext0
                }

                // Its diff, or the head of its text.
                Rectangle {
                    id: snippet
                    readonly property real line: Math.round((root.tinyGrid.cellHeight ?? 14) * 1.25)
                    readonly property int shown: Math.max(0, Math.min((root.preview.lines ?? []).length, Math.floor((previewPane.height - y - parent.y - 24 * root.ratio) / line)))

                    width: parent.width
                    height: shown * line + 16 * root.ratio
                    visible: shown > 0
                    radius: 4 * root.ratio
                    color: root.colors.surface_dim
                    border.width: Math.max(root.hairline, 1 * root.ratio)
                    border.color: root.colors.surface1
                    clip: true

                    Repeater {
                        model: snippet.shown

                        delegate: CellText {
                            required property int index
                            readonly property var entry: (root.preview.lines ?? [])[index] ?? ({})

                            x: 8 * root.ratio
                            y: 8 * root.ratio + index * snippet.line
                            width: snippet.width - 16 * root.ratio
                            height: snippet.line
                            text: entry.text ?? ""
                            grid: root.tinyGrid
                            color: root.toneColor(entry.tone ?? "context")
                            clip: true
                        }
                    }
                }
            }
        }
    }

    // What the explorer says, or the field of the mode.
    Item {
        id: command
        y: body.y + body.height
        width: root.width
        height: root.commandHeight

        CellText {
            id: prompt
            x: root.gutter
            width: implicitWidth
            height: parent.height
            visible: root.mode === "search" || root.mode === "command"
            text: root.mode === "search" ? "/" : ":"
            grid: root.grid
            color: root.colors.accent
        }

        FormTextField {
            id: commandField
            objectName: "explorerCommand"
            x: prompt.x + prompt.width + 1 * root.ratio
            y: Math.round((parent.height - height) / 2)
            width: parent.width - x - root.gutter
            height: Math.max(root.grid.cellHeight ?? 0, 18 * root.ratio)
            visible: prompt.visible
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            formControl: false
            maximumBytes: 4096
            Accessible.name: root.mode === "search" ? "Filter" : "Command"
            onTextEdited: {
                if (root.mode === "search")
                    root.controller.typed(text);
            }
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.controller.submit(text);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    root.controller.cancel();
                    event.accepted = true;
                }
            }
        }

        CellText {
            x: root.gutter
            width: parent.width - 2 * root.gutter
            height: parent.height
            visible: !prompt.visible
            text: root.line.message ?? ""
            grid: root.grid
            color: root.line.tone === "error" ? root.colors.red : root.line.tone === "ask" ? root.colors.accent : root.colors.subtext0
            clip: true
        }
    }

    // The keys that apply now.
    Item {
        id: hints
        y: root.height - height
        width: root.width
        height: flow.implicitHeight + 12 * root.ratio

        Rectangle {
            width: parent.width
            height: root.hairline
            color: root.colors.surface1
        }

        Flow {
            id: flow
            x: root.gutter
            y: 6 * root.ratio
            width: parent.width - 2 * root.gutter
            spacing: 12 * root.ratio

            Repeater {
                model: root.controller.hints

                delegate: Item {
                    id: hint

                    required property var modelData
                    readonly property real line: Math.round(Math.max(root.typography.smallRow, (root.tinyGrid.cellHeight ?? 14) + 6 * root.ratio))

                    width: cap.width + 5 * root.ratio + word.implicitWidth
                    height: line
                    opacity: modelData.enabled ? 1 : 0.35

                    // The cap's lower edge, a line thicker than the others, as a key's.
                    NativeRoundedRectangle {
                        x: cap.x
                        y: cap.y + 1 * root.ratio
                        width: cap.width
                        height: cap.height
                        radius: cap.radius
                        color: root.colors.surface1
                    }

                    NativeRoundedRectangle {
                        id: cap
                        y: Math.round((parent.height - height) / 2)
                        width: Math.max(Math.round(1.5 * (root.tinyGrid.cellHeight ?? 14)), capText.implicitWidth + 8 * root.ratio)
                        height: Math.round((root.tinyGrid.cellHeight ?? 14) + 4 * root.ratio)
                        radius: 4 * root.ratio
                        color: root.colors.surface_dim
                        borderWidth: Math.max(root.hairline, 1 * root.ratio)
                        borderColor: root.colors.surface1
                        borderAlpha: 1

                        CellText {
                            id: capText
                            x: Math.round((parent.width - width) / 2)
                            width: implicitWidth
                            height: parent.height
                            text: hint.modelData.keys
                            grid: root.tinyGrid
                            color: root.colors.text
                        }
                    }

                    ChromeText {
                        id: word
                        x: cap.width + 5 * root.ratio
                        width: implicitWidth
                        height: parent.height
                        text: hint.modelData.label
                        pixelSize: root.typography.small
                        color: root.colors.subtext0
                        elide: Text.ElideNone
                    }

                    ActionPointer {
                        anchors.fill: parent
                        enabled: hint.modelData.enabled
                        identity: "hint:" + hint.modelData.keys
                        onActivated: root.controller.type(hint.modelData.keys === ":w" ? ":" : hint.modelData.keys)
                    }
                }
            }
        }
    }

    // The name of a row while it is typed: a rename, or a new entry.
    FormTextField {
        id: nameField
        objectName: "explorerName"

        readonly property var owner: root.windows[root.line.window ?? 0] ?? ({})
        readonly property int place: (root.line.cursor ?? 0) - (owner.top ?? 0)
        readonly property real paneX: (root.controller.sideBySide ? Math.round((root.line.window ?? 0) * (body.width - root.previewWidth) / Math.max(1, root.windows.length)) : 0)
        readonly property real paneY: (root.controller.sideBySide ? 0 : Math.round((root.line.window ?? 0) * body.height / Math.max(1, root.windows.length)))

        x: paneX + root.gutter + 38 * root.ratio
        y: body.y + paneY + root.headHeight + 4 * root.ratio + place * root.rowHeight + Math.round((root.rowHeight - height) / 2)
        z: 5
        width: Math.max(120 * root.ratio, (body.width - root.previewWidth) / Math.max(1, root.windows.length) - 160 * root.ratio)
        height: Math.max(root.grid.cellHeight ?? 0, 18 * root.ratio)
        visible: root.mode === "insert"
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        formControl: false
        maximumBytes: 255
        Accessible.name: "Name"
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.controller.submit(text);
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.controller.cancel();
                event.accepted = true;
            }
        }
    }

    // The plan `:w` shows before anything is touched, and the help.
    Rectangle {
        id: sheet
        x: root.gutter
        y: bar.height + 14 * root.ratio
        z: 6
        width: root.width - 2 * root.gutter
        height: Math.max(0, root.height - y - command.height - hints.height - 8 * root.ratio)
        visible: root.mode === "plan" || root.mode === "help"
        radius: 6 * root.ratio
        color: root.colors.surface_dim
        border.width: Math.max(root.hairline, 1 * root.ratio)
        border.color: root.colors.overlay0
        clip: true

        Column {
            x: 14 * root.ratio
            y: 12 * root.ratio
            width: parent.width - 28 * root.ratio
            spacing: 6 * root.ratio
            visible: root.mode === "plan"

            ChromeText {
                width: parent.width
                height: root.typography.smallRow
                text: "PLAN OF :w · " + root.controller.plan.length + (root.controller.plan.length === 1 ? " OPERATION" : " OPERATIONS") + ((root.line.overwrite ?? false) ? " · OVERWRITES WHAT EXISTS" : "")
                pixelSize: root.typography.small * 0.88
                emphasized: true
                color: root.colors.subtext0
            }

            Repeater {
                model: root.controller.plan

                delegate: Item {
                    id: step

                    required property var modelData
                    readonly property color verbColor: modelData.verb === "CREATE" ? root.colors.green : modelData.verb === "MOVE" ? root.colors.yellow : modelData.verb === "COPY" ? root.colors.blue : root.colors.red

                    width: parent.width
                    height: root.rowHeight

                    CellText {
                        id: verb
                        width: Math.round(9 * (root.smallGrid.cellWidth ?? 8))
                        height: parent.height
                        text: step.modelData.verb
                        grid: root.smallGrid
                        color: step.verbColor
                        bold: true
                    }

                    CellText {
                        x: verb.width
                        width: parent.width - x
                        height: parent.height
                        text: (step.modelData.source ?? "") + ((step.modelData.source ?? "").length > 0 && (step.modelData.target ?? "").length > 0 ? " → " : "") + (step.modelData.target ?? "") + (step.modelData.directory && (step.modelData.source ?? "").length === 0 ? "/" : "")
                        grid: root.smallGrid
                        color: root.colors.text
                        clip: true
                    }
                }
            }

            ChromeText {
                width: parent.width
                height: 2 * root.typography.smallRow
                text: "Before each operation the runtime checks that its source still is the file it listed, by inode and modification time, and skips it otherwise. What is deleted or replaced goes to the trash."
                pixelSize: root.typography.small
                color: root.colors.subtext0
            }
        }

        Flow {
            x: 14 * root.ratio
            y: 12 * root.ratio
            width: parent.width - 28 * root.ratio
            spacing: 20 * root.ratio
            visible: root.mode === "help"

            Repeater {
                model: root.controller.help

                delegate: Column {
                    id: group

                    required property var modelData

                    width: Math.max(220 * root.ratio, (sheet.width - 28 * root.ratio - 40 * root.ratio) / 3)
                    spacing: 2 * root.ratio

                    ChromeText {
                        width: parent.width
                        height: root.typography.smallRow + 4 * root.ratio
                        text: group.modelData.title.toUpperCase()
                        pixelSize: root.typography.small * 0.88
                        emphasized: true
                        color: root.colors.subtext0
                    }

                    Repeater {
                        model: group.modelData.keys

                        delegate: Item {
                            id: binding

                            required property var modelData

                            width: group.width
                            height: Math.round(Math.max(root.typography.smallRow, (root.smallGrid.cellHeight ?? 16) + 2 * root.ratio))

                            CellText {
                                id: bindingKeys
                                width: Math.round(16 * (root.smallGrid.cellWidth ?? 8))
                                height: parent.height
                                text: binding.modelData.keys
                                grid: root.smallGrid
                                color: root.colors.accent
                                clip: true
                            }

                            ChromeText {
                                x: bindingKeys.width + 8 * root.ratio
                                width: parent.width - x
                                height: parent.height
                                text: binding.modelData.label
                                pixelSize: root.typography.small
                                color: root.colors.subtext0
                            }
                        }
                    }
                }
            }
        }
    }
}
