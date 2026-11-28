pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The commands an earlier runtime kept, whose rows went with it: a chip at the pane's top that
// counts them and opens their list under a "restored" rule, each with how it ended, where and
// when it ran, and a way to put it in the editor or run it again.
Item {
    id: root

    required property var view
    required property var colors
    required property var typography
    property real ratio: 1
    property bool expanded: false
    readonly property var blocks: root.view ? root.view.restoredBlocks : []
    readonly property real line: 22 * root.ratio
    readonly property real gap: 8 * root.ratio
    readonly property real small: root.typography.small ?? 11
    // The runtime's word for a command its history keeps out.
    readonly property string redacted: "[REDACTED]"

    visible: root.blocks.length > 0
    width: root.expanded ? Math.min(560 * root.ratio, parent ? parent.width - 44 * root.ratio : 560 * root.ratio) : chip.width
    height: root.expanded ? chip.height + list.height + root.gap : chip.height

    function mark(block) {
        return block.state === "succeeded" ? "✓" : block.state === "failed" ? "✗ " + block.status : "–";
    }

    function tone(block) {
        return block.state === "succeeded" ? root.colors.green : block.state === "failed" ? root.colors.red : root.colors.overlay1;
    }

    // A small framed action, such as putting a command in the editor.
    component Action: Rectangle {
        id: action
        property alias text: actionLabel.text
        signal activated
        anchors.verticalCenter: parent.verticalCenter
        width: actionLabel.width + 12 * root.ratio
        height: root.line - 6 * root.ratio
        radius: ChromeStyle.smallRadius * root.ratio
        color: actionArea.containsMouse ? Qt.alpha(root.colors.text, 0.1) : "transparent"
        border.width: Math.max(1, root.ratio)
        border.color: Qt.alpha(root.colors.overlay1, 0.5)

        ChromeText {
            id: actionLabel
            anchors.centerIn: parent
            width: implicitWidth
            height: implicitHeight
            pixelSize: root.small
            color: root.colors.subtext0
        }

        MouseArea {
            id: actionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: action.activated()
        }
    }

    Rectangle {
        id: chip
        objectName: "restoredChip"
        anchors.right: parent.right
        width: chipLabel.width + 16 * root.ratio
        height: root.line
        radius: height / 2
        color: Qt.rgba(root.colors.surface0.r, root.colors.surface0.g, root.colors.surface0.b, 0.95)
        border.width: Math.max(1, root.ratio)
        border.color: Qt.alpha(root.colors.mauve, 0.6)
        Accessible.role: Accessible.Button
        Accessible.name: chipLabel.text

        ChromeText {
            id: chipLabel
            anchors.centerIn: parent
            width: implicitWidth
            height: implicitHeight
            pixelSize: root.small
            text: "↺ " + root.blocks.length + (root.blocks.length === 1 ? " command" : " commands") + " from before the runtime restarted " + (root.expanded ? "▾" : "▸")
            color: root.colors.text
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.expanded = !root.expanded
        }
    }

    Rectangle {
        id: list
        objectName: "restoredList"
        visible: root.expanded
        y: chip.height + root.gap
        width: parent.width
        height: Math.min(rows.implicitHeight + 2 * root.gap, 12 * root.line)
        radius: ChromeStyle.controlRadius * root.ratio
        color: Qt.rgba(root.colors.surface0.r, root.colors.surface0.g, root.colors.surface0.b, 0.97)
        border.width: Math.max(1, root.ratio)
        border.color: Qt.alpha(root.colors.overlay1, 0.5)
        clip: true

        Flickable {
            anchors.fill: parent
            anchors.margins: root.gap
            contentHeight: rows.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: rows
                width: parent.width

                // The rule they come under, as a separator's.
                Item {
                    width: parent.width
                    height: root.line

                    ChromeText {
                        id: ruleLabel
                        anchors.verticalCenter: parent.verticalCenter
                        width: implicitWidth
                        height: implicitHeight
                        pixelSize: root.small
                        emphasized: true
                        text: "restored"
                        color: root.colors.mauve
                    }

                    Rectangle {
                        x: ruleLabel.width + root.gap
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x
                        height: Math.max(1, root.ratio)
                        color: Qt.alpha(root.colors.mauve, 0.4)
                    }
                }

                Repeater {
                    model: root.blocks

                    delegate: Item {
                        id: entry
                        required property var modelData
                        readonly property bool hidden: entry.modelData.command === root.redacted
                        width: rows.width
                        height: root.line

                        ChromeText {
                            id: status
                            width: 4 * root.small
                            height: parent.height
                            pixelSize: root.small
                            emphasized: true
                            text: root.mark(entry.modelData)
                            color: root.tone(entry.modelData)
                        }

                        ChromeText {
                            x: status.width
                            width: Math.max(0, actions.x - x - root.gap)
                            height: parent.height
                            pixelSize: root.small
                            text: entry.hidden ? "hidden by the history's filters" : entry.modelData.command + ((entry.modelData.place ?? "").length > 0 ? "   " + entry.modelData.place : "") + ((entry.modelData.started ?? "").length > 0 ? "   " + entry.modelData.started : "")
                            color: entry.hidden ? root.colors.subtext0 : root.colors.text
                        }

                        Row {
                            id: actions
                            anchors.right: parent.right
                            height: parent.height
                            spacing: 4 * root.ratio
                            visible: !entry.hidden

                            Action {
                                text: "edit"
                                onActivated: root.view.reuseRestored(entry.modelData.index, "edit")
                            }

                            Action {
                                visible: entry.modelData.whole === true
                                text: "rerun"
                                onActivated: root.view.reuseRestored(entry.modelData.index, "run")
                            }
                        }
                    }
                }
            }
        }
    }
}
