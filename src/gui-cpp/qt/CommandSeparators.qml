pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The commands the shell ran, each drawn over the rows its prompt and command line took: how
// it ended, its first line, a rule and how long it ran. The one running turns its ring, sends a
// light along its rule and counts its time. It only draws; the terminal under it keeps the
// pointer and the keyboard.
Item {
    id: root

    required property var view
    required property var colors
    required property var grid
    property real ratio: 1
    property bool moving: true
    // The command the prompt line just launched, by its index among the pane's commands: its
    // line lights up as it lands.
    property int landing: -1
    // While the line turns into it, its separator leaves the command to the line.
    property bool holding: false
    // The key that interrupts the running command, shown beside its time while nothing waits
    // to run after it; and whether the program reads a secret, which tints it.
    property string interruptKey: ""
    property bool queueing: false
    property bool secret: false
    // The editor waits for a command: the last command's separator offers its error if it failed.
    property bool offerFailure: false
    // How each command was last drawn, so a separator built again does not replay its entrance,
    // and when each running one was first seen, for its time.
    property var drawn: ({})
    property var started: ({})

    readonly property int last: root.view ? root.view.rail.length - 1 : -1
    readonly property bool anyRunning: {
        const separators = root.view ? root.view.separators : [];
        for (let index = 0; index < separators.length; ++index) {
            if (separators[index].state === "running") {
                return true;
            }
        }
        return false;
    }

    function duration(milliseconds) {
        return milliseconds < 60000 ? (milliseconds / 1000).toFixed(1) + "s" : Math.floor(milliseconds / 60000) + "m " + String(Math.floor(milliseconds / 1000) % 60).padStart(2, "0") + "s";
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
        interval: 100
        repeat: true
        triggeredOnStart: true
        running: root.anyRunning
        onTriggered: root.now = Date.now()
    }

    // A key the user can press, framed.
    component Key: Rectangle {
        id: key
        property alias text: keyLabel.text
        property real line: 0
        width: keyLabel.implicitWidth + root.view.cell.width
        height: key.line * 0.8
        radius: 4 * root.ratio
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

    Repeater {
        model: root.view.separators

        delegate: Item {
            id: separator

            required property var modelData
            readonly property real line: root.view.cell.height
            readonly property real cell: root.view.cell.width
            readonly property string outcome: separator.modelData.state
            readonly property bool running: separator.outcome === "running"
            readonly property bool failed: separator.outcome === "failed"
            readonly property bool current: separator.modelData.index === root.last
            readonly property color tone: separator.failed ? root.colors.red : separator.outcome === "succeeded" ? root.colors.green : separator.running ? (separator.current && root.secret ? root.colors.peach : root.colors.accent) : root.colors.overlay1
            // What this command looked like the last time it was drawn.
            readonly property string before: root.drawn[separator.modelData.index] ?? ""
            // When it was first seen running, for its time.
            property double since: 0

            y: separator.modelData.row * separator.line
            width: root.width
            height: separator.line

            Component.onCompleted: {
                const index = separator.modelData.index;
                if (separator.running && !(index in root.started)) {
                    root.started[index] = Date.now();
                }
                separator.since = root.started[index] ?? 0;
                if (!root.moving) {
                    root.drawn[index] = separator.outcome;
                    return;
                }
                if (separator.before === "running" && !separator.running) {
                    popIn.start();
                    flash.start();
                    if (separator.failed) {
                        shake.start();
                    }
                }
                if (index === root.landing && !root.holding && separator.before === "" && separator.running) {
                    land.start();
                }
                root.drawn[index] = separator.outcome;
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

            // A click selects the block, as stepping to it from the editor does.
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.view.selectBlock(separator.modelData.index)
            }

            // Everything but the selection shakes when the command fails.
            Item {
                id: content
                width: parent.width
                height: parent.height

                // How it ended: a turning ring while it runs, then a check or the exit status.
                Rectangle {
                    id: pill
                    x: separator.cell * 0.5
                    anchors.verticalCenter: parent.verticalCenter
                    height: Math.round(separator.line * 0.72)
                    width: Math.max(height, mark.implicitWidth + separator.cell)
                    radius: height / 2
                    color: Qt.alpha(separator.tone, separator.running ? root.breath : 0.2)

                    NativeProgressRing {
                        anchors.centerIn: parent
                        visible: separator.running
                        width: parent.height * 0.6
                        height: width
                        color: separator.tone
                        fraction: 0.3
                        rotation: root.spin
                    }

                    CellText {
                        id: mark
                        anchors.centerIn: parent
                        visible: !separator.running
                        text: separator.failed ? "✗ " + separator.modelData.status : separator.outcome === "succeeded" ? "✓" : "–"
                        grid: root.grid
                        color: separator.tone
                        bold: true
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

                // The line landed on this separator: its command lights up.
                Connections {
                    target: root
                    function onHoldingChanged() {
                        if (!root.holding && root.moving && separator.modelData.index === root.landing) {
                            land.start();
                        }
                    }
                }

                // The command's first line, cut where the rule and what follows it need the room.
                Item {
                    id: command
                    opacity: root.holding && separator.modelData.index === root.landing ? 0 : 1
                    x: pill.x + pill.width + separator.cell
                    height: parent.height
                    width: Math.min(commandText.implicitWidth, Math.max(0, trail.x - x - (more.visible ? more.implicitWidth + separator.cell : 0) - separator.cell * 6))
                    clip: true

                    Rectangle {
                        id: glow
                        anchors.fill: parent
                        radius: 3 * root.ratio
                        color: Qt.alpha(root.colors.accent, 0.3)
                        opacity: 0
                    }

                    CellText {
                        id: commandText
                        anchors.verticalCenter: parent.verticalCenter
                        text: separator.modelData.command
                        grid: root.grid
                        color: root.colors.text
                        bold: true
                    }

                    NumberAnimation {
                        id: land
                        target: glow
                        property: "opacity"
                        from: 1
                        to: 0
                        duration: 900
                        easing.type: Easing.OutQuad
                    }
                }

                CellText {
                    id: more
                    x: command.x + command.width + separator.cell
                    anchors.verticalCenter: parent.verticalCenter
                    visible: separator.modelData.lines > 0
                    text: "+" + separator.modelData.lines + (separator.modelData.lines === 1 ? " line" : " lines")
                    grid: root.grid
                    color: root.colors.subtext0
                }

                // The rule, and while the command runs a light that travels along it.
                Item {
                    id: rule
                    x: (more.visible ? more.x + more.implicitWidth : command.x + command.width) + separator.cell
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, trail.x - x - separator.cell)
                    height: Math.max(3, 3 * root.ratio)
                    clip: true

                    Rectangle {
                        id: ruleLine
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: Math.max(1, root.ratio)
                        color: separator.running ? Qt.alpha(separator.tone, 0.4) : separator.failed ? Qt.alpha(root.colors.red, 0.55) : Qt.alpha(root.colors.overlay1, 0.35)
                    }

                    Rectangle {
                        visible: separator.running && root.moving
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

                    CellText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !separator.running
                        text: separator.running ? "" : root.duration(separator.modelData.duration)
                        grid: root.grid
                        color: root.colors.subtext0
                    }

                    // Room for the longest reading, so the rule does not move as the time
                    // passes; a digit that changes rolls in.
                    Row {
                        id: clock
                        readonly property string reading: separator.since > 0 ? root.duration(Math.max(0, root.now - separator.since)) : ""
                        visible: separator.running && clock.reading.length > 0
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
                        visible: separator.running && separator.current && !root.queueing && root.interruptKey.length > 0
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
                        radius: 4 * root.ratio
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
}
