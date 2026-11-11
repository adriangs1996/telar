pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Telar.Gui

// telar's prompt line: the command editor in the scrollback, over the rows of the shell's prompt
// it stands in for and laid out as the separator the command becomes when it runs. A row of
// context (where the command runs, vim's mode) over the editor, and under it what the editor
// opens: Tab's choices, a history or path search. While a program runs, the next command, or a
// secret, is written on a line under its output. Out of view, the line docks at the bottom of
// the pane. It only draws; the terminal keeps the keyboard focus and hands keys to the session's
// editor.
Item {
    id: root

    required property var application
    required property string paneId
    required property var colors
    required property var grid
    property var terminal: null
    property real ratio: 1
    // Only the focused pane edits, queues, reads secrets and searches; another pane's line
    // waits dimmed, and the shell's own prompt stays hidden either way.
    property bool focused: true

    readonly property string surface: editor.surface
    readonly property bool editing: root.surface === "editor"
    readonly property bool running: root.surface === "running"
    readonly property bool secret: root.surface === "secret" && root.focused
    // While a program runs, typing writes the next command on a line of its own.
    readonly property bool queueing: root.running && root.focused && (!editor.empty || editor.queued)
    // The history or the paths, searched from the editor's row, the rows they find under it.
    // The scrollback search lives in the line of the pane copy mode reads, whatever runs there.
    readonly property bool scrollbackSearch: root.application.islandSearchPane === root.paneId && root.application.islandSearch === "copy-search"
    readonly property string search: (root.editing && root.focused || root.scrollbackSearch) && root.application.islandSearchPane === root.paneId ? root.application.islandSearch : ""
    readonly property bool searching: root.search.length > 0
    // The rows a search shows at most, newest or best nearest the query.
    readonly property int searchRows: 8
    readonly property bool moving: editor.motion !== "none"

    // The terminal's rows; the editor's text in the same font.
    readonly property real cell: editor.cellWidth
    readonly property real line: root.terminal && root.terminal.cell.height > 0 ? root.terminal.cell.height : editor.cellHeight
    readonly property int screenRows: root.terminal ? root.terminal.rows : 0
    // As a separator lays out its row: the pill, then the command.
    readonly property real pillX: root.cell * 0.5
    readonly property real pillHeight: Math.round(root.line * 0.72)
    readonly property real pillWidth: Math.max(root.pillHeight, root.cell * 2)
    readonly property real textX: root.pillX + root.pillWidth + root.cell
    readonly property real inset: root.docked ? 4 * root.ratio : 0

    // Where the line starts: over the shell's prompt, its context on the row above the
    // command's when the prompt has one to spare, else on the command's own; while a program
    // runs, under its cursor. -1 when that is out of view, and the line docks at the bottom.
    readonly property int anchor: {
        const terminal = root.terminal;
        if (!terminal) {
            return -1;
        }
        if (root.scrollbackSearch) {
            return -1;
        }
        if (root.editing) {
            const row = terminal.promptRow;
            if (row < 0) {
                return -1;
            }
            return terminal.promptTop >= 0 && terminal.promptTop < row ? row - 1 : row;
        }
        if (root.queueing || root.secret) {
            return terminal.cursorRow < 0 ? -1 : terminal.cursorRow + 1;
        }
        return -1;
    }
    readonly property bool shown: !root.flying && (root.editing || root.queueing || root.secret || root.scrollbackSearch)
    readonly property bool docked: root.shown && root.anchor < 0
    // How much of the pane's bottom the docked line covers, for what floats above it.
    readonly property real dockedHeight: root.docked ? body.height + root.inset * 2 : 0
    readonly property bool contextShown: root.editing && !root.searching && !root.flying
    readonly property bool inputShown: (root.editing && !root.searching && !root.flying) || root.queueing
    readonly property real editorY: root.inset + (root.editing ? root.line : 0)
    readonly property int menuRows: root.editing && !root.searching && editor.choices.length > 0 ? editor.choices.length + (editor.menuLabel.length > 0 ? 1 : 0) : 0
    // The menu just opened: its choices fall into place, which a new selection does not replay.
    property bool menuOpening: false
    property bool menuOpen: false
    onMenuRowsChanged: {
        const open = root.menuRows > 0;
        if (open && !root.menuOpen) {
            root.menuOpening = true;
            menuOpened.restart();
        }
        root.menuOpen = open;
    }
    Timer {
        id: menuOpened
        interval: 400
        onTriggered: root.menuOpening = false
    }
    readonly property int searchCount: root.search === "history" ? (root.application.historyState.count ?? 0) : root.search === "paths" ? (root.application.pathPickerState.count ?? 0) : 0
    readonly property int listRows: Math.max(1, Math.min(root.searchRows, root.searchCount, root.screenRows - 2))
    readonly property int rowCount: root.searching ? 2 + (root.scrollbackSearch ? 0 : root.listRows) : root.editing ? 1 + editor.visibleRows + root.menuRows : root.queueing ? editor.visibleRows : root.secret ? 2 : 0
    // The rows the line needs past the screen's last: the terminal rises by them, so the
    // line never covers output, and never so far that the line's first row leaves the view.
    readonly property int liftRows: root.shown && !root.docked ? Math.max(0, Math.min(root.anchor, root.anchor + root.rowCount - root.screenRows)) : 0
    readonly property real lift: root.liftRows * root.line

    // What the pane's separators show of the running command.
    readonly property string interruptKey: root.running ? editor.interruptKey : ""
    readonly property bool offerFailure: root.editing && root.focused

    width: root.terminal ? root.terminal.width : 0
    height: root.terminal ? root.terminal.height : 0

    // How a part enters and leaves: it fades into the next state's, rising into place out of a
    // slight blur. The blur takes a layer only while it fades.
    component Layer: Item {
        id: content
        property bool shown: false
        // Hidden at once instead of fading, as the editor's row is when it runs.
        property bool instant: false
        opacity: content.shown ? 1 : 0
        visible: content.opacity > 0 && !content.instant
        transform: Translate {
            y: content.shown ? 0 : 4 * root.ratio
            Behavior on y {
                enabled: root.moving
                NumberAnimation { duration: 340; easing.type: Easing.OutCubic }
            }
        }
        Behavior on opacity {
            enabled: root.moving
            NumberAnimation { duration: 220 }
        }
        layer.enabled: root.moving && content.opacity > 0 && content.opacity < 1
        layer.effect: MultiEffect {
            blurEnabled: true
            blurMax: Math.round(8 * root.ratio)
            blur: (1 - content.opacity) * 0.375
        }
    }

    // A key the user can press, framed.
    component Key: Rectangle {
        property alias text: label.text
        implicitWidth: label.implicitWidth + root.cell
        implicitHeight: root.line * 0.8
        width: implicitWidth
        height: implicitHeight
        radius: 4 * root.ratio
        color: "transparent"
        border.width: Math.max(1, root.ratio)
        border.color: Qt.alpha(root.colors.overlay1, 0.5)

        CellText {
            id: label
            text: ""
            anchors.centerIn: parent
            grid: root.grid
            color: root.colors.subtext0
        }
    }

    // A key and what it does.
    component Hint: Row {
        property alias key: hintKey.text
        property alias action: hintAction.text
        spacing: root.cell * 0.5
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined

        Key {
            id: hintKey
            anchors.verticalCenter: parent.verticalCenter
        }

        CellText {
            id: hintAction
            text: ""
            anchors.verticalCenter: parent.verticalCenter
            grid: root.grid
            color: root.colors.overlay1
        }
    }

    // A segment of the context that changed rises into place in the accent colour, which fades.
    component Segment: CellText {
        id: segment
        property real tint: 0
        grid: root.grid
        color: Qt.tint(root.colors.subtext0, Qt.alpha(root.colors.accent, segment.tint))

        function announce() {
            if (root.moving) {
                announcement.restart();
            }
        }

        ParallelAnimation {
            id: announcement
            NumberAnimation { target: segment; property: "y"; from: root.line * 0.8; to: 0; duration: 260; easing.type: Easing.OutCubic }
            NumberAnimation { target: segment; property: "opacity"; from: 0; to: 1; duration: 260 }
            SequentialAnimation {
                PropertyAction { target: segment; property: "tint"; value: 1 }
                PauseAnimation { duration: 1700 }
                NumberAnimation { target: segment; property: "tint"; to: 0; duration: 900 }
            }
        }
    }

    // When a key last changed the editor: the caret's blink waits for a pause.
    property double lastKey: 0
    Connections {
        target: editor
        function onLayoutChanged() {
            root.lastKey = Date.now();
            caret.on = true;
        }
    }

    // The directory, branch or host the next command runs in, announced where it shows.
    // Fitted to the columns before the mode's chip: the directory gives way first, to its last
    // two names, its last, then cut at its start; the branch is cut at its end, the host last.
    // When the whole context does not fit beside the chip the line turns compact: the chip
    // leaves its columns to the context and the pill wears the mode's colour instead.
    readonly property bool modeShown: statusRow.vim || statusRow.copying || statusRow.selecting
    readonly property real contextRoom: root.width - root.cell * 3 - root.pillX
    readonly property int wideColumns: root.cell > 0 ? Math.floor(Math.max(0, root.contextRoom - (root.modeShown ? modeChip.width + root.cell : 0)) / root.cell) : 0
    readonly property bool compact: root.modeShown && root.contextSpan(root.fitContext(Infinity, root.hostLabel, root.directory, root.branch)) > root.wideColumns
    readonly property int contextColumns: root.compact ? Math.floor(Math.max(0, root.contextRoom) / root.cell) : root.wideColumns
    readonly property var contextText: root.fitContext(root.contextColumns, root.hostLabel, root.directory, root.branch)
    function contextSpan(text) {
        const segments = [text.host, text.directory, text.branch].filter(segment => segment.length > 0);
        return segments.reduce((columns, segment) => columns + segment.length, 0) + 2 * Math.max(0, segments.length - 1) + (text.host.length > 0 ? root.chipColumns : 0);
    }
    function elide(text, columns, keepEnd) {
        if (text.length <= columns) {
            return text;
        }
        if (columns < 2) {
            return "";
        }
        return keepEnd ? "…" + text.slice(text.length - columns + 1) : text.slice(0, columns - 1) + "…";
    }
    // The host's chip pads its text by half a column each side.
    readonly property int chipColumns: 1
    function fitContext(columns, host, directory, branch) {
        const gap = 2;
        const hostText = host.length > 0 ? "⇄ " + host : "";
        // The chip's padding, beside the host's own columns.
        const hostColumns = hostText.length > 0 ? hostText.length + root.chipColumns + gap : 0;
        const branchText = branch.length > 0 ? "⎇ " + branch : "";
        const parts = directory.split("/").filter(part => part.length > 0);
        // A long path is shortened even when it fits, as it always was.
        const shapes = directory.length <= 48 || parts.length <= 2 ? [directory] : [];
        if (parts.length > 2) {
            shapes.push("…/" + parts.slice(-2).join("/"));
        }
        if (parts.length > 1) {
            shapes.push("…/" + parts[parts.length - 1]);
        }
        const last = shapes[shapes.length - 1];
        let room = columns - hostColumns - (branchText.length > 0 ? branchText.length + gap : 0);
        const fittedDirectory = shapes.find(shape => shape.length <= room) ?? root.elide(last, Math.max(room, Math.min(last.length, 8)), true);
        room = columns - fittedDirectory.length - hostColumns - gap;
        const fittedBranch = root.elide(branchText, room, false);
        room = columns - fittedDirectory.length - (fittedBranch.length > 0 ? fittedBranch.length + gap : 0) - gap - root.chipColumns;
        return {host: root.elide(hostText, room, false), directory: fittedDirectory, branch: fittedBranch};
    }
    property string knownDirectory: ""
    property string knownBranch: ""
    property string knownHost: ""
    readonly property string directory: editor.directory
    readonly property string branch: editor.branch
    readonly property string host: editor.remote ? (editor.host.length > 0 ? editor.host : "remote") : ""
    // The host, and the link's round trip once timed.
    readonly property string hostLabel: root.host.length > 0 && editor.link > 0 ? root.host + " · " + editor.link + " ms" : root.host
    onDirectoryChanged: {
        if (root.knownDirectory.length > 0 && root.directory !== root.knownDirectory) {
            directorySegment.announce();
        }
        root.knownDirectory = root.directory;
    }
    onBranchChanged: {
        if (root.knownDirectory.length > 0 && root.branch.length > 0 && root.branch !== root.knownBranch) {
            branchSegment.announce();
        }
        root.knownBranch = root.branch;
    }
    onHostChanged: {
        if (root.host.length > 0 && root.host !== root.knownHost) {
            hostSegment.announce();
        }
        root.knownHost = root.host;
    }

    // A run turns the line into its separator, on the row the shell's prompt was: the pill
    // becomes the command's ring, the context steps aside and the terminal settles under it.
    property int launchRow: -1
    property real lastEditorY: 0
    property real lastBodyY: 0
    Connections {
        target: root.terminal
        function onBlocksChanged() {
            if (root.terminal.promptRow >= 0) {
                root.launchRow = root.terminal.promptRow;
            }
        }
    }
    onEditorYChanged: root.remember()
    onInputShownChanged: root.remember()
    function remember() {
        if (root.inputShown && root.editing) {
            root.lastBodyY = body.y;
            root.lastEditorY = body.y + root.editorY;
        }
    }

    // The command the line launched last, by its index among the pane's commands, for its
    // separator to light up as it lands.
    property int landing: -1
    readonly property bool flying: flight.running
    property int seenLaunches: -1
    Component.onCompleted: {
        root.seenLaunches = editor.launches;
        root.knownDirectory = root.directory;
        root.knownBranch = root.branch;
        root.knownHost = root.host;
    }
    Connections {
        target: editor
        function onStateChanged() {
            if (editor.launches === root.seenLaunches) {
                return;
            }
            root.seenLaunches = editor.launches;
            const terminal = root.terminal;
            if (!root.moving || !root.visible || editor.lastCommand.length === 0 || !terminal) {
                return;
            }
            flyer.text = editor.lastCommand.split("\n")[0];
            flight.from = root.lastEditorY;
            flight.to = root.launchRow >= 0 ? root.launchRow * root.line : root.lastEditorY;
            root.landing = Math.min(terminal.rail.length, 63);
            terminal.holdOutput();
            flight.restart();
        }
    }

    Item {
        id: flyer
        property alias text: flyerText.text
        width: root.width
        height: root.line
        opacity: 0

        Rectangle {
            id: flyerPill
            x: root.pillX
            anchors.verticalCenter: parent.verticalCenter
            width: root.pillWidth
            height: root.pillHeight
            radius: height / 2
            color: Qt.alpha(root.colors.accent, 0.2)

            NativeProgressRing {
                anchors.centerIn: parent
                width: parent.height * 0.6
                height: width
                color: root.colors.accent
                fraction: 0.3
            }
        }

        CellText {
            id: flyerText
            x: root.textX
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            grid: root.grid
            color: root.colors.text
            bold: true
        }
    }

    // As short as the terminal's settling under it: the command already runs, and its output
    // waits for the separator to take its place.
    ParallelAnimation {
        id: flight
        property real from
        property real to
        NumberAnimation { target: flyer; property: "y"; from: flight.from; to: flight.to; duration: 220; easing.type: Easing.OutCubic }
        NumberAnimation { target: flyerPill; property: "scale"; from: 0.4; to: 1; duration: 220; easing.type: Easing.OutBack; easing.overshoot: 2.4 }
        SequentialAnimation {
            PropertyAction { target: flyer; property: "opacity"; value: 1 }
            PauseAnimation { duration: 190 }
            NumberAnimation { target: flyer; property: "opacity"; to: 0; duration: 30 }
        }
        // Landed: the output held meanwhile enters.
        onRunningChanged: {
            if (!flight.running && root.terminal) {
                root.terminal.releaseOutput();
            }
        }
    }

    // The line's rows, from its first.
    Item {
        id: body
        // Where it was while it turns into the separator, whatever the shell prints meanwhile.
        y: root.flying ? root.lastBodyY : root.docked ? root.height - body.height : Math.max(0, root.anchor) * root.line
        width: root.width
        height: root.rowCount * root.line + root.inset * 2
        visible: root.shown || root.flying
        onYChanged: root.remember()

        // Docked, the line covers the output under it.
        Rectangle {
            visible: root.docked
            anchors.fill: parent
            color: root.colors.elevated

            Rectangle {
                width: parent.width
                height: Math.max(1, root.ratio)
                color: Qt.alpha(root.colors.overlay1, 0.35)
            }
        }

        // A shell on another host: a violet edge down the line.
        Rectangle {
            visible: editor.remote && (root.contextShown || root.inputShown)
            x: 0
            y: root.inset
            width: 3 * root.ratio
            height: Math.max(0, (root.searching ? root.rowCount : root.rowCount - root.menuRows) * root.line)
            color: root.colors.mauve
        }

        // Where the command runs, and the editor's mode.
        Layer {
            id: context
            shown: root.contextShown
            y: root.inset
            width: parent.width
            height: root.line

            Row {
                id: place
                x: root.pillX
                width: Math.min(implicitWidth, root.contextColumns * root.cell)
                height: root.line
                spacing: root.cell * 2

                // Another host: a chip in the remote colour, as plain to see as the mode's.
                Item {
                    visible: root.contextText.host.length > 0
                    width: hostSegment.implicitWidth + root.cell * root.chipColumns
                    height: root.line

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: root.line * 0.8
                        radius: 4 * root.ratio
                        color: Qt.alpha(root.colors.mauve, 0.18)
                        border.width: Math.max(1, root.ratio)
                        border.color: Qt.alpha(root.colors.mauve, 0.45)
                    }

                    Segment {
                        id: hostSegment
                        x: root.cell * root.chipColumns / 2
                        height: root.line
                        text: root.contextText.host
                        color: Qt.tint(root.colors.mauve, Qt.alpha(root.colors.accent, hostSegment.tint))
                        bold: true
                    }
                }

                Segment {
                    id: directorySegment
                    visible: root.contextText.directory.length > 0
                    height: root.line
                    text: root.contextText.directory
                }

                Segment {
                    id: branchSegment
                    visible: root.contextText.branch.length > 0
                    height: root.line
                    text: root.contextText.branch
                }
            }

            Rectangle {
                x: place.x + place.width + root.cell
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, statusRow.x - x - root.cell)
                height: Math.max(1, root.ratio)
                color: Qt.alpha(root.colors.overlay1, 0.35)
            }

            Row {
                id: statusRow
                readonly property bool copying: editor.copying.length > 0
                readonly property bool selecting: editor.block > 0 && !statusRow.copying
                readonly property bool vim: editor.mode !== "emacs"
                x: parent.width - implicitWidth - root.cell * 2
                height: root.line
                spacing: root.cell

                // Each mode in its own colour, the label in the background's, as a status line.
                Rectangle {
                    id: modeChip
                    readonly property color tint: statusRow.copying ? root.colors.mauve : statusRow.selecting ? root.colors.accent : editor.mode === "insert" ? root.colors.green : editor.mode === "normal" ? root.colors.accent : root.colors.mauve
                    visible: root.modeShown && !root.compact
                    opacity: root.focused ? 1 : 0.45
                    anchors.verticalCenter: parent.verticalCenter
                    width: modeLabel.implicitWidth + root.cell
                    height: root.line * 0.8
                    radius: 4 * root.ratio
                    color: modeChip.tint
                    Behavior on color {
                        enabled: root.moving
                        ColorAnimation { duration: 150 }
                    }

                    CellText {
                        id: modeLabel
                        anchors.centerIn: parent
                        text: statusRow.copying ? (editor.copying === "copy" ? "COPY" : editor.copying === "visual" ? "VISUAL" : "V-LINE") : statusRow.selecting ? "BLOCK " + editor.block + "/" + editor.blocks : editor.mode === "insert" ? "INSERT" : editor.mode === "normal" ? "NORMAL" : editor.mode === "visual" ? "VISUAL" : "V-LINE"
                        grid: root.grid
                        color: root.colors.background
                        bold: true
                    }
                }
            }
        }

        // The editor's pill, and the keys that act on what shows at the end of its last row.
        Layer {
            id: input
            shown: root.inputShown
            instant: root.flying
            y: root.editorY
            width: parent.width
            height: editor.visibleRows * root.line

            Rectangle {
                id: pill
                readonly property color tone: !root.focused ? root.colors.overlay1 : root.queueing ? root.colors.overlay1 : editor.failed ? root.colors.red : root.compact ? modeChip.tint : editor.remote ? root.colors.mauve : root.colors.accent
                x: root.pillX
                y: (root.line - height) / 2
                width: root.pillWidth
                height: root.pillHeight
                radius: height / 2
                color: Qt.alpha(pill.tone, root.queueing || !root.focused ? 0.14 : 0.18)
                Behavior on color {
                    enabled: root.moving
                    ColorAnimation { duration: 200 }
                }

                // vim's normal and visual modes turn the mark around.
                CellText {
                    anchors.centerIn: parent
                    text: editor.mode === "normal" || editor.mode.startsWith("visual") ? "❮" : "❯"
                    grid: root.grid
                    color: pill.tone
                    bold: true
                }
            }

            Row {
                id: trailing
                readonly property bool menuOpen: editor.choices.length > 0
                readonly property bool copying: editor.copying.length > 0
                readonly property bool selecting: editor.block > 0 && !trailing.copying
                readonly property bool editing: root.editing && !trailing.copying && !trailing.selecting
                visible: root.focused && (root.queueing || trailing.copying || trailing.selecting || editor.suggesting || trailing.menuOpen)
                x: parent.width - implicitWidth - root.cell * 2
                y: parent.height - root.line
                height: root.line
                spacing: root.cell

                Hint {
                    visible: trailing.editing && editor.suggesting && !trailing.menuOpen
                    key: "→"
                    action: "accept"
                }

                Hint {
                    visible: trailing.editing && editor.suggesting && !trailing.menuOpen
                    key: "⌥→"
                    action: "word"
                }

                Hint {
                    visible: trailing.editing && trailing.menuOpen
                    key: "⇥"
                    action: "next"
                }

                Hint {
                    visible: trailing.editing && trailing.menuOpen
                    key: "⏎"
                    action: "take"
                }

                Hint {
                    visible: trailing.editing && trailing.menuOpen
                    key: "esc"
                    action: "close"
                }

                Hint {
                    visible: trailing.selecting
                    key: "⌃U ⌃D"
                    action: "move"
                }

                Hint {
                    visible: trailing.selecting
                    key: "v"
                    action: "select"
                }

                Hint {
                    visible: trailing.selecting
                    key: "Y"
                    action: "copy"
                }

                Hint {
                    visible: trailing.copying
                    key: "y"
                    action: "copy"
                }

                Hint {
                    visible: trailing.selecting || trailing.copying
                    key: "esc"
                    action: "back"
                }

                // A line written while a program runs waits for it, or goes to it.
                Hint {
                    visible: root.queueing && !editor.queued && !editor.answering
                    key: "⏎"
                    action: "queue"
                }

                Hint {
                    visible: root.queueing && !editor.queued
                    key: "⌥⏎"
                    action: editor.answering ? "queue" : "to program"
                }

                Key {
                    id: queuedKey
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.queueing && (editor.queued || editor.answering)
                    text: editor.answering ? "to program" : "queued"
                    onVisibleChanged: {
                        if (queuedKey.visible && root.moving) {
                            armed.restart();
                        }
                    }

                    NumberAnimation {
                        id: armed
                        target: queuedKey
                        property: "scale"
                        from: 0.4
                        to: 1
                        duration: 320
                        easing.type: Easing.OutBack
                        easing.overshoot: 2.4
                    }
                }
            }
        }

        // Tab's choices, under the command they would complete, below a heading that says
        // where they come from.
        Layer {
            id: menu
            shown: root.menuRows > 0
            y: root.editorY + editor.visibleRows * root.line
            width: parent.width
            height: Math.max(root.menuRows, 1) * root.line

            CellText {
                id: menuHeading
                visible: editor.menuLabel.length > 0
                x: root.textX
                height: root.line
                text: editor.menuLabel
                grid: root.grid
                color: root.colors.overlay1
            }

            // The selection slides from one choice to the next.
            Rectangle {
                id: selection
                readonly property real offset: menuHeading.visible ? root.line : 0
                visible: editor.choice >= 0
                width: parent.width
                height: root.line
                y: offset + Math.max(0, editor.choice) * root.line
                radius: 4 * root.ratio
                color: Qt.alpha(root.colors.accent, 0.16)
                Behavior on y {
                    enabled: root.moving
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }

                Rectangle {
                    width: 2 * root.ratio
                    height: parent.height
                    color: root.colors.accent
                }
            }

            Column {
                y: selection.offset
                width: parent.width

                Repeater {
                    model: editor.choices
                    delegate: Item {
                        id: entry
                        required property var modelData
                        required property int index
                        width: menu.width
                        height: root.line
                        opacity: 0
                        Component.onCompleted: {
                            if (root.moving && root.menuOpening) {
                                entrance.start();
                            } else {
                                entry.opacity = 1;
                            }
                        }

                        // The choices fall into place one after another.
                        SequentialAnimation {
                            id: entrance
                            PauseAnimation { duration: Math.min(entry.index, 7) * 20 }
                            ParallelAnimation {
                                NumberAnimation { target: entry; property: "opacity"; from: 0; to: 1; duration: 220 }
                                NumberAnimation { target: entryShift; property: "y"; from: 4 * root.ratio; to: 0; duration: 340; easing.type: Easing.OutCubic }
                            }
                        }
                        transform: Translate { id: entryShift }

                        // The letters what was typed matches, marked.
                        Row {
                            id: choiceText
                            x: root.textX
                            anchors.verticalCenter: parent.verticalCenter

                            Repeater {
                                model: entry.modelData.segments
                                delegate: CellText {
                                    required property var modelData
                                    text: modelData.text
                                    grid: root.grid
                                    bold: modelData.marked
                                    color: modelData.marked ? root.colors.accent : entry.modelData.selected ? root.colors.text : root.colors.subtext0
                                }
                            }
                        }

                        // The description takes the room the choice leaves, cut at the line's end.
                        Item {
                            x: Math.max(choiceText.x + choiceText.implicitWidth + root.cell * 3, menu.width * 0.4)
                            width: Math.max(0, menu.width - x - root.cell * 2)
                            height: parent.height
                            clip: true

                            CellText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: entry.modelData.description
                                grid: root.grid
                                color: root.colors.overlay1
                            }
                        }
                    }
                }
            }
        }

        // A program reading a secret, under where it asks: what asks, a dot per key and a
        // reminder that telar neither draws nor keeps it.
        Layer {
            id: secretLayer
            shown: root.secret
            y: root.inset
            width: parent.width
            height: root.line * 2

            Row {
                x: root.pillX
                height: root.line
                spacing: root.cell

                CellText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\u{1F512}"
                    grid: root.grid
                    color: root.colors.peach
                }

                CellText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: editor.program.length > 0 ? editor.program + " reads hidden input" : "hidden input"
                    grid: root.grid
                    color: root.colors.text
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(2 * root.cell, dots.implicitWidth + root.cell)
                    height: root.line * 0.8
                    radius: 6 * root.ratio
                    color: Qt.alpha(root.colors.overlay1, 0.18)

                    Row {
                        id: dots
                        anchors.centerIn: parent
                        spacing: 5 * root.ratio

                        Repeater {
                            model: editor.secretKeys
                            delegate: Rectangle {
                                id: secretDot
                                width: 7 * root.ratio
                                height: width
                                radius: width / 2
                                color: root.colors.peach
                                Component.onCompleted: {
                                    if (root.moving) {
                                        popIn.start();
                                    }
                                }

                                NumberAnimation {
                                    id: popIn
                                    target: secretDot
                                    property: "scale"
                                    from: 0.4
                                    to: 1
                                    duration: 260
                                    easing.type: Easing.OutBack
                                    easing.overshoot: 2.4
                                }
                            }
                        }
                    }
                }

                Key {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "⏎"
                }
            }

            CellText {
                x: root.textX
                y: root.line
                height: root.line
                text: "echo is off: telar neither draws nor keeps it"
                grid: root.grid
                color: root.colors.overlay1
            }
        }

        // A history or path search in place of the editor: what it searches on the context's
        // row, the query on the editor's and the rows it found under it, newest or best first.
        Layer {
            id: searchLayer
            shown: root.searching
            y: root.inset
            width: parent.width
            height: (2 + (root.scrollbackSearch ? 0 : root.listRows)) * root.line

            Loader {
                id: search
                width: parent.width
                active: root.searching
                sourceComponent: root.scrollbackSearch ? scrollbackView : searchView
                onActiveChanged: {
                    if (!search.active) {
                        Qt.callLater(root.abandonSearch);
                    }
                }
            }
        }
    }

    // A search the line stops hosting while it is open, as when its pane loses the focus,
    // closes; so does one whose field loses the keyboard to a click elsewhere in the window.
    function abandonSearch() {
        if (!root.searching && root.application.islandSearch.length > 0 && root.application.islandSearchPane === root.paneId) {
            root.application.execute(GuiController.Action.cancel);
        }
    }

    function keepSearch() {
        const view = search.item;
        const window = root.Window.window;
        if (!root.searching || !view || view.focused || view.inspecting || !window || !window.active) {
            return;
        }
        root.application.execute(GuiController.Action.cancel);
    }

    Component.onDestruction: {
        if (root.application.islandSearchPane === root.paneId && root.application.islandSearch.length > 0) {
            root.application.execute(GuiController.Action.cancel);
        }
    }

    // `text` on one line in runs, with the letters `query` finds in it marked: the query itself
    // if it shows, else its letters in order, as the fuzzy search reads it.
    function marked(text, query) {
        const line = text.length > 240 ? text.slice(0, 240).replace(/\n/g, " ↵ ") : text.replace(/\n/g, " ↵ ");
        if (query.length === 0) {
            return [{text: line, marked: false}];
        }

        const lower = line.toLowerCase();
        const wanted = query.toLowerCase();
        const marks = new Array(line.length).fill(false);
        const at = lower.indexOf(wanted);
        if (at >= 0) {
            marks.fill(true, at, at + wanted.length);
        } else {
            let next = 0;
            for (let index = 0; index < line.length && next < wanted.length; ++index) {
                if (lower[index] === wanted[next]) {
                    marks[index] = true;
                    ++next;
                }
            }
            if (next < wanted.length) {
                return [{text: line, marked: false}];
            }
        }

        const runs = [];
        for (let index = 0; index < line.length; ++index) {
            if (runs.length > 0 && runs[runs.length - 1].marked === marks[index]) {
                runs[runs.length - 1].text += line[index];
            } else {
                runs.push({text: line[index], marked: marks[index]});
            }
        }
        return runs;
    }

    // The scrollback searched as it is typed: what it reads and how many it found on the
    // context's row, the query on the editor's. Every match is lit in the pane, the one the
    // cursor is on more.
    Component {
        id: scrollbackView

        Item {
            id: scrollback
            readonly property var current: root.application.copySearchState
            readonly property bool focused: query.activeFocus
            readonly property bool inspecting: false
            height: 2 * root.line

            Component.onCompleted: query.forceActiveFocus()

            // Each letter asks again, a moment after the last.
            Timer {
                id: typing
                interval: 90
                onTriggered: root.application.searchScrollback(query.text)
            }

            CellText {
                x: root.pillX
                width: Math.max(0, count.x - x - root.cell * 2)
                height: root.line
                clip: true
                text: scrollback.current.scope.length > 0 ? "in " + scrollback.current.scope : "whole scrollback"
                grid: root.grid
                color: root.colors.subtext0
            }

            CellText {
                id: count
                readonly property bool none: scrollback.current.query.length > 0 && !scrollback.current.searching && scrollback.current.count === 0
                x: parent.width - implicitWidth - root.cell * 2
                height: root.line
                text: scrollback.current.query.length === 0 ? "" : scrollback.current.searching ? "searching…" : count.none ? "no matches" : (scrollback.current.index + 1) + "/" + scrollback.current.count + (scrollback.current.truncated ? "+" : "")
                grid: root.grid
                color: count.none ? root.colors.red : root.colors.overlay1
            }

            Rectangle {
                id: slash
                x: root.pillX
                y: root.line + (root.line - height) / 2
                width: slashLabel.implicitWidth + root.cell
                height: root.line * 0.8
                radius: 4 * root.ratio
                color: root.colors.accent

                CellText {
                    id: slashLabel
                    anchors.centerIn: parent
                    text: "/"
                    grid: root.grid
                    color: root.colors.background
                    bold: true
                }
            }

            FormTextField {
                id: query
                objectName: "scrollbackSearch"
                x: slash.x + slash.width + root.cell
                y: root.line
                width: Math.max(0, (keys.visible ? keys.x : parent.width) - x - root.cell)
                height: root.line
                colors: root.colors
                typography: root.application.windowGeometry.typography
                ratio: root.ratio
                formControl: false
                drawsCaret: false
                maximumBytes: 128
                placeholderText: "Search"
                Accessible.name: "Search the scrollback"
                onTextEdited: typing.restart()
                onActiveFocusChanged: {
                    if (!query.activeFocus) {
                        Qt.callLater(root.keepSearch);
                    }
                }
                Keys.onUpPressed: root.application.stepScrollbackMatch(false)
                Keys.onDownPressed: root.application.stepScrollbackMatch(true)
                Keys.onReturnPressed: {
                    typing.stop();
                    root.application.searchScrollback(query.text);
                    root.application.finishScrollbackSearch();
                }
                Keys.onEnterPressed: {
                    typing.stop();
                    root.application.searchScrollback(query.text);
                    root.application.finishScrollbackSearch();
                }
                Keys.onTabPressed: {
                    if (scrollback.current.scopes) {
                        typing.stop();
                        root.application.toggleCopySearchScope();
                    }
                }
                Keys.onEscapePressed: {
                    if (query.cancelComposition()) {
                        return;
                    }
                    // Nothing found: the cursor goes back where the search began.
                    typing.stop();
                    root.application.searchScrollback("");
                    root.application.execute(GuiController.Action.cancel);
                }
            }

            Rectangle {
                readonly property rect at: query.regions.caret ?? Qt.rect(0, 0, 0, 0)
                visible: query.activeFocus && (query.regions.available ?? false)
                x: query.x + at.x
                y: query.y + at.y + at.height * 0.12
                width: Math.max(1, 2 * root.ratio)
                height: at.height * 0.76
                radius: width / 2
                color: root.colors.accent
            }

            Row {
                id: keys
                readonly property var hints: (scrollback.current.scopes ? [{key: "⇥", action: scrollback.current.scope.length > 0 ? "everywhere" : "this command"}] : []).concat([{key: "↑↓", action: "match"}, {key: "⏎", action: "done"}, {key: "esc", action: "close"}])
                visible: parent.width - implicitWidth - slash.width > 32 * root.cell
                x: parent.width - implicitWidth - root.cell * 2
                y: root.line
                height: root.line
                spacing: root.cell

                Repeater {
                    model: keys.hints
                    delegate: Hint {
                        required property var modelData
                        key: modelData.key
                        action: modelData.action
                    }
                }
            }
        }
    }

    Component {
        id: searchView

        Item {
            id: view
            readonly property bool history: root.search === "history"
            readonly property var current: view.history ? root.application.historyState : root.application.pathPickerState
            readonly property int count: view.current.count ?? 0
            readonly property int rows: root.listRows
            readonly property real listHeight: view.rows * root.line
            readonly property bool focused: field.activeFocus
            // The inspector shows the selected command's output in a dialog over the line.
            readonly property bool inspecting: view.history && view.current.inspecting
            property bool retiring: false
            height: (2 + view.rows) * root.line

            HistoryKeys {
                id: historyKeys
                controller: root.application
                queryField: field
                downward: true
            }

            PathKeys {
                id: pathKeys
                controller: root.application
            }

            function synchronize() {
                if (field.text !== view.current.editorText) {
                    field.text = view.current.editorText;
                    field.cursorPosition = field.text.length;
                }
            }

            function focusField() {
                if (root.searching && !view.inspecting && !field.activeFocus) {
                    field.forceActiveFocus();
                }
            }

            function reveal() {
                if (commands.count > 0 && commands.currentIndex >= 0) {
                    commands.positionViewAtIndex(commands.currentIndex, ListView.Contain);
                }
            }

            // The paths shown keep their place until the selection leaves them.
            function follow() {
                const selection = view.current.selection ?? 0;
                let first = paths.first;
                if (selection < first) {
                    first = selection;
                } else if (selection >= first + view.rows) {
                    first = selection - view.rows + 1;
                }
                paths.first = Math.max(0, Math.min(first, view.count - view.rows));
            }

            Component.onCompleted: {
                view.synchronize();
                view.follow();
                field.forceActiveFocus();
            }

            Connections {
                target: root.application
                function onHistoryChanged() {
                    if (view.history) {
                        view.synchronize();
                        Qt.callLater(view.focusField);
                    }
                }
                function onPathPickerChanged() {
                    if (!view.history) {
                        view.synchronize();
                        view.follow();
                    }
                }
            }

            Connections {
                target: view.history ? root.application.history : null
                function onRowsAboutToBeRemoved() {
                    view.retiring = true;
                }
                function onRowsRemoved() {
                    Qt.callLater(() => view.retiring = false);
                }
            }

            // What the search looks in, and how much it found, on the context's row.
            CellText {
                x: root.pillX
                width: Math.max(0, found.x - x - root.cell * 2)
                height: root.line
                clip: true
                text: view.history ? view.current.scopeLabel + (view.current.scopeValue ? " " + view.current.scopeValue : "") + " · " + view.current.authorLabel + (view.current.failedOnly ? " · Failed" : "") : view.current.rootLabel
                grid: root.grid
                color: root.colors.subtext0
            }

            CellText {
                id: found
                readonly property bool failed: view.history ? (view.current.error ?? "").length > 0 : view.current.failed
                x: parent.width - implicitWidth - root.cell * 2
                height: root.line
                text: view.history ? (found.failed ? view.current.error : root.application.historyLoading ? "searching…" : view.count + (view.current.hasMore ? "+" : "") + (view.count === 1 ? " command" : " commands")) : found.failed ? view.current.status : view.current.countText
                grid: root.grid
                color: found.failed ? root.colors.red : root.colors.overlay1
            }

            // The query, in the editor's row: what is searched, then the keys that act on it.
            Rectangle {
                id: chip
                x: root.pillX
                y: root.line + (root.line - height) / 2
                width: chipLabel.implicitWidth + root.cell
                height: root.line * 0.8
                radius: 4 * root.ratio
                color: root.colors.accent

                CellText {
                    id: chipLabel
                    anchors.centerIn: parent
                    text: view.history ? "HISTORY" : "PATHS"
                    grid: root.grid
                    color: root.colors.background
                    bold: true
                }
            }

            FormTextField {
                id: field
                objectName: "promptSearch"
                x: chip.x + chip.width + root.cell
                y: root.line
                width: Math.max(0, (hints.visible ? hints.x : parent.width) - x - root.cell)
                height: root.line
                colors: root.colors
                typography: root.application.windowGeometry.typography
                ratio: root.ratio
                formControl: false
                drawsCaret: false
                maximumBytes: view.current.maximumQueryBytes ?? 0
                placeholderText: view.history ? "Search commands" : "Search paths"
                Accessible.name: view.history ? "Search commands" : "Search paths"
                onTextEdited: view.history ? root.application.searchHistory(text) : root.application.searchPaths(text)
                onLimitReached: requested => view.history ? root.application.reportHistoryQueryLimit(requested) : root.application.reportPathQueryLimit(requested)
                onActiveFocusChanged: {
                    if (!field.activeFocus) {
                        Qt.callLater(root.keepSearch);
                    }
                }
                // The rows run down from the query: down goes to an older command, a worse path.
                Keys.onUpPressed: view.history ? historyKeys.moveSelection(-1) : root.application.movePathSelection(-1)
                Keys.onDownPressed: view.history ? historyKeys.moveSelection(1) : root.application.movePathSelection(1)
                Keys.onReturnPressed: event => view.history ? historyKeys.submit(event) : pathKeys.submit(event)
                Keys.onEnterPressed: event => view.history ? historyKeys.submit(event) : pathKeys.submit(event)
                Keys.onTabPressed: event => view.history ? historyKeys.cycleFilter(event) : root.application.descendPath()
                Keys.onBacktabPressed: event => view.history ? historyKeys.cycleFilter(event) : root.application.ascendPath()
                Keys.onEscapePressed: {
                    if (field.cancelComposition()) {
                        return;
                    }
                    if (view.history) {
                        historyKeys.cancel();
                    } else {
                        root.application.execute(GuiController.Action.cancel);
                    }
                }
                Keys.onPressed: event => event.accepted = view.history ? historyKeys.handle(event) : pathKeys.handle(event)
            }

            // The editor's caret: a solid bar in the accent colour.
            Rectangle {
                readonly property rect at: field.regions.caret ?? Qt.rect(0, 0, 0, 0)
                visible: field.activeFocus && (field.regions.available ?? false)
                x: field.x + at.x
                y: field.y + at.y + at.height * 0.12
                width: Math.max(1, 2 * root.ratio)
                height: at.height * 0.76
                radius: width / 2
                color: root.colors.accent
            }

            Row {
                id: hints
                readonly property var keys: view.history ? [{key: "⇥", action: "scope"}, {key: view.current.inspectionKey ?? "", action: "output"}, {key: "⏎", action: view.current.enterRuns ? "run" : "edit"}, {key: "esc", action: "close"}] : [{key: "⇥", action: "open"}, {key: "⇧⇥", action: "up"}, {key: "⏎", action: "insert"}, {key: "esc", action: "close"}]
                // The query keeps room for a few words; the keys give way first.
                visible: parent.width - implicitWidth - chip.width > 32 * root.cell
                x: parent.width - implicitWidth - root.cell * 2
                y: root.line
                height: root.line
                spacing: root.cell

                Repeater {
                    model: hints.keys
                    delegate: Hint {
                        required property var modelData
                        key: modelData.key
                        action: modelData.action
                    }
                }
            }

            CellText {
                visible: view.count === 0
                x: root.textX
                y: root.line * 2
                height: root.line
                text: view.history ? (root.application.historyLoading ? "Searching…" : (view.current.query ?? "").length > 0 ? "No command matches" : "No commands yet") : view.current.emptyText
                grid: root.grid
                color: root.colors.overlay1
            }

            // The commands, newest first under the query; the selection slides between them.
            ListView {
                id: commands
                visible: view.history
                y: root.line * 2
                width: parent.width
                height: view.listHeight
                clip: true
                model: view.history && !view.retiring ? root.application.history : null
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: view.history ? view.current.selection : -1
                highlightFollowsCurrentItem: true
                highlightMoveDuration: root.moving ? 180 : 0
                onCurrentIndexChanged: Qt.callLater(view.reveal)
                highlight: Rectangle {
                    width: commands.width
                    radius: 4 * root.ratio
                    color: Qt.alpha(root.colors.accent, 0.16)

                    Rectangle {
                        width: 2 * root.ratio
                        height: parent.height
                        color: root.colors.accent
                    }
                }

                delegate: Item {
                    id: historyEntry
                    required property int index
                    required property var record
                    width: commands.width
                    height: root.line

                    CellText {
                        x: root.pillX + root.cell
                        anchors.verticalCenter: parent.verticalCenter
                        text: historyEntry.record?.statusGlyph ?? ""
                        grid: root.grid
                        color: root.colors[historyEntry.record?.statusColor] ?? root.colors.overlay1
                    }

                    Item {
                        x: root.textX
                        width: Math.max(0, meta.x - x - root.cell * 2)
                        height: parent.height
                        clip: true

                        Row {
                            anchors.verticalCenter: parent.verticalCenter

                            Repeater {
                                model: root.marked(historyEntry.record?.command ?? "", view.current.query ?? "")
                                delegate: CellText {
                                    required property var modelData
                                    text: modelData.text
                                    grid: root.grid
                                    bold: modelData.marked
                                    color: modelData.marked ? root.colors.accent : historyEntry.index === commands.currentIndex ? root.colors.text : root.colors.subtext0
                                }
                            }
                        }
                    }

                    // Where it ran, when the search spans directories, and when.
                    CellText {
                        id: meta
                        readonly property bool spans: view.current.effectiveScope === "global" || view.current.effectiveScope === "workspace"
                        x: parent.width - implicitWidth - root.cell * 2
                        anchors.verticalCenter: parent.verticalCenter
                        text: (meta.spans && (historyEntry.record?.compactCwd ?? "").length > 0 ? historyEntry.record.compactCwd + "  " : "") + (historyEntry.record?.date ?? "")
                        grid: root.grid
                        color: root.colors.overlay1
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.application.selectHistoryRow(historyEntry.index)
                        onDoubleClicked: root.application.useHistoryRow(historyEntry.index, false)
                    }
                }
            }

            // The paths, best first under the query.
            Item {
                id: paths
                property int first: 0
                readonly property int columns: Math.max(1, Math.floor((paths.width - root.textX - root.cell * 2) / Math.max(1, root.cell)))
                readonly property var rows: view.history ? [] : paths.layout(view.current)
                visible: !view.history
                y: root.line * 2
                width: parent.width
                height: view.listHeight
                clip: true

                // Takes the state so a new page or selection lays the rows out again.
                function layout(state) {
                    return state ? root.application.pathPickerRows(paths.columns, paths.first, view.rows) : [];
                }

                Repeater {
                    model: paths.rows
                    delegate: Item {
                        id: pathRow
                        required property var modelData
                        required property int index
                        y: pathRow.index * root.line
                        width: paths.width
                        height: root.line

                        Rectangle {
                            visible: pathRow.modelData.selected
                            anchors.fill: parent
                            radius: 4 * root.ratio
                            color: Qt.alpha(root.colors.accent, 0.16)

                            Rectangle {
                                width: 2 * root.ratio
                                height: parent.height
                                color: root.colors.accent
                            }
                        }

                        CellText {
                            x: root.pillX + root.cell
                            anchors.verticalCenter: parent.verticalCenter
                            text: pathRow.modelData.directory ? "" : ""
                            grid: root.grid
                            color: pathRow.modelData.directory ? root.colors.blue : root.colors.subtext0
                        }

                        Row {
                            x: root.textX
                            anchors.verticalCenter: parent.verticalCenter

                            Repeater {
                                model: pathRow.modelData.runs
                                delegate: CellText {
                                    required property var modelData
                                    text: modelData.text
                                    grid: root.grid
                                    bold: modelData.bold
                                    color: root.colors[modelData.colorRole] ?? root.colors.text
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.application.activatePath({path: pathRow.modelData.path, revision: view.current.revision, absolute: false})
                        }
                    }
                }
            }
        }
    }

    NativePromptEditor {
        id: editor
        application: root.application
        paneId: root.paneId
        grid: root.grid
        colors: root.colors
        preedit: root.terminal ? root.terminal.preeditText : ""
        // A key brings the editor back at once; only a run hides it at once.
        opacity: root.inputShown ? (root.focused || root.queueing ? 1 : 0.6) : 0
        visible: editor.opacity > 0 && !root.flying
        Behavior on opacity {
            enabled: root.moving
            NumberAnimation { duration: 200 }
        }
        // The editor lays its text out from a two-column indent: the text starts where a
        // separator's command does.
        x: root.textX - root.cell * 2
        y: body.y + root.editorY
        width: editor.columns * root.cell + root.cell
        height: editor.visibleRows * root.line
        maximumColumns: Math.max(8, Math.floor((root.width - editor.x - (trailing.visible && trailing.implicitWidth > 0 ? trailing.implicitWidth + root.cell * 3 : root.cell * 2)) / Math.max(1, root.cell)) - 1)

        // A completion sweeping in glows in the accent colour as it settles.
        Repeater {
            model: editor.glows.length
            delegate: RectangularShadow {
                required property int index
                readonly property var glow: editor.glows[index] ?? {x: 0, y: 0, width: 0, height: 0, strength: 0}
                x: glow.x
                y: glow.y + glow.height * 0.2
                width: glow.width
                height: glow.height * 0.6
                z: -1
                radius: height / 2
                blur: 10 * root.ratio
                color: root.colors.accent
                opacity: 0.55 * glow.strength
            }
        }

        // The caret slides to where it goes and blinks while the keyboard rests; a block in
        // vim's normal mode.
        Rectangle {
            id: caret
            readonly property bool block: editor.mode === "normal" || editor.mode.startsWith("visual")
            property bool on: true
            x: editor.caret.x
            y: editor.caret.y + (block ? 0 : editor.caret.height * 0.12)
            width: block ? editor.caret.width : Math.max(1, 2 * root.ratio)
            height: block ? editor.caret.height : editor.caret.height * 0.76
            radius: block ? 2 * root.ratio : width / 2
            color: root.colors.accent
            opacity: block ? 0.5 : caret.on ? 1 : 0.15
            visible: root.focused && root.inputShown
            Behavior on x {
                enabled: root.moving
                NumberAnimation { duration: 40; easing.type: Easing.OutCubic }
            }
            Behavior on y {
                enabled: root.moving
                NumberAnimation { duration: 40; easing.type: Easing.OutCubic }
            }
            Behavior on width {
                enabled: root.moving
                NumberAnimation { duration: 120 }
            }
        }

        // Steady while typing, then on for a little more than half of each second.
        Timer {
            interval: caret.on ? 583 : 477
            repeat: true
            running: root.moving && caret.visible && !caret.block && root.visible
            onTriggered: caret.on = Date.now() - root.lastKey < 600 || !caret.on
            onRunningChanged: caret.on = true
        }
    }

    // The input method composes at the line's caret, not at the hidden shell prompt.
    Binding {
        target: root.terminal
        when: root.terminal !== null
        property: "promptCaret"
        value: root.focused && root.inputShown && root.visible ? editor.mapToItem(root.terminal, editor.caret.x, editor.caret.y, editor.caret.width, editor.caret.height) : Qt.rect(0, 0, 0, 0)
    }
}
