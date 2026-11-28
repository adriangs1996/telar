pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// What Neovim says, as notices of telar's own stacked in a corner of the pane: each fades by
// itself, an error stays longer, and none asks for a key to go away. Only what is said to the
// person is a notice: a search's count goes on the status line, and the output of a command
// that lists in the pane's output panel. An error names its code apart from what it says, and
// a task's progress is a bar that fills in place.
Item {
    id: root

    // The editor's messages not yet gone from sight: items [{key, kind, text}], oldest first.
    required property var messages
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var items: messages.items ?? []
    // The person asked for everything that was said.
    signal history()
    // A notice's time is up, or the person closed it: the editor keeps it gone, for every view
    // its pane makes.
    signal dismissed(string key)

    // The notices shown: a message Neovim keeps is shown until its time is up.
    readonly property var shown: items.filter(item => item.text.length > 0 && item.kind !== "search" && item.kind !== "list").slice(-4)

    width: Math.min(parent.width - 24 * ratio, 340 * ratio)
    height: stack.height
    x: parent.width - width - 12 * ratio
    y: 12 * ratio
    visible: shown.length > 0

    Column {
        id: stack
        width: root.width
        spacing: 8 * root.ratio

        Repeater {
            model: root.shown

            delegate: Item {
                id: notice

                required property var modelData
                readonly property bool failure: modelData.kind === "error"
                readonly property bool caution: modelData.kind === "warning"
                readonly property bool progress: modelData.kind === "progress"
                readonly property color tone: failure ? root.colors.red : caution ? root.colors.yellow : progress ? root.colors.accent : root.colors.subtext0
                // The first line says what happened; the rest is its detail. An error's code,
                // as `E492:`, is set apart from it.
                readonly property var lines: modelData.text.split("\n")
                readonly property var coded: /^(E\d+|W\d+):\s*(.*)$/.exec(lines[0])
                readonly property string code: coded ? coded[1] : ""
                // A task's progress, as Neovim writes it: `clangd:  43% Indexing 412 of 958`.
                readonly property var task: progress ? /^([^:]+):\s*(?:(\d{1,3})%)?\s*(.*)$/.exec(lines[0]) : null
                readonly property string title: task ? task[1] : coded ? coded[2] : lines[0]
                readonly property string detail: task ? task[3] : lines.slice(1).join("\n").trim()
                // How far a task has come, when it says so as a percentage.
                readonly property var percent: task && task[2] ? [task[0], task[2]] : progress ? /(\d{1,3})\s*%/.exec(modelData.text) : null
                property real reveal: 0

                function dismiss() {
                    root.dismissed(notice.modelData.key);
                }

                width: stack.width
                height: Math.max(body.implicitHeight, 24 * root.ratio) + 24 * root.ratio
                opacity: reveal
                transform: Translate { x: (1 - notice.reveal) * 12 * root.ratio }

                Component.onCompleted: reveal = 1

                Behavior on reveal {
                    NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                }

                // An error is read, not glimpsed; a task in progress stays until it says more.
                Timer {
                    interval: notice.failure ? 9000 : notice.progress ? 12000 : 4500
                    running: true
                    onTriggered: notice.dismiss()
                }

                NvimSurface {
                    anchors.fill: parent
                    colors: root.colors
                    ratio: root.ratio
                }

                // What kind of thing was said, before the words.
                Rectangle {
                    x: 14 * root.ratio
                    y: 13 * root.ratio
                    width: 22 * root.ratio
                    height: width
                    radius: width / 2
                    color: Qt.alpha(notice.tone, 0.16)

                    ChromeIcon {
                        anchors.centerIn: parent
                        width: Math.round(root.typography.body * 1.05)
                        height: width
                        glyph: notice.failure ? "\uea87" : notice.caution ? "\uea6c" : notice.progress ? "\ueb19" : "\uea74"
                        pixelSize: width
                        color: notice.tone
                    }
                }

                Column {
                    id: body
                    x: 48 * root.ratio
                    y: 12 * root.ratio
                    width: parent.width - x - (notice.progress ? 16 : 34) * root.ratio
                    spacing: 3 * root.ratio

                    Row {
                        width: parent.width
                        spacing: 7 * root.ratio

                        // The code of an error, as a chip in its tone.
                        Rectangle {
                            visible: notice.code.length > 0
                            y: 1 * root.ratio
                            width: codeText.implicitWidth + 10 * root.ratio
                            height: codeText.implicitHeight + 4 * root.ratio
                            radius: 4 * root.ratio
                            color: Qt.alpha(notice.tone, 0.14)

                            Text {
                                id: codeText
                                anchors.centerIn: parent
                                text: notice.code
                                color: notice.tone
                                font.family: root.typography.primaryFamily || "Telar Forma"
                                font.pixelSize: Math.round(root.typography.small * 0.95)
                                textFormat: Text.PlainText
                                renderType: Text.NativeRendering
                            }
                        }

                        Text {
                            width: parent.width - (notice.code.length > 0 ? codeText.implicitWidth + 17 * root.ratio : 0)
                            text: notice.title
                            color: root.colors.text
                            font.pixelSize: root.typography.body
                            font.weight: notice.failure || notice.caution ? Font.DemiBold : Font.Medium
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                        }
                    }

                    Text {
                        width: parent.width
                        visible: notice.detail.length > 0
                        text: notice.detail
                        color: root.colors.subtext0
                        font.pixelSize: root.typography.small
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        maximumLineCount: 10
                        elide: Text.ElideRight
                        lineHeight: 1.25
                    }

                    // How far the task has come: the share it says, or a band that runs while it
                    // says none.
                    Item {
                        visible: notice.progress
                        width: parent.width
                        height: 10 * root.ratio

                        Rectangle {
                            id: track
                            y: 5 * root.ratio
                            width: parent.width
                            height: 3 * root.ratio
                            radius: height / 2
                            color: Qt.alpha(root.colors.text, 0.1)
                            clip: true

                            Rectangle {
                                id: band
                                property real at: 0
                                readonly property real share: notice.percent ? Math.min(100, Number(notice.percent[1])) / 100 : 0.3
                                x: notice.percent ? 0 : (at * (track.width + width)) - width
                                width: track.width * share
                                height: parent.height
                                radius: height / 2
                                color: notice.tone

                                NumberAnimation on at {
                                    running: notice.progress && !notice.percent
                                    from: 0
                                    to: 1
                                    duration: 1400
                                    loops: Animation.Infinite
                                }
                            }
                        }
                    }

                    // An error is where the rest of what was said matters.
                    Text {
                        visible: notice.failure
                        text: "History →"
                        color: historyArea.containsMouse ? root.colors.text : root.colors.accent
                        font.pixelSize: root.typography.small

                        MouseArea {
                            id: historyArea
                            anchors.fill: parent
                            anchors.margins: -4 * root.ratio
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.history()
                        }
                    }
                }

                ChromeIcon {
                    visible: !notice.progress
                    x: parent.width - width - 14 * root.ratio
                    y: 14 * root.ratio
                    width: Math.round(root.typography.small * 0.9)
                    height: width
                    glyph: "\uea76"
                    pixelSize: width
                    color: closeArea.containsMouse ? root.colors.text : root.colors.subtext0

                    MouseArea {
                        id: closeArea
                        anchors.fill: parent
                        anchors.margins: -6 * root.ratio
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: notice.dismiss()
                    }
                }
            }
        }
    }
}
