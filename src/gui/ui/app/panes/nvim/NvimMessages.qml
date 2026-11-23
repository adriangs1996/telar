pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// What Neovim says, as notices of telar's own stacked in a corner of the pane: each fades by
// itself, an error stays longer, and none asks for a key to go away.
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
    readonly property var shown: items.filter(item => item.text.length > 0).slice(-4)

    width: Math.min(parent.width - 24 * ratio, 300 * ratio)
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
                readonly property color tone: failure ? root.colors.red : caution ? root.colors.yellow : root.colors.accent
                // The first line says what happened; the rest is its detail.
                readonly property var lines: modelData.text.split("\n")
                readonly property string title: lines[0]
                readonly property string detail: lines.slice(1).join("\n").trim()
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

                // An error is read, not glimpsed.
                Timer {
                    interval: notice.failure ? 9000 : 4500
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
                        glyph: notice.failure ? "\uea87" : notice.caution ? "\uea6c" : "\ueab2"
                        pixelSize: width
                        color: notice.tone
                    }
                }

                Column {
                    id: body
                    x: 48 * root.ratio
                    y: 12 * root.ratio
                    width: parent.width - x - 34 * root.ratio
                    spacing: 3 * root.ratio

                    Text {
                        width: parent.width
                        text: notice.title
                        color: root.colors.text
                        font.pixelSize: root.typography.body
                        font.weight: Font.DemiBold
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
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

                    // An error is where the rest of what was said matters.
                    Text {
                        visible: notice.failure
                        text: "History \u2192"
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
