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
    // The area of the panes, which the explorer takes whole; or, beside the panes, the room
    // their area left it at their right.
    required property rect area
    // Where the panes are, to say which one is under rows the pointer drags out of the explorer.
    property Item paneArea: null
    // Beside the panes it shows no preview, is as wide as the room, and takes the keys only
    // while it was given them.
    readonly property bool pinned: controller.pinned
    readonly property bool active: controller.focused
    // The pane that would take the rows dragged over it, and its frame in the explorer's own
    // coordinates; none while the pointer is over no pane.
    property string dropPane: ""
    property rect dropPaneFrame: Qt.rect(0, 0, 0, 0)
    // The design this is drawn from measures its boxes for a font of 12px, whose cell is 7.2px
    // wide. Each box takes the size of the terminal's font, as the text in it does, so the
    // explorer keeps its proportions whatever the font.
    readonly property real ratio: (grid.cellWidth ?? 7.2) / 7.2
    // How far inside the area it stands: that margin hides the panes too.
    readonly property real inset: pinned ? 0 : Math.round(6 * ratio)
    // The room between the panes and the explorer beside them.
    readonly property real gap: pinned ? Math.round(6 * ratio) : 0

    readonly property var windows: controller.windows
    readonly property var line: controller.line
    readonly property var preview: controller.preview
    readonly property var menu: controller.menu
    // Rows the pointer drags: how many, where it is in the explorer, whether Alt asks for a
    // copy or Shift for a move, whether they would be copied where the pointer is, and the
    // window and row whose directory would take them there, if one would.
    property bool dragCopy: false
    property bool dragMove: false
    property bool dragging: false
    property int dragCount: 0
    property real dragX: 0
    property real dragY: 0
    property bool dropCopy: false
    property int dropWindow: -1
    property int dropRow: -1
    readonly property string mode: line.mode ?? "normal"
    readonly property bool typing: mode === "insert" || mode === "search" || mode === "command"
    // How many times `<Tab>` completed the command line: the field takes what it completed.
    readonly property int completed: line.completed ?? 0
    // The terminal's font, and the same a step smaller for what a row says beside its name.
    readonly property var grid: typography.grid ?? ({})
    readonly property var smallGrid: scaled(grid, 0.92)
    readonly property var tinyGrid: scaled(grid, 0.84)
    // How long ago a file was touched, between the two.
    readonly property var agoGrid: scaled(grid, 0.875)
    // The sizes of what is written in the window's own font: a label, and a heading over a part.
    readonly property real labelSize: 11.5 * ratio
    readonly property real headingSize: 10 * ratio
    readonly property real hairline: 1 / Screen.devicePixelRatio
    // A frame's line: whole pixels, so it is drawn sharp at any size of the font.
    readonly property real edge: Math.max(hairline, Math.round(ratio))
    // A row's pitch is seldom a whole number of pixels: each row starts on the pixel nearest
    // its place, so a long list does not drift from the pitch.
    readonly property real rowPitch: 22 * ratio
    readonly property real rowHeight: Math.round(rowPitch)
    // The cells the longest machine's label takes in a plan that goes to more than one, so the
    // paths of its lines start in one column.
    readonly property int planMachineCells: controller.plan.reduce((longest, step) => Math.max(longest, (step.machine ?? "").length), 0)
    readonly property real listPadding: 4 * ratio
    // With the line above it.
    readonly property real statusHeight: Math.round(20 * ratio)
    readonly property real headHeight: Math.round(36 * ratio)
    readonly property real barHeight: Math.round(35.2 * ratio)
    readonly property real commandHeight: Math.round(24 * ratio)
    readonly property real hintsHeight: Math.round(30.4 * ratio)
    readonly property real previewWidth: pinned || windows.length > 1 ? 0 : Math.round(Math.max(300 * ratio, body.width * 0.38))
    readonly property real indent: 14 * ratio
    readonly property real gutter: 10 * ratio

    // The chip of who touched a file: `you`, or the place in the tab of its agent's pane, in the
    // color of whose hand it was.
    component ActorChip: Rectangle {
        property var actor: ({})
        // In a row it is written in the terminal's font, as the row is; in the preview, in the
        // window's own.
        property bool cell: true
        readonly property real written: cell ? cellText.implicitWidth : chromeText.implicitWidth

        width: Math.max(Math.floor(16 * root.ratio), Math.floor(written + 6 * root.ratio))
        height: Math.floor(15 * root.ratio)
        radius: 3 * root.ratio
        color: root.actorColor(actor.tone ?? "agent")

        CellText {
            id: cellText
            x: Math.round((parent.width - width) / 2)
            width: implicitWidth
            // A pixel above the middle, where a browser sets it.
            y: -Math.round(0.5 * root.ratio)
            height: parent.height
            visible: parent.cell
            text: actor.chip ?? ""
            grid: root.tinyGrid
            color: root.colors.panel_bg
            bold: true
        }

        ChromeText {
            id: chromeText
            x: Math.round((parent.width - width) / 2)
            width: implicitWidth
            height: parent.height
            visible: !parent.cell
            text: actor.chip ?? ""
            pixelSize: root.headingSize
            emphasized: true
            color: root.colors.panel_bg
        }
    }

    objectName: "explorerOverlay"
    x: area.x + inset + gap
    y: area.y + inset
    width: Math.max(0, area.width - 2 * inset - gap)
    height: Math.max(0, area.height - 2 * inset)
    visible: controller.showing
    z: 40

    // Where the row `index` of a window's list starts, and the row a place in the list is in.
    function rowY(index) {
        return Math.round(listPadding + index * rowPitch);
    }

    function rowAt(y) {
        return Math.floor((y - listPadding) / rowPitch);
    }

    // `grid` at `factor` of its size. A cell is a whole number of the screen's pixels, as the text
    // drawn in it takes: what is measured in cells here then fits what is drawn.
    function scaled(grid, factor) {
        const pixels = Screen.devicePixelRatio;
        const snapped = value => Math.max(1, Math.round(value * factor * pixels)) / pixels;

        return {
            family: grid.family ?? "",
            style: grid.style ?? "",
            pixelHeight: Math.max(1, (grid.pixelHeight ?? 13) * factor),
            cellWidth: snapped(grid.cellWidth ?? 8),
            cellHeight: snapped(grid.cellHeight ?? 16),
            baseline: (grid.baseline ?? 12) * factor
        };
    }

    // The end of `text` that fits `width` in cells of `grid`, with a mark where it was cut.
    function tail(text, width, grid) {
        const cells = Math.max(1, Math.floor(width / Math.max(1, grid.cellWidth ?? 8)));

        return text.length <= cells ? text : "…" + text.slice(text.length - cells + 1);
    }

    // `text` on two lines of `width` in cells of `grid`, broken at a space where one is near, the
    // second cut with a mark when it does not fit either.
    function actorColor(tone) {
        return tone === "you" ? colors.teal : tone === "claude" ? colors.peach : tone === "codex" ? colors.mauve : colors.subtext0;
    }

    function folded(text, width, grid) {
        const cells = Math.max(1, Math.floor(width / Math.max(1, grid.cellWidth ?? 8)));
        if (text.length <= cells)
            return [text, ""];

        const space = text.lastIndexOf(" ", cells);
        const cut = space > cells / 2 ? space : cells;
        const rest = text.slice(cut).trim();

        return [text.slice(0, cut), rest.length <= cells ? rest : rest.slice(0, cells - 1) + "…"];
    }

    // The window and the row of its listing under a point of the explorer; none outside the rows
    // of every window, and row -1 below the last one.
    function rowsAt(x, y) {
        for (let index = 0; index < panes.count; ++index) {
            const pane = panes.itemAt(index);
            if (!pane)
                continue;

            const point = pane.rowsArea.mapFromItem(root, x, y);
            if (point.x < 0 || point.y < 0 || point.x >= pane.rowsArea.width || point.y >= pane.rowsArea.height)
                continue;

            const row = pane.modelData.top + rowAt(point.y);

            return {window: index, row: row >= 0 && row < pane.modelData.rows ? row : -1};
        }

        return null;
    }

    // The pointer drags the rows to a point of the explorer: what is there says whether it takes
    // them, and which directory does.
    function dragTo(x, y, copy, move) {
        const at = rowsAt(x, y);
        const aimed = at === null ? ({}) : controller.aim(at.window, at.row, copy, move);
        // Out of the explorer, beside the panes, a pane takes the rows as Enter gives them.
        const over = at === null && pinned && paneArea !== null ? paneArea.paneAt(paneArea.mapFromItem(root, x, y)) : null;

        dropPane = over === null ? "" : String(over.key);
        dropPaneFrame = over === null ? Qt.rect(0, 0, 0, 0) : root.mapFromItem(paneArea, over.x, over.y, over.width, over.height);

        dragX = x;
        dragY = y;
        dragCopy = copy;
        dragMove = move;
        // On another machine rows are copied unless a move is asked for.
        dropCopy = aimed.copy ?? copy;
        dropWindow = (aimed.count ?? 0) > 0 ? at.window : -1;
        dropRow = aimed.row ?? -1;
    }

    // The pointer lets the rows go where it is, or the drag ends with nothing to take them.
    function endDrag(letGo) {
        const at = letGo ? rowsAt(dragX, dragY) : null;
        const pane = letGo ? dropPane : "";

        dragging = false;
        dropWindow = -1;
        dropRow = -1;
        dropPane = "";
        if (at !== null)
            controller.drop(at.window, at.row, dragCopy, dragMove);
        else if (pane.length > 0)
            controller.dropOnPane(pane);
        else
            controller.release();
        settleFocus();
    }

    function toneColor(tone) {
        return tone === "added" ? colors.green : tone === "removed" ? colors.red : tone === "hunk" ? colors.blue : colors.subtext0;
    }

    function modeColor(kind) {
        return kind === "visual" ? colors.mauve : kind === "insert" ? colors.teal : kind === "search" || kind === "command" ? colors.accent : colors.green;
    }

    // The field of the mode takes the keys while something is typed; the windows otherwise.
    // A press in the explorer gives it the keys, which beside the panes it may not have.
    function claim() {
        controller.giveFocus(true);
        settleFocus();
    }

    function settleFocus() {
        if (!visible || !active)
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
    onActiveChanged: settleFocus()

    onCompletedChanged: {
        if (mode === "command")
            commandField.text = line.completion ?? "";
    }

    // What is behind the explorer takes no pointer while it shows.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: mouse => {
            mouse.accepted = true;
            root.claim();
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

    // The panes and the frame of the focused one stay behind: the explorer takes their area.
    // Beside the panes it covers none of them.
    NativeRoundedRectangle {
        x: -root.inset
        y: -root.inset
        width: root.width + 2 * root.inset
        height: root.height + 2 * root.inset
        visible: !root.pinned
        color: root.colors.workbenchBackground
    }

    NativeRoundedRectangle {
        x: -root.hairline
        y: -root.hairline
        width: root.width + 2 * root.hairline
        height: root.height + 2 * root.hairline
        radius: 8 * root.ratio + root.hairline
        color: Qt.rgba(0, 0, 0, 0.27)
    }

    NativeRoundedRectangle {
        id: surface
        anchors.fill: parent
        radius: 8 * root.ratio
        color: root.colors.surface_dim
        borderWidth: root.edge
        // Beside the panes its frame is a pane's, lighter while it has the keys.
        borderColor: root.pinned ? (root.active ? root.colors.overlay0 : root.colors.surface1) : root.colors.overlay0
        borderAlpha: 1
    }

    // The lenses of the current window, and what it follows.
    Item {
        id: bar
        // A line of the bar, and whether what the window follows goes on a second one: beside
        // the panes the lenses leave it no room on theirs.
        readonly property real line: Math.round(23.2 * root.ratio)
        readonly property real inset: Math.round((root.barHeight - line) / 2)
        readonly property bool wrapped: lensRow.width + scopeRow.width + 8 * root.ratio > width

        x: root.gutter
        // Inside the frame's line, as everything below it.
        y: root.edge
        width: root.width - 2 * root.gutter
        height: wrapped ? 2 * inset + 2 * line + Math.round(8 * root.ratio) : root.barHeight

        Row {
            id: lensRow
            y: bar.inset
            height: bar.line
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
                    height: parent.height

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
                        pixelSize: root.labelSize
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
            id: scopeRow
            x: bar.wrapped ? 0 : parent.width - width
            y: bar.wrapped ? bar.inset + bar.line + Math.round(8 * root.ratio) : bar.inset
            height: bar.line
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
                    height: parent.height

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
                        pixelSize: root.labelSize
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
        y: bar.y + bar.height
        width: root.width
        height: root.hairline
        color: root.colors.surface1
    }

    // The windows, each on a directory of a machine, and beside them the preview.
    Item {
        id: body
        // Inside the frame: a row's mark stands beside its line, not on it.
        x: surface.borderWidth
        y: bar.y + bar.height + root.hairline
        width: root.width - 2 * x
        height: Math.max(0, root.height - y - command.height - hints.height - root.edge)

        Repeater {
            id: panes
            // A window keeps its items while what it shows changes.
            model: root.windows.length

            delegate: Item {
                id: pane

                required property int index
                readonly property var modelData: root.windows[index] ?? ({})
                readonly property int count: root.windows.length
                readonly property bool sideBySide: root.controller.sideBySide
                readonly property real room: body.width - root.previewWidth
                readonly property bool current: modelData.current && root.active
                readonly property int visibleRows: Math.max(1, Math.floor((list.height - root.listPadding) / root.rowPitch))
                readonly property Item rowsArea: list

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
                    width: pane.sideBySide ? root.edge : parent.width
                    height: pane.sideBySide ? parent.height : root.edge
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

                        // A click takes the window to the next machine, as `gm` does.
                        ActionPointer {
                            anchors.fill: parent
                            identity: "machine:" + pane.index
                            onActivated: root.controller.nextMachine(pane.index)
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
                    objectName: "explorerRows"
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
                            readonly property bool entry: record.kind === "entry" || record.kind === "added" || record.kind === "change" || record.kind === "pane" || record.kind === "match"
                            readonly property real leading: root.gutter + record.depth * root.indent
                            readonly property color nameColor: record.removed ? root.colors.red : record.added ? root.colors.green : record.renamed ? root.colors.yellow : record.ignored ? root.colors.overlay1 : record.directory ? root.colors.accent : root.colors.text

                            y: root.rowY(index)
                            width: list.width - (scrollbar.visible ? scrollbar.width + 2 * root.ratio : 0)
                            height: root.rowY(index + 1) - y

                            // The directory that would take the rows dragged.
                            Rectangle {
                                anchors.fill: parent
                                visible: root.dragging && root.dropWindow === pane.index && root.dropRow === pane.modelData.top + row.index
                                color: Qt.alpha(root.colors.accent, 0.16)
                                border.width: root.edge
                                border.color: root.colors.accent
                            }

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
                                text: row.record.kind === "added" ? "+" : !row.record.directory || row.record.kind === "match" ? "" : row.record.expanded ? "▾" : "▸"
                                grid: root.grid
                                color: row.record.kind === "added" ? root.colors.green : root.colors.overlay1
                            }

                            ChromeIcon {
                                id: icon
                                x: row.leading + 16 * root.ratio
                                y: Math.round((parent.height - height) / 2)
                                // The design's glyph of 13px, in a box 1.25 times as wide. The
                                // window draws an icon a fifth smaller than a browser does at the
                                // same size, so it asks for one that much larger.
                                width: Math.round(1.25 * 13 * root.ratio)
                                height: width
                                visible: row.entry && (row.record.icon ?? "").length > 0
                                glyph: row.record.icon ?? ""
                                pixelSize: 15.75 * root.ratio
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
                                            borderWidth: root.edge
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

                                // In the lens of touches: how the file was touched last.
                                CellText {
                                    width: implicitWidth
                                    height: parent.height
                                    visible: (row.record.verb ?? "").length > 0
                                    text: row.record.verb ?? ""
                                    grid: root.smallGrid
                                    color: root.colors.subtext0
                                }

                                // Who touched it, the last one first.
                                Repeater {
                                    model: row.record.actors ?? []

                                    delegate: ActorChip {
                                        required property var modelData

                                        y: Math.round(((parent?.height ?? height) - height) / 2)
                                        actor: modelData
                                    }
                                }

                                // And how long ago, at the right of a column any of them fits.
                                Item {
                                    width: Math.round(33.6 * root.ratio)
                                    height: parent.height
                                    visible: (row.record.ago ?? "").length > 0

                                    CellText {
                                        x: parent.width - width
                                        width: implicitWidth
                                        height: parent.height
                                        text: row.record.ago ?? ""
                                        grid: root.agoGrid
                                        color: root.colors.overlay1
                                    }
                                }

                                // What git says: the index's column, then the working tree's, as
                                // `git status -s`; of a directory, how many paths changed below it.
                                Item {
                                    width: Math.max(Math.round(2.4 * (root.smallGrid.cellWidth ?? 8)), below.visible ? below.implicitWidth : 0)
                                    height: parent.height
                                    visible: row.record.kind !== "pane"

                                    CellText {
                                        id: below
                                        x: parent.width - width
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
                                        visible: !below.visible
                                        text: row.record.staged ?? ""
                                        grid: root.smallGrid
                                        color: root.colors.green
                                        bold: true
                                    }

                                    CellText {
                                        x: Math.round(1.2 * (root.smallGrid.cellWidth ?? 8))
                                        width: implicitWidth
                                        height: parent.height
                                        visible: !below.visible
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
                                    // A file a pane touched says its size too, as in its directory.
                                    readonly property bool touched: (row.record.ago ?? "").length > 0
                                    visible: row.record.kind === "entry" || row.record.kind === "added" || touched

                                    Rectangle {
                                        id: track
                                        // Beside the size, which is four letters wide at most.
                                        x: Math.round(parent.width - (30.4 + 6 + 32) * root.ratio)
                                        y: Math.round((parent.height - height) / 2)
                                        width: 32 * root.ratio
                                        height: 4 * root.ratio
                                        radius: height / 2
                                        color: root.colors.surface0
                                        // A file that arrives from another machine fills it as it does.
                                        visible: row.record.kind === "entry" || parent.touched || (row.record.arriving ?? false)

                                        Rectangle {
                                            width: Math.round(parent.width * Math.min(1, row.record.share ?? 0))
                                            height: parent.height
                                            radius: parent.radius
                                            color: (row.record.arriving ?? false) ? root.colors.accent : Qt.alpha(root.colors.peach, 0.7)
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
                                height: root.edge
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
                        pixelSize: root.labelSize
                        color: root.colors.subtext0
                    }

                    // The window's root would take the rows dragged.
                    Rectangle {
                        anchors.fill: parent
                        visible: root.dragging && root.dropWindow === pane.index && root.dropRow < 0
                        color: "transparent"
                        border.width: root.edge
                        border.color: root.colors.accent
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // The row the button went down on and where, to tell a click from a drag;
                        // and whether choosing it waits for the button to come up, as it does on
                        // a row of the selection, which a drag takes whole.
                        property int pressedRow: -1
                        property point pressedAt: Qt.point(0, 0)
                        property bool waiting: false

                        function rowOf(mouse) {
                            return pane.modelData.top + root.rowAt(mouse.y);
                        }

                        onPressed: mouse => {
                            const at = rowOf(mouse);
                            const extend = (mouse.modifiers & Qt.ShiftModifier) !== 0;
                            const pick = (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0;

                            if (root.typing || root.mode === "menu")
                                root.controller.cancel();
                            if (mouse.button === Qt.RightButton) {
                                const place = mapToItem(root, mouse.x, mouse.y);

                                root.controller.openMenu(pane.index, at < pane.modelData.rows ? at : -1, Qt.point(place.x, place.y));
                                root.claim();
                                return;
                            }

                            pressedRow = at;
                            pressedAt = Qt.point(mouse.x, mouse.y);
                            waiting = !extend && !pick && root.controller.isChosen(pane.index, at);
                            if (!waiting)
                                root.controller.select(pane.index, at, extend, pick);
                            root.claim();
                        }
                        onPositionChanged: mouse => {
                            if ((mouse.buttons & Qt.LeftButton) === 0 || pressedRow < 0)
                                return;

                            const place = mapToItem(root, mouse.x, mouse.y);

                            if (!root.dragging) {
                                if (Math.abs(mouse.x - pressedAt.x) + Math.abs(mouse.y - pressedAt.y) < 6 * root.ratio)
                                    return;

                                root.dragCount = root.controller.grab(pane.index, pressedRow);
                                if (root.dragCount === 0) {
                                    pressedRow = -1;
                                    return;
                                }

                                root.dragging = true;
                            }

                            root.dragTo(place.x, place.y, (mouse.modifiers & Qt.AltModifier) !== 0, (mouse.modifiers & Qt.ShiftModifier) !== 0);
                        }
                        onReleased: mouse => {
                            if (root.dragging)
                                root.endDrag(true);
                            else if (waiting && mouse.button === Qt.LeftButton)
                                root.controller.select(pane.index, pressedRow, false, false);
                            waiting = false;
                            pressedRow = -1;
                        }
                        onCanceled: {
                            if (root.dragging)
                                root.endDrag(false);
                            waiting = false;
                            pressedRow = -1;
                        }
                        onDoubleClicked: mouse => {
                            if (mouse.button === Qt.LeftButton)
                                root.controller.activate(pane.index, rowOf(mouse));
                        }
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

                        // The filter, and how many paths below the root it found.
                        CellText {
                            width: implicitWidth
                            height: parent.height
                            visible: (pane.modelData.filter ?? "").length > 0
                            text: pane.modelData.filter ?? ""
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

                        // The files on their way to or from the window's machine.
                        CellText {
                            objectName: "explorerCarried"
                            width: implicitWidth
                            height: parent.height
                            visible: (pane.modelData.carried ?? 0) > 0
                            text: (pane.modelData.carried ?? 0) + " in transit"
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
                width: root.edge
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
                    height: Math.round((root.grid.cellHeight ?? 16) + 4 * root.ratio)

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
                    text: root.tail(root.preview.path ?? "", width, root.tinyGrid)
                    grid: root.tinyGrid
                    color: root.colors.overlay1
                    clip: true
                }

                // What is known of it, a line's height apart from what is above and below.
                Column {
                    width: parent.width
                    topPadding: root.labelSize + 1.6 * root.ratio
                    bottomPadding: root.labelSize
                    spacing: 2 * root.ratio

                    Repeater {
                        model: root.preview.facts ?? []

                        delegate: Item {
                            id: fact

                            required property var modelData
                            readonly property real labelWidth: 87 * root.ratio
                            readonly property real line: Math.round(17.6 * root.ratio)
                            readonly property bool detailed: (modelData.detail ?? "").length > 0 && modelData.label === "Last commit"
                            // The subject of a commit takes a second line when it is long.
                            readonly property var subject: detailed ? root.folded(modelData.detail ?? "", width - labelWidth, root.smallGrid) : ["", ""]

                            // The lines of the subject are set as close as a browser sets the
                            // lines of one text, which is closer than two facts are.
                            readonly property real subjectLine: Math.round(15.2 * root.ratio)
                            readonly property real subjectTop: line - Math.round(0.8 * root.ratio)

                            width: parent.width
                            height: detailed ? subjectTop + (subject[1].length > 0 ? 2 : 1) * subjectLine + Math.round(3.2 * root.ratio) : line

                            ChromeText {
                                width: fact.labelWidth
                                height: fact.line
                                text: fact.modelData.label
                                pixelSize: root.labelSize
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
                                y: fact.subjectTop
                                width: parent.width - x
                                height: fact.subjectLine
                                visible: fact.detailed
                                text: fact.subject[0]
                                grid: root.smallGrid
                                color: root.colors.overlay1
                                clip: true
                            }

                            CellText {
                                x: fact.labelWidth
                                y: fact.subjectTop + fact.subjectLine
                                width: parent.width - x
                                height: fact.subjectLine
                                visible: fact.detailed && fact.subject[1].length > 0
                                text: fact.subject[1]
                                grid: root.smallGrid
                                color: root.colors.overlay1
                                clip: true
                            }
                        }
                    }
                }

                // Who touched it lately.
                Column {
                    width: parent.width
                    spacing: 4 * root.ratio
                    visible: (root.preview.activity ?? []).length > 0

                    ChromeText {
                        width: parent.width
                        height: root.typography.smallRow
                        text: "ACTIVITY"
                        pixelSize: root.headingSize
                        emphasized: true
                        color: root.colors.subtext0
                    }

                    // A line for each, as tall as its chip and as far from the heading and from
                    // what follows as a browser sets them.
                    Column {
                        width: parent.width
                        topPadding: Math.round(1.6 * root.ratio)
                        bottomPadding: Math.round(1.6 * root.ratio)
                        spacing: 4 * root.ratio

                        Repeater {
                            model: root.preview.activity ?? []

                            delegate: Row {
                                id: touch

                                required property var modelData

                                height: Math.round(15 * root.ratio)
                                spacing: 6 * root.ratio

                                ActorChip {
                                    actor: (touch.modelData.actors ?? [])[0] ?? ({})
                                    cell: false
                                }

                                ChromeText {
                                    width: implicitWidth
                                    height: parent.height
                                    text: touch.modelData.who ?? ""
                                    pixelSize: root.labelSize
                                    color: root.colors.text
                                }

                                ChromeText {
                                    width: implicitWidth
                                    height: parent.height
                                    text: touch.modelData.verb ?? ""
                                    pixelSize: 11 * root.ratio
                                    color: root.colors.subtext0
                                }

                                Item {
                                    width: Math.round(33.6 * root.ratio)
                                    height: parent.height

                                    ChromeText {
                                        x: parent.width - width
                                        width: implicitWidth
                                        height: parent.height
                                        text: touch.modelData.ago ?? ""
                                        pixelSize: 10.5 * root.ratio
                                        color: root.colors.overlay1
                                    }
                                }
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
                        pixelSize: root.headingSize
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
                    pixelSize: root.headingSize
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
                    border.width: root.edge
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
            width: parent.width - x - root.gutter - (said.visible ? said.width + root.gutter : 0)
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
                } else if (event.key === Qt.Key_Tab && root.mode === "command") {
                    // The path a command goes to is completed; what it completes arrives in `line`.
                    root.controller.complete(text);
                    event.accepted = true;
                }
            }
        }

        // What the explorer says while a line is typed: the names `<Tab>` found.
        CellText {
            id: said
            x: parent.width - width - root.gutter
            width: Math.min(implicitWidth, parent.width * 0.6)
            height: parent.height
            visible: prompt.visible && (root.line.said ?? "").length > 0
            text: root.line.said ?? ""
            grid: root.smallGrid
            color: root.line.tone === "error" ? root.colors.red : root.colors.overlay1
            clip: true
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
        y: root.height - height - root.edge
        width: root.width
        height: Math.max(root.hintsHeight, flow.implicitHeight + 12 * root.ratio)

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
                        borderWidth: root.edge
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
                        pixelSize: root.labelSize
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
        y: body.y + paneY + root.headHeight + root.rowY(place) + Math.round((root.rowHeight - height) / 2)
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
        // Over the windows and the preview, whole: nothing of them shows beside it.
        x: body.x
        y: body.y
        z: 6
        width: body.width
        height: body.height
        visible: root.mode === "plan" || root.mode === "help"
        color: root.colors.surface_dim
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
                pixelSize: root.headingSize
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

                    // The machine of the step, in a plan that goes to more than one.
                    CellText {
                        id: stepMachine
                        x: verb.width
                        width: root.planMachineCells > 0 ? Math.round((root.planMachineCells + 1) * (root.smallGrid.cellWidth ?? 8)) : 0
                        height: parent.height
                        visible: width > 0
                        text: step.modelData.machine ?? ""
                        grid: root.smallGrid
                        color: root.colors.blue
                    }

                    CellText {
                        x: verb.width + stepMachine.width
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
                pixelSize: root.labelSize
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
                        pixelSize: root.headingSize
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
                                width: Math.round(17 * (root.smallGrid.cellWidth ?? 8))
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
                                pixelSize: root.labelSize
                                color: root.colors.subtext0
                            }
                        }
                    }
                }
            }
        }
    }
    // A click anywhere but on the menu closes it.
    MouseArea {
        anchors.fill: parent
        z: 7
        visible: root.mode === "menu"
        acceptedButtons: Qt.AllButtons
        onPressed: root.controller.cancel()
        onWheel: wheel => wheel.accepted = true
    }

    // The menu of a row: what applies to it, each line with the keys that do the same.
    NativeRoundedRectangle {
        id: menuBox

        readonly property real pad: 4 * root.ratio
        readonly property real lineHeight: Math.round(Math.max(root.typography.smallRow, (root.tinyGrid.cellHeight ?? 14) + 8 * root.ratio))
        readonly property real ruleHeight: 9 * root.ratio
        // Where the pointer asked for it, or below the selected row when the keys did.
        readonly property point asked: {
            if ((root.menu.x ?? -1) >= 0)
                return Qt.point(root.menu.x, root.menu.y);

            const pane = panes.itemAt(root.menu.window ?? 0);

            return pane ? pane.rowsArea.mapToItem(root, root.gutter + 40 * root.ratio, root.rowY((root.menu.row ?? 0) + 1)) : Qt.point(0, 0);
        }
        readonly property real wanted: {
            let widest = 250 * root.ratio;

            for (let index = 0; index < menuLines.count; ++index) {
                const line = menuLines.itemAt(index);
                if (line)
                    widest = Math.max(widest, line.wanted + 2 * pad);
            }

            return widest;
        }

        z: 8
        visible: root.mode === "menu" && (root.menu.lines ?? []).length > 0
        x: Math.round(Math.max(pad, Math.min(asked.x, root.width - width - pad)))
        y: Math.round(Math.max(pad, Math.min(asked.y, root.height - height - pad)))
        width: Math.min(wanted, root.width - 2 * pad)
        height: menuColumn.height + 2 * pad
        radius: 7 * root.ratio
        color: root.colors.surface0
        borderWidth: root.edge
        borderColor: root.colors.overlay0
        borderAlpha: 1

        Column {
            id: menuColumn
            x: menuBox.pad
            y: menuBox.pad
            width: parent.width - 2 * menuBox.pad

            Repeater {
                id: menuLines
                model: root.menu.lines ?? []

                delegate: Item {
                    id: menuLine

                    required property var modelData
                    required property int index
                    readonly property real wanted: modelData.rule ? 0 : menuLabel.implicitWidth + menuKeys.implicitWidth + 34 * root.ratio

                    width: menuColumn.width
                    height: modelData.rule ? menuBox.ruleHeight : menuBox.lineHeight

                    Rectangle {
                        x: 6 * root.ratio
                        y: Math.round((parent.height - height) / 2)
                        width: parent.width - 2 * x
                        height: root.edge
                        visible: menuLine.modelData.rule
                        color: root.colors.surface1
                    }

                    NativeRoundedRectangle {
                        anchors.fill: parent
                        visible: !menuLine.modelData.rule && menuLine.modelData.current
                        radius: 4 * root.ratio
                        color: root.colors.surface1
                    }

                    ChromeText {
                        id: menuLabel
                        x: 8 * root.ratio
                        width: implicitWidth
                        height: parent.height
                        visible: !menuLine.modelData.rule
                        text: menuLine.modelData.label ?? ""
                        pixelSize: root.labelSize
                        color: menuLine.modelData.enabled ? root.colors.text : root.colors.overlay0
                        elide: Text.ElideNone
                    }

                    CellText {
                        id: menuKeys
                        x: parent.width - width - 8 * root.ratio
                        width: implicitWidth
                        height: parent.height
                        visible: !menuLine.modelData.rule
                        text: menuLine.modelData.keys ?? ""
                        grid: root.tinyGrid
                        color: menuLine.modelData.enabled ? root.colors.subtext0 : root.colors.overlay0
                    }

                    ActionPointer {
                        anchors.fill: parent
                        enabled: !menuLine.modelData.rule && menuLine.modelData.enabled
                        identity: "menu:" + menuLine.index
                        onActivated: root.controller.chooseMenu(menuLine.index)
                    }
                }
            }
        }
    }

    // The pane that would take the rows dragged over it.
    NativeRoundedRectangle {
        z: 8
        visible: root.dragging && root.dropPane.length > 0
        x: root.dropPaneFrame.x
        y: root.dropPaneFrame.y
        width: root.dropPaneFrame.width
        height: root.dropPaneFrame.height
        radius: 6 * root.ratio
        color: Qt.alpha(root.colors.accent, 0.12)
        borderWidth: root.edge
        borderColor: root.colors.accent
        borderAlpha: 1
    }

    // What the pointer drags, said beside it: what letting go would do, and to how many rows.
    NativeRoundedRectangle {
        z: 9
        visible: root.dragging
        x: Math.round(Math.min(root.dragX + 12 * root.ratio, root.width - width - 4 * root.ratio))
        y: Math.round(Math.min(root.dragY + 8 * root.ratio, root.height - height - 4 * root.ratio))
        width: dragLabel.implicitWidth + 18 * root.ratio
        height: Math.round((root.smallGrid.cellHeight ?? 16) + 8 * root.ratio)
        radius: 4 * root.ratio
        color: root.colors.surface0
        borderWidth: root.edge
        borderColor: root.dropWindow >= 0 || root.dropPane.length > 0 ? root.colors.accent : root.colors.overlay0
        borderAlpha: 1

        CellText {
            id: dragLabel
            x: 9 * root.ratio
            width: implicitWidth
            height: parent.height
            text: (root.dropPane.length > 0 ? "to the pane · " : root.dropCopy ? "copy " : "move ") + root.dragCount
            grid: root.smallGrid
            color: root.dropWindow >= 0 || root.dropPane.length > 0 ? root.colors.text : root.colors.overlay1
        }
    }
}
