pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// What Neovim says, as notices of telar's own stacked in a corner of the pane: each fades by
// itself, an error stays longer, and none asks for a key to go away.
Item {
    id: root

    // The editor's messages: items [{id, kind, text}], oldest first.
    required property var messages
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var items: messages.items ?? []
    // The notices shown: a message Neovim keeps is shown until its time is up.
    property var dismissed: ({})
    readonly property var shown: items.filter(item => item.text.length > 0 && !(root.stamp(item) in dismissed)).slice(-4)

    function stamp(item) {
        return item.id + ":" + item.text.length + ":" + item.kind;
    }

    // Fewer messages than before means Neovim cleared them: the next ones are new again.
    onItemsChanged: {
        if (items.length === 0) {
            dismissed = ({});
        }
    }

    width: Math.min(parent.width - 24 * ratio, 440 * ratio)
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
                property real reveal: 0

                width: stack.width
                height: body.implicitHeight + 20 * root.ratio
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
                    onTriggered: {
                        const next = Object.assign({}, root.dismissed);
                        next[root.stamp(notice.modelData)] = true;
                        root.dismissed = next;
                    }
                }

                NvimSurface {
                    anchors.fill: parent
                    colors: root.colors
                    ratio: root.ratio
                }

                Rectangle {
                    x: 10 * root.ratio
                    y: 10 * root.ratio
                    width: 3 * root.ratio
                    height: parent.height - 20 * root.ratio
                    radius: width / 2
                    color: notice.tone
                }

                Text {
                    id: body
                    x: 22 * root.ratio
                    y: 10 * root.ratio
                    width: parent.width - x - 14 * root.ratio
                    text: notice.modelData.text
                    color: root.colors.text
                    font.pixelSize: root.typography.body
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    maximumLineCount: 12
                    elide: Text.ElideRight
                    lineHeight: 1.25
                }
            }
        }
    }
}
