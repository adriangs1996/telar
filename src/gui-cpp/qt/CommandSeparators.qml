pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The commands the shell ran, each drawn over the rows its prompt and command line took: how
// it ended, its first line, a rule and how long it ran. It only draws; the terminal under it
// keeps the pointer and the keyboard.
Item {
    id: root

    required property var view
    required property var colors
    required property var grid
    property real ratio: 1
    property bool moving: true
    // The command the island just launched, by its index among the pane's commands: its line
    // lights up as it lands.
    property int landing: -1
    // While it flies there, its separator leaves the command to the flight.
    property bool holding: false
    // How each command was last drawn, so a separator built again does not replay its entrance.
    property var drawn: ({})

    function duration(milliseconds) {
        return milliseconds < 60000 ? (milliseconds / 1000).toFixed(1) + "s" : Math.floor(milliseconds / 60000) + "m " + String(Math.floor(milliseconds / 1000) % 60).padStart(2, "0") + "s";
    }

    // Over the terminal it sits beside, from the same corner.
    width: root.view ? root.view.width : 0
    height: root.view ? root.view.height : 0

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
            readonly property color tone: separator.failed ? root.colors.red : separator.outcome === "succeeded" ? root.colors.green : separator.running ? root.colors.accent : root.colors.overlay1
            // What this command looked like the last time it was drawn.
            readonly property string before: root.drawn[separator.modelData.index] ?? ""

            y: separator.modelData.row * separator.line
            width: root.width
            height: separator.line

            Component.onCompleted: {
                if (!root.moving) {
                    root.drawn[separator.modelData.index] = separator.outcome;
                    return;
                }
                if (separator.before === "running" && !separator.running) {
                    popIn.start();
                }
                if (separator.modelData.index === root.landing && !root.holding && separator.before === "" && separator.running) {
                    land.start();
                }
                root.drawn[separator.modelData.index] = separator.outcome;
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

            // How it ended: a turning ring while it runs, then a check or the exit status.
            Rectangle {
                id: pill
                x: separator.cell * 0.5
                anchors.verticalCenter: parent.verticalCenter
                height: Math.round(separator.line * 0.72)
                width: Math.max(height, mark.implicitWidth + separator.cell)
                radius: height / 2
                color: Qt.alpha(separator.tone, separator.running ? 0.14 : 0.2)

                NativeProgressRing {
                    anchors.centerIn: parent
                    visible: separator.running
                    width: parent.height * 0.6
                    height: width
                    color: root.colors.accent
                    fraction: 0.3
                    NumberAnimation on rotation {
                        from: 0
                        to: 360
                        duration: 900
                        loops: Animation.Infinite
                        running: separator.running && root.moving
                    }
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

            // The flight landed on this separator: its command lights up.
            Connections {
                target: root
                function onHoldingChanged() {
                    if (!root.holding && root.moving && separator.modelData.index === root.landing) {
                        land.start();
                    }
                }
            }

            // The command's first line, cut where the rule and its duration need the room.
            Item {
                id: command
                opacity: root.holding && separator.modelData.index === root.landing ? 0 : 1
                x: pill.x + pill.width + separator.cell
                height: parent.height
                // What the duration, the line count and a short rule leave.
                width: Math.min(commandText.implicitWidth, Math.max(0, elapsed.x - x - (more.visible ? more.implicitWidth + separator.cell : 0) - separator.cell * 6))
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

            Rectangle {
                id: rule
                x: (more.visible ? more.x + more.implicitWidth : command.x + command.width) + separator.cell
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, elapsed.x - x - separator.cell)
                height: Math.max(1, root.ratio)
                color: Qt.alpha(root.colors.overlay1, 0.35)
            }

            CellText {
                id: elapsed
                x: root.width - implicitWidth - separator.cell * 2
                anchors.verticalCenter: parent.verticalCenter
                text: separator.running ? "" : root.duration(separator.modelData.duration)
                grid: root.grid
                color: root.colors.subtext0
            }
        }
    }
}
