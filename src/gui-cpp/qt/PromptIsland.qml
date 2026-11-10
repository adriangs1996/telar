pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Telar.Gui

// The island: telar's command editor floating over the bottom of a pane while its shell waits
// for a command, a pill while a command runs, and a lock while a program reads a secret. It
// only draws; the terminal keeps the keyboard focus and hands keys to the session's editor.
Item {
    id: root

    required property var application
    required property string paneId
    required property var colors
    required property var grid
    property var terminal: null
    property real ratio: 1
    // Only the focused pane edits, reads secrets and shows outcomes; a command running
    // elsewhere still shows its pill. Either way the shell's own prompt stays hidden.
    property bool focused: true

    readonly property string surface: island.surface
    readonly property real cell: island.cellWidth
    readonly property real line: island.cellHeight
    readonly property real gutter: 12 * root.ratio
    readonly property real padding: 10 * root.ratio
    readonly property bool editing: root.surface === "editor"
    readonly property bool running: root.surface === "running"
    readonly property bool secret: root.surface === "secret"
    readonly property bool queueing: root.running && (!island.empty || island.queued)
    readonly property bool ink: island.skin === "ink"
    readonly property bool glass: island.skin === "glass"
    readonly property bool halo: island.skin === "halo"
    readonly property bool moving: island.motion !== "none"
    // Room for the last line of output beside the running command.
    readonly property bool wide: (root.parent ? root.parent.width : 0) >= 600 * root.ratio
    // How the last command ended, shown in place of the empty editor for a moment.
    readonly property bool concluded: root.concluding && root.editing && island.empty && island.choices.length === 0 && island.block === 0 && island.copying.length === 0
    readonly property bool concludedFailed: island.lastBlock.failed ?? island.failed
    // The state's colour, shared by the border, the halo and the light under the island.
    readonly property color tone: root.secret ? root.tones.peach : root.concluded ? (root.concludedFailed ? root.tones.red : root.tones.green) : island.failed && root.editing ? root.tones.red : root.tones.accent
    // Ink inverts the surface: light paper, the theme's background as text.
    readonly property var tones: root.ink ? Object.assign({}, root.colors, {text: root.colors.background, subtext0: Qt.darker(root.colors.overlay1, 1.6), overlay1: Qt.darker(root.colors.overlay1, 1.3), green: Qt.darker(root.colors.green, 1.8), blue: Qt.darker(root.colors.blue, 1.8), yellow: Qt.darker(root.colors.yellow, 2.0), mauve: Qt.darker(root.colors.mauve, 1.8), peach: Qt.darker(root.colors.peach, 1.8), accent: Qt.darker(root.colors.accent, 1.9), red: Qt.darker(root.colors.red, 1.6)}) : root.colors
    // The command the island launched last, by its index among the pane's commands, for its
    // separator to light up as it lands.
    property int landing: -1

    visible: root.surface !== "none" && (root.focused || root.running)
    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
    anchors.bottom: parent ? parent.bottom : undefined
    anchors.bottomMargin: root.gutter
    width: Math.min(parent ? parent.width - root.gutter * 2 : 0, Math.max(root.editing ? root.minimumWidth : 0, root.contentWidth))
    height: root.contentHeight

    // One surface that changes shape: a spring with a little overshoot between states, and a
    // short settle without one while typing grows it.
    property bool calm: false
    Timer {
        id: calming
        interval: 460
        onTriggered: root.calm = root.editing
    }
    Behavior on width {
        enabled: root.moving
        SpringAnimation { spring: root.calm || island.motion === "ease" ? 6 : 4.5; damping: root.calm || island.motion === "ease" ? 1 : 0.32; epsilon: 0.5 }
    }
    Behavior on height {
        enabled: root.moving
        SpringAnimation { spring: root.calm || island.motion === "ease" ? 6 : 4.5; damping: root.calm || island.motion === "ease" ? 1 : 0.32; epsilon: 0.5 }
    }

    readonly property real minimumWidth: Math.min(56 * root.cell, parent ? parent.width - root.gutter * 2 : 0)
    // While typing, the island grows a few columns at a time and never shrinks before the
    // command runs, so it does not wobble with every key.
    readonly property real step: 6 * root.cell
    readonly property real editorWidth: island.columns * root.cell + root.padding * 2 + root.cell + root.trailingWidth
    // The mode and the hints at the end of the editor's last row take this much room.
    readonly property real trailingWidth: trailing.visible && trailing.implicitWidth > 0 ? trailing.implicitWidth + root.cell * 2 : 0
    property real grownWidth: 0
    onEditorWidthChanged: root.grow()
    onEditingChanged: {
        root.grownWidth = 0;
        root.grow();
    }
    function grow() {
        if (root.editing && root.step > 0) {
            root.grownWidth = Math.max(root.grownWidth, Math.ceil(root.editorWidth / root.step) * root.step);
        }
    }
    readonly property real menuHeight: root.editing && island.choices.length > 0 ? island.choices.length * root.line + root.padding + (island.menuLabel.length > 0 ? root.line : 0) : 0
    readonly property real contentWidth: root.editing ? Math.max(root.grownWidth, root.concluded ? outcomeRow.implicitWidth + root.padding * 2 : 0) : root.secret ? secretColumn.implicitWidth + root.padding * 2 : Math.max(pill.implicitWidth + root.padding * 2, root.queueing ? root.editorWidth : 0)
    readonly property real contentHeight: (root.editing ? island.visibleRows * root.line + root.menuHeight : root.secret ? root.line * 2 : root.line + (root.queueing ? island.visibleRows * root.line + root.padding * 0.5 : 0)) + root.padding * 2

    // When a key last changed the editor: announcements and the caret's blink wait for a pause.
    property double lastKey: 0
    Connections {
        target: island
        function onLayoutChanged() {
            root.lastKey = Date.now();
            caret.on = true;
        }
    }

    // A change of directory or branch is announced over the island once typing pauses, then
    // fades; so is a connection to another host.
    property string announced: ""
    readonly property string context: island.branch.length > 0 ? island.directory + "\n" + island.branch : island.directory
    onContextChanged: {
        const previous = root.announced;
        root.announced = root.context;
        if (previous.length === 0 || !root.editing || island.remote) {
            return;
        }
        const parts = root.context.split("\n");
        const before = previous.split("\n");
        root.say(parts.length > 1 && parts[1] !== (before[1] ?? "") ? "⎇ " + parts[1] : parts[0].replace(/^.*\//, "") || "/");
    }
    readonly property bool remote: island.remote
    onRemoteChanged: {
        if (root.remote) {
            root.say("connected to " + (island.host.length > 0 ? island.host : "a remote host") + (island.directory.length > 0 ? " · " + island.directory : ""));
        }
    }
    function say(text) {
        whisper.pending = text;
        whisperDelay.interval = Math.max(1, 800 - (Date.now() - root.lastKey));
        whisperDelay.restart();
    }

    CellText {
        id: whisper
        property string pending: ""
        text: ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.top
        anchors.bottomMargin: root.padding * 0.8
        grid: root.grid
        color: root.tones.subtext0
        opacity: 0
        Behavior on opacity {
            enabled: root.moving
            NumberAnimation { duration: 300 }
        }
    }

    Timer {
        id: whisperDelay
        onTriggered: {
            whisper.text = whisper.pending;
            whisper.opacity = 1;
            whisperTimer.restart();
        }
    }

    Timer {
        id: whisperTimer
        interval: 2600
        onTriggered: whisper.opacity = 0
    }

    // The light the island casts on the output under it, in its state's colour; it breathes
    // while a command runs.
    Shape {
        id: ambient
        // A circle of the glow's width, squashed to its height: the gradient fades to nothing
        // at the edge in both directions.
        readonly property real glowWidth: Math.max(root.width * 1.4, 240 * root.ratio)
        readonly property real glowHeight: 200 * root.ratio
        readonly property real rest: root.concluded ? (root.concludedFailed ? 0.34 : 0.32) : root.secret ? 0.26 : 0.14
        width: glowWidth
        height: glowWidth
        x: (root.width - width) / 2
        y: root.height + glowHeight * 0.15 - glowWidth / 2
        opacity: root.running ? ambient.pulse : ambient.rest
        z: -1
        property real pulse: 0.2
        preferredRendererType: Shape.CurveRenderer
        transform: Scale {
            origin.x: ambient.width / 2
            origin.y: ambient.height / 2
            yScale: ambient.glowHeight / ambient.glowWidth
        }
        Behavior on opacity {
            enabled: root.moving && !root.running
            NumberAnimation { duration: 500 }
        }

        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: ambient.width / 2
                centerY: ambient.height / 2
                centerRadius: ambient.width / 2
                focalX: centerX
                focalY: centerY
                GradientStop { position: 0; color: Qt.alpha(root.tone, 0.9) }
                GradientStop { position: 1; color: Qt.alpha(root.tone, 0) }
            }
            PathRectangle { x: 0; y: 0; width: ambient.width; height: ambient.height }
        }

        SequentialAnimation on pulse {
            running: root.running && root.moving
            loops: Animation.Infinite
            NumberAnimation { from: 0.12; to: 0.3; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.3; to: 0.12; duration: 900; easing.type: Easing.InOutSine }
        }
    }

    ElevationShadow {
        anchors.fill: surfaceShape
        ratio: root.ratio
        cornerRadius: surfaceShape.radius
    }

    Loader {
        anchors.fill: surfaceShape
        active: root.glass && root.terminal !== null
        source: "PromptGlass.qml"
        onLoaded: {
            item.backdrop = Qt.binding(() => root.terminal);
            item.island = root;
            item.radius = Qt.binding(() => surfaceShape.radius);
        }
    }

    NativeRoundedRectangle {
        id: surfaceShape
        anchors.fill: parent
        radius: root.editing ? 12 * root.ratio : Math.min(height / 2, 21 * root.ratio)
        // An outcome and a secret tint the surface with their colour.
        color: root.ink ? root.colors.text : Qt.alpha(Qt.tint(root.colors.elevated, Qt.alpha(root.secret ? root.colors.peach : root.concluded ? (root.concludedFailed ? root.colors.red : root.colors.green) : island.failed && root.editing ? root.colors.red : root.colors.accent, root.secret || root.concluded ? 0.15 : 0.04)), root.glass ? 0.55 : 1)
        borderColor: flash.running ? root.tones.green : root.tone
        borderAlpha: flash.running ? 0.9 : root.running ? 0.55 : 0.28
        borderWidth: 1
    }

    // A shell on another host: a violet edge down the island's side.
    Rectangle {
        visible: island.remote
        x: Math.max(1, root.ratio)
        y: surfaceShape.radius * 0.5
        width: 3 * root.ratio
        height: Math.max(0, root.height - surfaceShape.radius)
        radius: width / 2
        color: root.tones.mauve
        z: 2
    }

    // Halo: a light on the border that runs around it while a command runs, a program reads a
    // secret or an outcome shows, and rests at the bottom otherwise, so an idle prompt never
    // repaints.
    Shape {
        id: haloLight
        anchors.fill: surfaceShape
        visible: root.halo && !root.ink
        opacity: root.running || root.secret || root.concluded ? 1 : 0.55
        preferredRendererType: Shape.CurveRenderer
        property real angle: 270

        ShapePath {
            strokeWidth: -1
            fillRule: ShapePath.OddEvenFill
            fillGradient: ConicalGradient {
                centerX: haloLight.width / 2
                centerY: haloLight.height / 2
                angle: haloLight.angle
                GradientStop { position: 0; color: Qt.alpha(root.tone, 0) }
                GradientStop { position: 0.55; color: Qt.alpha(root.tone, 0) }
                GradientStop { position: 0.8; color: Qt.alpha(root.tone, 1) }
                GradientStop { position: 1; color: Qt.alpha(root.tone, 0) }
            }
            PathRectangle { x: 0; y: 0; width: haloLight.width; height: haloLight.height; radius: surfaceShape.radius }
            PathRectangle { x: 1.5 * root.ratio; y: 1.5 * root.ratio; width: haloLight.width - 3 * root.ratio; height: haloLight.height - 3 * root.ratio; radius: Math.max(0, surfaceShape.radius - 1.5 * root.ratio) }
        }

        NumberAnimation on angle {
            from: 270
            to: 630
            duration: root.concluded ? 3000 : 1500
            loops: Animation.Infinite
            // The model's state, not `visible`: an item's effective visibility loops back here.
            running: root.halo && !root.ink && (root.running || root.secret || root.concluded) && root.moving
            onRunningChanged: if (!running) haloLight.angle = 270
        }
    }

    // How the command ended: a green flash after a success, a shake after a failure, and its
    // outcome in place of the empty editor for a moment.
    // Not a binding: it holds the count the last outcome was shown for.
    property int seenCommands: -1
    property bool concluding: false
    Component.onCompleted: {
        root.seenCommands = island.commands;
        root.seenLaunches = island.launches;
    }
    Connections {
        target: island
        function onStateChanged() {
            if (island.commands === root.seenCommands) {
                return;
            }
            root.seenCommands = island.commands;
            root.concluding = true;
            concludingTimer.interval = island.status === 0 ? 1400 : 2800;
            concludingTimer.restart();
            if (!root.moving) {
                return;
            }
            if (island.status === 0) {
                flash.restart();
            } else {
                shake.restart();
            }
        }
    }

    Timer {
        id: concludingTimer
        onTriggered: root.concluding = false
    }

    Timer {
        id: flash
        interval: 700
    }

    // The outcome on show: "success" while the border flashes, "failure" while it shakes.
    readonly property string outcome: flash.running ? "success" : shake.running ? "failure" : ""

    SequentialAnimation {
        id: shake
        NumberAnimation { target: root; property: "anchors.horizontalCenterOffset"; to: -7 * root.ratio; duration: 60; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "anchors.horizontalCenterOffset"; to: 6 * root.ratio; duration: 90; easing.type: Easing.InOutQuad }
        NumberAnimation { target: root; property: "anchors.horizontalCenterOffset"; to: -4 * root.ratio; duration: 80; easing.type: Easing.InOutQuad }
        NumberAnimation { target: root; property: "anchors.horizontalCenterOffset"; to: 2 * root.ratio; duration: 70; easing.type: Easing.InOutQuad }
        NumberAnimation { target: root; property: "anchors.horizontalCenterOffset"; to: 0; duration: 60; easing.type: Easing.OutQuad }
    }

    // A run sends the command to its separator in the scrollback, where the prompt the
    // island stood in for was.
    property int launchRow: -1
    Connections {
        target: root.terminal
        function onBlocksChanged() {
            if (root.terminal.promptRow >= 0) {
                root.launchRow = root.terminal.promptRow;
            }
        }
    }

    CellText {
        id: flyer
        text: ""
        grid: root.grid
        color: root.tones.accent
        opacity: 0
        x: root.padding + root.cell * 2
        y: root.height - root.padding - root.line
    }

    // The flight is short: the command already runs, and its output waits for it to land.
    readonly property bool flying: flight.running
    ParallelAnimation {
        id: flight
        property point from
        property point to
        NumberAnimation { target: flyer; property: "x"; from: flight.from.x; to: flight.to.x; duration: 180; easing.type: Easing.InOutCubic }
        NumberAnimation { target: flyer; property: "y"; from: flight.from.y; to: flight.to.y; duration: 180; easing.type: Easing.InOutCubic }
        ColorAnimation { target: flyer; property: "color"; from: root.tones.accent; to: root.colors.text; duration: 180 }
        SequentialAnimation {
            PropertyAction { target: flyer; property: "opacity"; value: 1 }
            PauseAnimation { duration: 150 }
            NumberAnimation { target: flyer; property: "opacity"; to: 0; duration: 30 }
        }
        // Landed: the output held meanwhile enters.
        onRunningChanged: {
            if (!flight.running && root.terminal) {
                root.terminal.releaseOutput();
            }
        }
    }

    // Each command the editor sends flies from the island to its separator, from the Enter
    // on, even one that ends before the shell reports it running.
    property int seenLaunches: -1
    Connections {
        target: island
        function onStateChanged() {
            if (island.launches === root.seenLaunches) {
                return;
            }
            root.seenLaunches = island.launches;
            const terminal = root.terminal;
            if (!root.moving || !root.visible || island.lastCommand.length === 0 || !terminal) {
                return;
            }
            flyer.text = island.lastCommand;
            const start = Qt.point(root.padding + root.cell * 2, root.height - root.padding - root.line);
            const cell = terminal.cell;
            // Where the separator's command will be: after its status, on the prompt's row.
            const target = root.launchRow >= 0 && cell.height > 0 ? root.mapFromItem(terminal, cell.width * 3.5, root.launchRow * cell.height) : Qt.point(start.x, -root.line * 4);
            flight.from = start;
            flight.to = Qt.point(target.x, target.y);
            root.landing = Math.min(terminal.rail.length, 63);
            terminal.holdOutput();
            flight.restart();
        }
    }

    // Reads `surface` itself: the bindings that derive from it may not have updated yet.
    onSurfaceChanged: {
        root.calm = false;
        calming.restart();
        const running = root.surface === "running";
        if (running) {
            root.startedAt = Date.now();
            root.elapsed = 0;
            ticker.reset();
        }
    }

    // The pill's clock: tenths for the first minute, then minutes and seconds. It also reads
    // the last line of output, at most ten times a second.
    property double startedAt: 0
    property double elapsed: 0
    Timer {
        interval: 100
        repeat: true
        running: root.running
        onTriggered: {
            root.elapsed = Date.now() - root.startedAt;
            if (root.wide) {
                ticker.show(island.outputLine());
            }
        }
    }
    readonly property string clock: root.elapsed < 60000 ? (root.elapsed / 1000).toFixed(1) + "s" : Math.floor(root.elapsed / 60000) + "m " + String(Math.floor(root.elapsed / 1000) % 60).padStart(2, "0") + "s"

    // How a state's content enters and leaves: it fades into the next state's, growing and
    // rising into place out of a slight blur. The blur takes a layer only while it fades.
    component Layer: Item {
        id: content
        property bool shown: false
        opacity: content.shown ? 1 : 0
        visible: content.opacity > 0
        scale: content.shown ? 1 : 0.94
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
        Behavior on scale {
            enabled: root.moving
            NumberAnimation { duration: 340; easing.type: Easing.OutCubic }
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
        radius: 5 * root.ratio
        color: "transparent"
        border.width: Math.max(1, root.ratio)
        border.color: Qt.alpha(root.tones.overlay1, 0.5)

        CellText {
            id: label
            text: ""
            anchors.centerIn: parent
            grid: root.grid
            color: root.tones.subtext0
        }
    }

    // At the end of the editor's last row: the keys that act on what shows, and vim's mode, as
    // Neovim names it.
    Row {
        id: trailing
        readonly property bool menuOpen: island.choices.length > 0
        readonly property bool vim: island.mode !== "emacs"
        // A block selected in the scrollback, or copy mode on it, takes over the hints.
        readonly property bool copying: island.copying.length > 0
        readonly property bool selecting: island.block > 0 && !trailing.copying
        readonly property bool editing: !trailing.copying && !trailing.selecting
        visible: island.shown && (trailing.vim || trailing.copying || trailing.selecting || island.suggesting || trailing.menuOpen)
        x: root.width - root.padding - implicitWidth
        y: root.height - root.padding - root.line
        height: root.line
        spacing: root.cell

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
                color: root.tones.overlay1
            }
        }

        Hint {
            visible: trailing.editing && island.suggesting && !trailing.menuOpen
            key: "\u2192"
            action: "accept"
        }

        Hint {
            visible: trailing.editing && island.suggesting && !trailing.menuOpen
            key: "\u2325\u2192"
            action: "word"
        }

        Hint {
            visible: trailing.editing && trailing.menuOpen
            key: "\u21E5"
            action: "next"
        }

        Hint {
            visible: trailing.editing && trailing.menuOpen
            key: "\u23CE"
            action: "take"
        }

        Hint {
            visible: trailing.editing && trailing.menuOpen
            key: "esc"
            action: "close"
        }

        Hint {
            visible: trailing.selecting
            key: "\u2303U \u2303D"
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

        // Each mode in its own colour, the label in the island's background, as a status line.
        Rectangle {
            id: modeChip
            readonly property color tint: trailing.copying ? root.tones.mauve : trailing.selecting ? root.tones.accent : island.mode === "insert" ? root.tones.green : island.mode === "normal" ? root.tones.accent : root.tones.mauve
            visible: trailing.vim || trailing.copying || trailing.selecting
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
                text: trailing.copying ? (island.copying === "copy" ? "COPY" : island.copying === "visual" ? "VISUAL" : "V-LINE") : trailing.selecting ? "BLOCK " + island.block + "/" + island.blocks : island.mode === "insert" ? "INSERT" : island.mode === "normal" ? "NORMAL" : island.mode === "visual" ? "VISUAL" : "V-LINE"
                grid: root.grid
                color: root.ink ? root.colors.text : root.colors.background
                bold: true
            }
        }
    }

    // Tab's choices grow the island upward, above the command they would complete, under a
    // heading that says where they come from.
    Layer {
        id: menu
        shown: root.menuHeight > 0 && y >= root.padding * 0.5
        x: root.padding
        y: island.y - root.menuHeight
        width: root.width - root.padding * 2
        height: root.menuHeight

        CellText {
            id: menuHeading
            visible: island.menuLabel.length > 0
            x: root.cell
            text: island.menuLabel
            grid: root.grid
            color: root.tones.overlay1
        }

        // The selection slides from one choice to the next.
        Rectangle {
            id: selection
            readonly property real offset: menuHeading.visible ? root.line : 0
            visible: island.choice >= 0
            width: parent.width
            height: root.line
            y: offset + Math.max(0, island.choice) * root.line
            radius: 4 * root.ratio
            color: Qt.alpha(root.tones.accent, 0.16)
            Behavior on y {
                enabled: root.moving
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
            }

            Rectangle {
                width: 2 * root.ratio
                height: parent.height
                color: root.tones.accent
            }
        }

        Column {
            y: selection.offset
            width: parent.width

            Repeater {
                model: island.choices
                delegate: Item {
                    id: entry
                    required property var modelData
                    width: menu.width
                    height: root.line

                    // The letters what was typed matches, marked.
                    Row {
                        id: choiceText
                        x: root.cell
                        anchors.verticalCenter: parent.verticalCenter

                        Repeater {
                            model: entry.modelData.segments
                            delegate: CellText {
                                required property var modelData
                                text: modelData.text
                                grid: root.grid
                                bold: modelData.marked
                                color: modelData.marked ? root.tones.accent : entry.modelData.selected ? root.tones.text : root.tones.subtext0
                            }
                        }
                    }

                    // The description takes the room the choice leaves, cut at the island's edge.
                    Item {
                        x: Math.max(choiceText.x + choiceText.implicitWidth + root.cell * 3, menu.width * 0.4)
                        width: Math.max(0, menu.width - x - root.cell)
                        height: parent.height
                        clip: true

                        CellText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: entry.modelData.description
                            grid: root.grid
                            color: root.tones.overlay1
                        }
                    }
                }
            }
        }
    }

    // The running command: its progress, the last line it printed and how long it has run.
    Layer {
        id: runLayer
        shown: root.running
        x: root.padding
        y: root.queueing ? island.y - root.line - root.padding * 0.5 : (root.height - root.line) / 2
        width: pill.implicitWidth
        height: root.line

        Row {
            id: pill
            height: root.line
            spacing: root.cell

            // The program's own progress when it reports one, else a turning arc.
            Item {
                width: root.line
                height: root.line

                NativeProgressRing {
                    id: ring
                    anchors.centerIn: parent
                    width: parent.width * 0.62
                    height: width
                    color: root.tones.accent
                    fraction: island.progress >= 0 ? island.progress / 100 : 0.3
                    NumberAnimation on rotation {
                        from: 0
                        to: 360
                        duration: 900
                        loops: Animation.Infinite
                        running: root.running && island.progress < 0
                    }
                }
            }

            Item {
                width: Math.min(command.implicitWidth, 24 * root.cell)
                height: root.line
                clip: true

                CellText {
                    id: command
                    anchors.verticalCenter: parent.verticalCenter
                    text: island.answering ? "typing goes to the program" : island.lastCommand
                    grid: root.grid
                    color: root.tones.text
                }
            }

            // The last line of output scrolls by, the new one rising under the old.
            Item {
                id: ticker
                visible: root.wide && (current.text.length > 0 || previous.text.length > 0)
                width: 28 * root.cell
                height: root.line
                clip: true

                function reset() {
                    current.text = "";
                    previous.text = "";
                }

                function show(text) {
                    if (text === current.text) {
                        return;
                    }
                    previous.text = current.text;
                    current.text = text;
                    if (root.moving) {
                        tick.restart();
                    }
                }

                Rectangle {
                    width: Math.max(1, root.ratio)
                    height: parent.height
                    color: Qt.alpha(root.tones.overlay1, 0.35)
                }

                CellText {
                    id: previous
                    text: ""
                    x: root.cell
                    opacity: 0
                    grid: root.grid
                    color: root.tones.subtext0
                }

                CellText {
                    id: current
                    text: ""
                    x: root.cell
                    grid: root.grid
                    color: root.tones.subtext0
                }

                ParallelAnimation {
                    id: tick
                    NumberAnimation { target: current; property: "y"; from: root.line; to: 0; duration: 260; easing.type: Easing.OutCubic }
                    NumberAnimation { target: current; property: "opacity"; from: 0; to: 1; duration: 260 }
                    NumberAnimation { target: previous; property: "y"; from: 0; to: -root.line; duration: 260; easing.type: Easing.InQuad }
                    NumberAnimation { target: previous; property: "opacity"; from: 1; to: 0; duration: 260 }
                }
            }

            // Room for the longest reading, so the island does not resize as the time passes; a
            // digit that changes rolls in.
            Row {
                width: root.cell * 7
                height: root.line

                Repeater {
                    model: 7
                    delegate: Item {
                        id: digit
                        required property int index
                        readonly property string character: root.clock.length > digit.index ? root.clock[digit.index] : ""
                        property string shown: ""
                        width: root.cell
                        height: root.line
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
                            color: root.tones.accent
                        }

                        ParallelAnimation {
                            id: rolling
                            NumberAnimation { target: glyph; property: "y"; from: root.line * 0.6; to: 0; duration: 180; easing.type: Easing.OutCubic }
                            NumberAnimation { target: glyph; property: "opacity"; from: 0; to: 1; duration: 180 }
                        }
                    }
                }
            }

            Key {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.queueing && island.interruptKey.length > 0
                text: island.interruptKey
            }

            Key {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.queueing
                text: island.queued ? "queued" : "⌥⏎ to program"
            }
        }
    }

    // A program reading a secret: what asks, a dot per key and a reminder that telar neither
    // draws nor keeps it.
    Layer {
        id: secretLayer
        shown: root.secret
        x: root.padding
        y: root.padding
        width: secretColumn.implicitWidth
        height: secretColumn.implicitHeight

        Column {
            id: secretColumn

            Row {
                height: root.line
                spacing: root.cell

                CellText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\u{1F512}"
                    grid: root.grid
                    color: root.tones.peach
                }

                CellText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: island.program.length > 0 ? island.program + " reads hidden input" : "hidden input"
                    grid: root.grid
                    color: root.tones.text
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(2 * root.cell, dots.implicitWidth + root.cell)
                    height: root.line * 0.8
                    radius: 6 * root.ratio
                    color: Qt.alpha(root.tones.overlay1, 0.18)

                    Row {
                        id: dots
                        anchors.centerIn: parent
                        spacing: 5 * root.ratio

                        Repeater {
                            model: island.secretKeys
                            delegate: Rectangle {
                                id: secretDot
                                width: 7 * root.ratio
                                height: width
                                radius: width / 2
                                color: root.tones.peach
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
                x: root.cell * 3
                height: root.line
                text: "echo is off: telar neither draws nor keeps it"
                grid: root.grid
                color: root.tones.overlay1
            }
        }
    }

    // How the last command ended, until a key or a moment later: a mark, its status, the
    // command and how long it ran; a failure offers its error.
    Layer {
        id: outcomeLayer
        shown: root.concluded
        x: root.padding
        y: root.height - root.padding - root.line
        width: outcomeRow.implicitWidth
        height: root.line

        Row {
            id: outcomeRow
            height: root.line
            spacing: root.cell

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: root.line * 0.9
                height: width
                radius: width / 2
                color: root.tone

                CellText {
                    anchors.centerIn: parent
                    text: root.concludedFailed ? "✗" : "✓"
                    grid: root.grid
                    color: root.ink ? root.colors.text : root.colors.background
                    bold: true
                }
            }

            CellText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.concludedFailed
                text: "exit " + (island.lastBlock.status ?? island.status)
                grid: root.grid
                color: root.tone
                bold: true
            }

            Item {
                width: Math.min(outcomeCommand.implicitWidth, 32 * root.cell)
                height: root.line
                clip: true

                CellText {
                    id: outcomeCommand
                    anchors.verticalCenter: parent.verticalCenter
                    text: island.lastBlock.command ?? island.lastCommand
                    grid: root.grid
                    color: root.tones.text
                }
            }

            CellText {
                readonly property double milliseconds: island.lastBlock.duration ?? root.elapsed
                anchors.verticalCenter: parent.verticalCenter
                text: milliseconds < 60000 ? (milliseconds / 1000).toFixed(1) + "s" : Math.floor(milliseconds / 60000) + "m " + String(Math.floor(milliseconds / 1000) % 60).padStart(2, "0") + "s"
                grid: root.grid
                color: root.concludedFailed ? root.tones.subtext0 : root.tone
                bold: !root.concludedFailed
            }

            Rectangle {
                visible: root.concludedFailed
                anchors.verticalCenter: parent.verticalCenter
                width: viewError.implicitWidth + root.cell * 2
                height: root.line * 0.85
                radius: height / 2
                color: viewErrorArea.containsMouse ? Qt.alpha(root.tone, 0.15) : "transparent"
                border.width: Math.max(1, root.ratio)
                border.color: root.tone

                CellText {
                    id: viewError
                    anchors.centerIn: parent
                    text: "view error"
                    grid: root.grid
                    color: root.tone
                }

                MouseArea {
                    id: viewErrorArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: island.viewFailure()
                }
            }
        }
    }

    NativePromptEditor {
        id: island
        application: root.application
        paneId: root.paneId
        grid: root.grid
        colors: root.tones
        preedit: root.terminal ? root.terminal.preeditText : ""
        // A key brings the editor back at once; only an outcome fades it.
        readonly property bool shown: (root.editing && !root.concluded) || root.queueing
        opacity: island.shown ? 1 : 0
        visible: island.opacity > 0
        Behavior on opacity {
            enabled: root.moving && island.empty
            NumberAnimation { duration: 200 }
        }
        x: root.padding
        // Anchored to the bottom, so the island grows upward and its content never spills.
        y: root.height - root.padding - height
        width: island.columns * root.cell + root.cell
        height: island.visibleRows * root.line
        maximumColumns: Math.max(8, Math.floor(((root.parent ? root.parent.width : 0) - root.gutter * 2 - root.padding * 2 - root.trailingWidth) / Math.max(1, root.cell)) - 1)

        // A completion sweeping in glows in the accent colour as it settles.
        Repeater {
            model: island.glows.length
            delegate: RectangularShadow {
                required property int index
                readonly property var glow: island.glows[index] ?? {x: 0, y: 0, width: 0, height: 0, strength: 0}
                x: glow.x
                y: glow.y + glow.height * 0.2
                width: glow.width
                height: glow.height * 0.6
                z: -1
                radius: height / 2
                blur: 10 * root.ratio
                color: root.tones.accent
                opacity: 0.55 * glow.strength
            }
        }

        // The caret slides to where it goes and blinks while the keyboard rests; a block in
        // vim's normal mode.
        Rectangle {
            id: caret
            readonly property bool block: island.mode === "normal" || island.mode.startsWith("visual")
            property bool on: true
            x: island.caret.x
            y: island.caret.y + (block ? 0 : island.caret.height * 0.12)
            width: block ? island.caret.width : Math.max(1, 2 * root.ratio)
            height: block ? island.caret.height : island.caret.height * 0.76
            radius: block ? 2 * root.ratio : width / 2
            color: root.tones.accent
            opacity: block ? 0.5 : caret.on ? 1 : 0.15
            visible: island.shown
            Behavior on x {
                enabled: root.moving
                NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
            }
            Behavior on y {
                enabled: root.moving
                NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
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
            running: root.moving && island.shown && !caret.block && root.visible
            onTriggered: caret.on = Date.now() - root.lastKey < 600 || !caret.on
            onRunningChanged: caret.on = true
        }
    }

    // The input method composes at the island's caret, not at the hidden shell prompt.
    Binding {
        target: root.terminal
        when: root.terminal !== null
        property: "promptCaret"
        value: root.editing && root.visible ? island.mapToItem(root.terminal, island.caret.x, island.caret.y, island.caret.width, island.caret.height) : Qt.rect(0, 0, 0, 0)
    }
}
