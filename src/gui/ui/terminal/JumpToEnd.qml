pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The way back to the live end while the view is scrolled away from it: the rows below, the
// rows of output that arrived meanwhile and how the commands that finished ended. A click
// glides back and follows the output again.
Item {
    id: root

    required property var view
    required property var colors
    required property var grid
    property real ratio: 1
    property bool moving: true
    readonly property int below: root.view ? root.view.rowsBelow : 0
    readonly property int arrived: root.view ? root.view.rowsArrived : 0
    readonly property var finished: root.view ? root.view.finishedBelow : []
    readonly property bool shown: root.below > 2
    readonly property real line: root.view ? root.view.cell.height : 16
    readonly property real cell: root.view ? root.view.cell.width : 8

    width: pill.width
    height: pill.height
    opacity: root.shown ? 1 : 0
    visible: opacity > 0
    enabled: root.shown

    Behavior on opacity {
        enabled: root.moving
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    Rectangle {
        id: pill
        y: root.shown ? 0 : 8 * root.ratio
        width: content.implicitWidth + root.cell * 2.5
        height: Math.round(root.line * 1.3)
        radius: height / 2
        color: Qt.rgba(root.colors.terminalBackground.r, root.colors.terminalBackground.g, root.colors.terminalBackground.b, 1)
        border.width: Math.max(1, root.ratio)
        border.color: area.containsMouse ? root.colors.accent : Qt.alpha(root.colors.overlay1, 0.45)

        Behavior on y {
            enabled: root.moving
            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }

        Row {
            id: content
            anchors.centerIn: parent
            spacing: root.cell

            CellText {
                anchors.verticalCenter: parent.verticalCenter
                text: "↓ " + root.below + (root.below === 1 ? " row" : " rows")
                grid: root.grid
                color: root.colors.text
            }

            CellText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.arrived > 0
                text: "· " + root.arrived + " new"
                grid: root.grid
                color: root.colors.accent
            }

            // A dot per command that finished while the view was away, in how it ended.
            Row {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.finished.length > 0
                spacing: 3 * root.ratio

                Repeater {
                    model: root.finished.slice(-8)

                    delegate: Rectangle {
                        required property var modelData
                        width: 7 * root.ratio
                        height: width
                        radius: width / 2
                        color: modelData === "failed" ? root.colors.red : modelData === "succeeded" ? root.colors.green : root.colors.overlay1
                    }
                }
            }
        }

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.view.scrollToEnd()
        }
    }
}
