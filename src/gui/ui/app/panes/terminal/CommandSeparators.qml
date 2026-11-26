pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The commands the shell ran, each drawn over the rows its prompt and command line took: how
// it ended, its first line, a rule and how long it ran. The one running turns its ring, sends a
// light along its rule and counts its time. An ssh whose remote shell took over the pane names
// the host and counts the session's time, and an edge marks the rows that session covers. Only
// its chevron, its status and command, and the buttons it shows under the pointer take clicks;
// the terminal under it keeps the rest of the pointer and the keyboard.
Item {
    id: root

    required property var view
    required property var colors
    required property var grid
    property real ratio: 1
    property bool moving: true
    // The key that interrupts the running command, shown beside its time while nothing waits
    // to run after it; and whether the program reads a secret, which tints it.
    property string interruptKey: ""
    property bool queueing: false
    property bool secret: false
    // The editor waits for a command: the last command's separator offers its error if it failed.
    property bool offerFailure: false
    // How far this item is moved up from the view's top, which the pinned separator undoes.
    property real pinnedOffset: 0
    readonly property bool pinning: root.view !== null && root.view.stickyBlock.index !== undefined
    // What the pinned separator shows while no command is pinned.
    readonly property var unpinned: ({index: -1, key: -1, row: 0, command: "", lines: 0, state: "succeeded", status: 0, duration: 0, selected: false, folded: false, foldable: false, rows: 0, push: 0})
    // How each command was last drawn, so a separator built again does not replay its entrance,
    // and when each running one was first seen, for its time. Commands are known by their stable
    // key, which stays as older commands drop from the scrollback; what was kept for a command
    // gone goes with it.
    property var drawn: ({})
    property var started: ({})
    readonly property var rail: root.view ? root.view.rail : []
    onRailChanged: {
        const kept = {};
        for (const block of root.rail) {
            kept[String(block.key)] = true;
        }
        for (const key of Object.keys(root.started)) {
            if (!(key in kept)) {
                delete root.started[key];
            }
        }
        for (const key of Object.keys(root.drawn)) {
            if (!(key in kept)) {
                delete root.drawn[key];
            }
        }
    }

    // The command whose copy was last asked for, and what to say about it, for a moment.
    property int copiedIndex: -1
    property string copiedText: ""
    property bool copiedOk: true
    Timer {
        id: copiedShown
        interval: 1400
        onTriggered: root.copiedIndex = -1
    }
    Connections {
        target: root.view
        function onBlockCopied(index, what, copied) {
            root.copiedIndex = index;
            root.copiedOk = copied;
            root.copiedText = copied ? (what === "command" ? "command copied" : "output copied") : "no output to copy";
            copiedShown.restart();
        }
    }

    readonly property int last: root.rail.length - 1
    readonly property bool anyRunning: root.anyIn("running")
    // A session's clock only needs its seconds.
    readonly property bool anySession: root.anyIn("session")
    function anyIn(state) {
        const separators = root.view ? root.view.separators : [];
        for (let index = 0; index < separators.length; ++index) {
            if (separators[index].state === state) {
                return true;
            }
        }
        return false;
    }

    // A session's clock ticks by the second, so it reads whole ones.
    function duration(milliseconds, seconds) {
        return milliseconds < 60000 ? (milliseconds / 1000).toFixed(seconds ? 0 : 1) + "s" : Math.floor(milliseconds / 60000) + "m " + String(Math.floor(milliseconds / 1000) % 60).padStart(2, "0") + "s";
    }

    // Over the terminal it sits beside, from the same corner.
    width: root.view ? root.view.width : 0
    height: root.view ? root.view.height : 0

    // Shared by every running separator, so one built again keeps its phase: the ring's turn,
    // the light along the rule, the ring's breath and the clock.
    property real spin: 0
    property real sweep: 0
    property real breath: 0.2
    property double now: 0
    // How long a command runs before its clock and interrupt key show: a quick one ends
    // before they would, instead of flashing them for a frame or two.
    readonly property int revealDelay: 400
    NumberAnimation on spin {
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        running: root.anyRunning && root.moving
    }
    NumberAnimation on sweep {
        from: 0
        to: 1
        duration: 1500
        loops: Animation.Infinite
        running: root.anyRunning && root.moving
    }
    SequentialAnimation on breath {
        running: root.anyRunning && root.moving
        loops: Animation.Infinite
        NumberAnimation { from: 0.12; to: 0.3; duration: 900; easing.type: Easing.InOutSine }
        NumberAnimation { from: 0.3; to: 0.12; duration: 900; easing.type: Easing.InOutSine }
    }
    Timer {
        interval: root.anyRunning ? 100 : 1000
        repeat: true
        triggeredOnStart: true
        running: root.anyRunning || root.anySession
        onTriggered: root.now = Date.now()
    }

    // A small framed action on a separator, such as copying its command.
    component Action: Rectangle {
        id: action
        property alias text: actionLabel.text
        property real line: 0
        property color tone: root.colors.subtext0
        signal activated
        width: actionLabel.implicitWidth + root.view.cell.width
        height: action.line * 0.8
        radius: ChromeStyle.smallRadius * root.ratio
        color: actionArea.containsMouse ? Qt.alpha(action.tone, 0.15) : "transparent"
        border.width: Math.max(1, root.ratio)
        border.color: Qt.alpha(action.tone, 0.45)

        CellText {
            id: actionLabel
            anchors.centerIn: parent
            text: ""
            grid: root.grid
            color: action.tone
        }

        MouseArea {
            id: actionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: action.activated()
        }
    }

    // A key the user can press, framed.
    component Key: Rectangle {
        id: key
        property alias text: keyLabel.text
        property real line: 0
        width: keyLabel.implicitWidth + root.view.cell.width
        height: key.line * 0.8
        radius: ChromeStyle.smallRadius * root.ratio
        color: "transparent"
        border.width: Math.max(1, root.ratio)
        border.color: Qt.alpha(root.colors.overlay1, 0.5)

        CellText {
            id: keyLabel
            text: ""
            anchors.centerIn: parent
            grid: root.grid
            color: root.colors.subtext0
        }
    }

    // A remote session's rows: an edge in the remote colour, fading into the rows.
    Repeater {
        model: root.view.remoteRows

        delegate: Item {
            required property var modelData
            y: modelData.row * root.view.cell.height
            width: root.view.cell.width * 8
            height: modelData.rows * root.view.cell.height

            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: Qt.alpha(root.colors.mauve, 0.08) }
                    GradientStop { position: 1; color: Qt.alpha(root.colors.mauve, 0) }
                }
            }

            Rectangle {
                width: 3 * root.ratio
                height: parent.height
                color: root.colors.mauve
            }
        }
    }

    // Keyed by command: one that moves or ends updates its separator in place.
    Repeater {
        model: root.view.separatorRows

        delegate: Separator {
            required property var record
            modelData: record
        }
    }

    // The separator of the command whose output the top row shows, pinned to the view's top
    // until the next one pushes it up.
    Separator {
        id: pinnedSeparator
        pinned: true
        modelData: root.pinning ? root.view.stickyBlock : root.unpinned
        visible: root.pinning
        y: root.pinnedOffset + pinnedSeparator.modelData.push
        z: 2
    }

    component Separator: Item {
            id: separator

            required property var modelData
            property bool pinned: false
            readonly property real line: root.view.cell.height
            readonly property real cell: root.view.cell.width
            readonly property string outcome: separator.modelData.state
            readonly property bool running: separator.outcome === "running"
            readonly property bool session: separator.outcome === "session"
            readonly property bool going: separator.running || separator.session
            readonly property bool failed: separator.outcome === "failed"
            readonly property bool current: separator.modelData.index === root.last
            readonly property color tone: separator.failed ? root.colors.red : separator.outcome === "succeeded" ? root.colors.green : separator.session ? root.colors.mauve : separator.running && separator.revealed ? (separator.current && root.secret ? root.colors.peach : root.colors.accent) : root.colors.overlay1
            // The host of the session the pane is in: where it went, or where it ran.
            readonly property string host: separator.modelData.host ?? ""
            readonly property string blockKey: String(separator.modelData.key ?? separator.modelData.index)
            readonly property bool copiedHere: root.copiedIndex === separator.modelData.index
            // When it was first seen running, for its time.
            property double since: 0
            // It has run long enough to show it runs: its ring, light, clock and interrupt key.
            // The pinned copy stands for a command already in view.
            readonly property bool revealed: separator.going && (separator.pinned || separator.since > 0 && root.now - separator.since >= root.revealDelay)

            // Under a fold opening or closing, on its way to its place.
            y: separator.pinned ? 0 : separator.modelData.row * separator.line + (root.view.foldFrom >= 0 && separator.modelData.row >= root.view.foldFrom ? root.view.foldOffset : 0)
            width: root.width
            height: separator.line

            // A separator stays as its command's rows move, so what it does on first showing a
            // command it does again when it shows another, or the same one ending.
            Component.onCompleted: separator.settle()
            onBlockKeyChanged: separator.settle()
            onOutcomeChanged: separator.settle()

            function settle() {
                if (separator.pinned) {
                    return;
                }
                // Read from the record itself: a change handler runs before the bindings derived
                // from it are brought up to date.
                const index = String(separator.modelData.key ?? separator.modelData.index);
                const outcome = separator.modelData.state;
                const going = outcome === "running" || outcome === "session";
                // What this command looked like the last time it was drawn.
                const before = root.drawn[index] ?? "";
                if (going && !(index in root.started)) {
                    root.started[index] = Date.now();
                }
                separator.since = root.started[index] ?? 0;
                // An ended command forgets when it started.
                const ran = going ? 0 : Date.now() - (root.started[index] ?? 0);
                if (!going) {
                    delete root.started[index];
                }
                if (!root.moving) {
                    root.drawn[index] = outcome;
                    return;
                }
                // One that ended before its clock showed settles without a flash, as the line
                // under it never left; a failure still shakes.
                if ((before === "running" || before === "session") && !going) {
                    if (ran >= root.revealDelay) {
                        popIn.start();
                        flash.start();
                    }
                    if (outcome === "failed") {
                        shake.start();
                    }
                }
                root.drawn[index] = outcome;
            }

            // Pinned over output rows, it covers them, with a shadow under it.
            Rectangle {
                anchors.fill: parent
                visible: separator.pinned
                color: Qt.rgba(root.colors.terminalBackground.r, root.colors.terminalBackground.g, root.colors.terminalBackground.b, 1)

                Rectangle {
                    anchors.top: parent.bottom
                    width: parent.width
                    height: Math.max(1, root.ratio)
                    color: Qt.alpha(root.colors.overlay1, 0.25)
                }
            }

            // The block selected from the editor: its row lit, an accent bar at its edge.
            Rectangle {
                anchors.fill: parent
                visible: separator.modelData.selected
                color: Qt.alpha(root.colors.accent, 0.12)

                Rectangle {
                    width: Math.max(2, 2 * root.ratio)
                    height: parent.height
                    color: root.colors.accent
                }
            }

            // The selected command's output, marked down its edge: the rows Y copies.
            Rectangle {
                readonly property int below: Math.max(0, (root.view ? root.view.rows : 0) - separator.modelData.row - (separator.modelData.commandRows ?? 1))
                visible: separator.modelData.selected && !separator.pinned && !separator.modelData.folded && (separator.modelData.rows ?? 0) > 0
                y: (separator.modelData.commandRows ?? 1) * separator.line
                width: Math.max(2, 2 * root.ratio)
                height: Math.min(separator.modelData.rows ?? 0, below) * separator.line
                color: Qt.alpha(root.colors.accent, 0.45)
            }

            // The pointer over the row shows the command's actions, without taking the pointer
            // from the terminal under it.
            HoverHandler {
                id: hover
            }

            // A click on its status or command selects the block, as stepping to it from the
            // editor does; elsewhere on the row a drag selects the terminal's text.
            MouseArea {
                x: pill.x
                width: Math.max(0, command.x + command.width - pill.x)
                height: parent.height
                cursorShape: Qt.PointingHandCursor
                onClicked: root.view.selectBlock(separator.modelData.index)
            }

            // Everything but the selection shakes when the command fails.
            Item {
                id: content
                width: parent.width
                height: parent.height

                // Folds or unfolds the command's output.
                Item {
                    id: chevron
                    readonly property bool shown: separator.modelData.foldable === true || separator.modelData.folded === true
                    x: 0
                    width: separator.cell * 2
                    height: parent.height

                    CellText {
                        anchors.centerIn: parent
                        visible: chevron.shown
                        text: "›"
                        rotation: separator.modelData.folded ? 0 : 90
                        grid: root.grid
                        color: foldArea.containsMouse ? root.colors.text : root.colors.subtext0
                        bold: true

                        Behavior on rotation {
                            enabled: root.moving
                            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                        }
                    }

                    MouseArea {
                        id: foldArea
                        anchors.fill: parent
                        enabled: chevron.shown
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.view.toggleFold(separator.modelData.index)
                    }
                }

                // How it ended: a turning ring while it runs, then a check or the exit status.
                Rectangle {
                    id: pill
                    x: chevron.width
                    anchors.verticalCenter: parent.verticalCenter
                    height: Math.round(separator.line * 0.72)
                    // As wide as the editor's pill at least, so the command stays where it was typed.
                    width: Math.max(height, separator.cell * 2, mark.width + separator.cell)
                    radius: height / 2
                    color: Qt.alpha(separator.tone, separator.running && separator.revealed ? root.breath : 0.2)

                    NativeProgressRing {
                        anchors.centerIn: parent
                        visible: separator.running && separator.revealed
                        width: parent.height * 0.6
                        height: width
                        color: separator.tone
                        fraction: 0.3
                        rotation: root.spin
                    }

                    // Drawn, not taken from a font: a check, a cross and the exit status, or a mark
                    // for a session or a command that was interrupted.
                    Row {
                        id: mark
                        anchors.centerIn: parent
                        visible: !separator.running
                        spacing: separator.cell * 0.3
                        readonly property real stroke: Math.max(1.5, 1.6 * root.ratio)
                        readonly property real size: pill.height * 0.56

                        Item {
                            id: check
                            visible: separator.outcome === "succeeded"
                            width: mark.size
                            height: mark.size
                            anchors.verticalCenter: parent.verticalCenter

                            // Its two strokes, from the elbow at (0.4, 0.78) of its box.
                            Rectangle {
                                x: check.width * 0.14
                                y: check.height * 0.52 - mark.stroke / 2
                                width: check.width * 0.37
                                height: mark.stroke
                                radius: height / 2
                                rotation: 45
                                transformOrigin: Item.Left
                                color: separator.tone
                            }

                            Rectangle {
                                x: check.width * 0.4
                                y: check.height * 0.78 - mark.stroke / 2
                                width: check.width * 0.72
                                height: mark.stroke
                                radius: height / 2
                                rotation: -50
                                transformOrigin: Item.Left
                                color: separator.tone
                            }
                        }

                        Item {
                            id: cross
                            visible: separator.failed
                            width: mark.size * 0.85
                            height: mark.size * 0.85
                            anchors.verticalCenter: parent.verticalCenter

                            Repeater {
                                model: [45, -45]
                                delegate: Rectangle {
                                    required property int modelData
                                    anchors.centerIn: parent
                                    width: cross.width * 1.3
                                    height: mark.stroke
                                    radius: height / 2
                                    rotation: modelData
                                    color: separator.tone
                                }
                            }
                        }

                        CellText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !check.visible
                            text: separator.failed ? String(separator.modelData.status) : separator.session ? "→" : cross.visible ? "" : "–"
                            grid: root.grid
                            color: separator.tone
                            bold: true
                        }
                    }

                    NumberAnimation {
                        id: popIn
                        target: pill
                        property: "scale"
                        from: 0.4
                        to: 1
                        duration: 320
                        easing.type: Easing.OutBack
                        easing.overshoot: 2.4
                    }
                }

                // The command's first line, cut with an ellipsis where the rule and what follows it
                // need the room.
                Item {
                    id: command
                    readonly property real room: Math.max(0, trail.x - x - (place.visible ? place.implicitWidth + separator.cell : 0) - (more.visible ? more.implicitWidth + separator.cell : 0) - separator.cell * 6)
                    readonly property bool cut: commandText.implicitWidth > command.room
                    x: pill.x + pill.width + separator.cell
                    height: parent.height
                    width: command.cut ? command.room : commandText.implicitWidth

                    Item {
                        width: command.cut ? Math.max(0, command.room - separator.cell) : commandText.implicitWidth
                        height: parent.height
                        clip: true

                        CellText {
                            id: commandText
                            anchors.verticalCenter: parent.verticalCenter
                            text: separator.modelData.command
                            grid: root.grid
                            color: separator.session ? root.colors.mauve : root.colors.text
                            bold: true
                        }
                    }

                    CellText {
                        x: Math.max(0, command.room - separator.cell)
                        anchors.verticalCenter: parent.verticalCenter
                        visible: command.cut
                        text: "…"
                        grid: root.grid
                        color: root.colors.subtext0
                    }
                }

                // The host the session reached, or the one the command ran on.
                CellText {
                    id: place
                    x: command.x + command.width + separator.cell
                    anchors.verticalCenter: parent.verticalCenter
                    visible: separator.host.length > 0 && (separator.session || separator.modelData.remote === true)
                    text: separator.session ? "→ " + separator.host : "@" + separator.host
                    grid: root.grid
                    color: separator.session ? root.colors.subtext0 : Qt.alpha(root.colors.mauve, 0.8)
                }

                // Its command's lines past the first, or, folded, the rows of output it hides.
                CellText {
                    id: more
                    readonly property int hidden: separator.modelData.folded ? (separator.modelData.rows ?? 0) : 0
                    x: (place.visible ? place.x + place.implicitWidth : command.x + command.width) + separator.cell
                    anchors.verticalCenter: parent.verticalCenter
                    visible: more.hidden > 0 || separator.modelData.lines > 0
                    text: more.hidden > 0 ? "… " + more.hidden + (more.hidden === 1 ? " row folded" : " rows folded") : "+" + separator.modelData.lines + (separator.modelData.lines === 1 ? " line" : " lines")
                    grid: root.grid
                    color: more.hidden > 0 ? root.colors.peach : root.colors.subtext0
                }

                // The rule, and while the command runs a light that travels along it.
                Item {
                    id: rule
                    x: (more.visible ? more.x + more.implicitWidth : place.visible ? place.x + place.implicitWidth : command.x + command.width) + separator.cell
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, trail.x - x - separator.cell)
                    height: Math.max(3, 3 * root.ratio)
                    clip: true

                    Rectangle {
                        id: ruleLine
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: Math.max(1, root.ratio)
                        color: separator.going && separator.revealed ? Qt.alpha(separator.tone, 0.4) : separator.failed ? Qt.alpha(root.colors.red, 0.55) : Qt.alpha(root.colors.overlay1, 0.35)
                    }

                    Rectangle {
                        visible: separator.running && separator.revealed && root.moving
                        width: Math.max(separator.cell * 6, rule.width * 0.28)
                        height: parent.height
                        radius: height / 2
                        x: -width + (rule.width + width) * root.sweep
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: Qt.alpha(separator.tone, 0) }
                            GradientStop { position: 0.5; color: separator.tone }
                            GradientStop { position: 1; color: Qt.alpha(separator.tone, 0) }
                        }
                    }

                    // Where it ended flashes in its colour, then rests.
                    Rectangle {
                        id: ending
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: parent.height
                        radius: height / 2
                        color: separator.failed ? root.colors.red : root.colors.green
                        opacity: 0
                    }
                }

                NumberAnimation {
                    id: flash
                    target: ending
                    property: "opacity"
                    from: 0.9
                    to: 0
                    duration: 700
                    easing.type: Easing.OutQuad
                }

                // How long it ran, or how long it runs, the time it was first seen running
                // counted; its interrupt key while nothing waits; its error, when it failed last.
                Row {
                    id: trail
                    x: root.width - implicitWidth - separator.cell * 2
                    height: parent.height
                    spacing: separator.cell

                    // What a copy of it did, for a moment.
                    CellText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: separator.copiedHere
                        text: root.copiedText
                        grid: root.grid
                        color: root.copiedOk ? root.colors.green : root.colors.peach
                    }

                    // Its actions, under the pointer or while it is selected.
                    Action {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: (hover.hovered || separator.modelData.selected) && !separator.copiedHere
                        line: separator.line
                        text: "copy command"
                        onActivated: root.view.copyBlock(separator.modelData.index, true)
                    }

                    Action {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: (hover.hovered || separator.modelData.selected) && !separator.copiedHere && !separator.going && (separator.modelData.rows ?? 0) > 0
                        line: separator.line
                        text: "copy output"
                        onActivated: root.view.copyBlock(separator.modelData.index, false)
                    }

                    // How long it ran, once that is long enough to matter.
                    CellText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !separator.going && separator.modelData.duration >= root.revealDelay
                        text: separator.going ? "" : root.duration(separator.modelData.duration)
                        grid: root.grid
                        color: root.colors.subtext0
                    }

                    // Room for the longest reading, so the rule does not move as the time
                    // passes; a digit that changes rolls in.
                    Row {
                        id: clock
                        readonly property string reading: separator.since > 0 ? root.duration(Math.max(0, root.now - separator.since), separator.session) : ""
                        visible: separator.revealed && clock.reading.length > 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: separator.cell * 7
                        height: separator.line

                        Repeater {
                            model: 7
                            delegate: Item {
                                id: digit
                                required property int index
                                readonly property string character: clock.reading.length > digit.index ? clock.reading[digit.index] : ""
                                property string shown: ""
                                width: separator.cell
                                height: separator.line
                                clip: true

                                onCharacterChanged: {
                                    const roll = root.moving && digit.shown.length > 0 && digit.character >= "0" && digit.character <= "9";
                                    digit.shown = digit.character;
                                    if (roll) {
                                        rolling.restart();
                                    }
                                }
                                Component.onCompleted: digit.shown = digit.character

                                CellText {
                                    id: glyph
                                    text: digit.shown
                                    grid: root.grid
                                    color: separator.tone
                                }

                                ParallelAnimation {
                                    id: rolling
                                    NumberAnimation { target: glyph; property: "y"; from: separator.line * 0.6; to: 0; duration: 180; easing.type: Easing.OutCubic }
                                    NumberAnimation { target: glyph; property: "opacity"; from: 0; to: 1; duration: 180 }
                                }
                            }
                        }
                    }

                    Key {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: separator.running && separator.revealed && separator.current && !root.queueing && root.interruptKey.length > 0
                        line: separator.line
                        text: root.interruptKey
                    }

                    // The last command failed: a way to its error, which selects its block.
                    Rectangle {
                        id: failure
                        visible: separator.failed && separator.current && root.offerFailure
                        anchors.verticalCenter: parent.verticalCenter
                        width: failureLabel.implicitWidth + separator.cell * 2
                        height: separator.line * 0.8
                        radius: ChromeStyle.smallRadius * root.ratio
                        color: failureArea.containsMouse ? Qt.alpha(root.colors.red, 0.15) : "transparent"
                        border.width: Math.max(1, root.ratio)
                        border.color: Qt.alpha(root.colors.red, 0.5)

                        CellText {
                            id: failureLabel
                            anchors.centerIn: parent
                            text: "view error"
                            grid: root.grid
                            color: root.colors.red
                        }

                        MouseArea {
                            id: failureArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.view.selectBlock(separator.modelData.index)
                        }
                    }
                }
            }

            // A failure shakes the separator, as it shook the editor before.
            SequentialAnimation {
                id: shake
                NumberAnimation { target: content; property: "x"; to: -7 * root.ratio; duration: 60; easing.type: Easing.OutQuad }
                NumberAnimation { target: content; property: "x"; to: 6 * root.ratio; duration: 90; easing.type: Easing.InOutQuad }
                NumberAnimation { target: content; property: "x"; to: -4 * root.ratio; duration: 80; easing.type: Easing.InOutQuad }
                NumberAnimation { target: content; property: "x"; to: 2 * root.ratio; duration: 70; easing.type: Easing.InOutQuad }
                NumberAnimation { target: content; property: "x"; to: 0; duration: 60; easing.type: Easing.OutQuad }
            }
    }
}
