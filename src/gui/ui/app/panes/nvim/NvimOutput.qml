pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// What a command that lists printed, as :ls, :set, :messages or a shell command do: a panel at
// the foot of the editor, under the command that printed it, whose text can be read whole,
// scrolled and selected to copy. It goes when Neovim clears what it said, or when it is closed.
Item {
    id: root
    objectName: "editorOutputPanel"

    // The editor's messages: items [{key, kind, text}], oldest first; the lines of those that
    // list are what the panel shows.
    required property var messages
    required property var colors
    required property var typography
    property real ratio: 1
    // The command line run last, as it was typed, and when it closed: the panel is titled by it
    // when the output comes right after, and is plain Output otherwise, as for a mapping's.
    property string command: ""
    property double commandAt: 0
    property string title: ""
    // The height of the editor's rows, and where the panel stands on: the top of the status line.
    property real cellHeight: 0
    property real ground: parent.height
    readonly property var listed: (messages.items ?? []).filter(item => item.kind === "list" && item.text.length > 0)
    readonly property string text: listed.map(item => item.text.replace(/^\n+/, "").replace(/\s+$/, "")).join("\n")
    readonly property int lineCount: text.length > 0 ? text.split("\n").length : 0
    readonly property real headerHeight: 38 * ratio
    readonly property real lineHeight: Math.max(cellHeight, Math.round(typography.body * 1.6))
    property real reveal: listed.length > 0 ? 1 : 0
    // The person closed it: each of its messages stays gone.
    signal dismissed(string key)

    // When it came, and how near that the line that ran it may have closed: in the same frame,
    // just before, or just after.
    property double shownAt: 0
    readonly property int nearby: 1500

    function name() {
        if (listed.length > 0 && title.length === 0) {
            shownAt = Date.now();
            title = command.length > 1 && shownAt - commandAt < nearby ? command : "Output";
        }
    }

    onListedChanged: {
        if (listed.length === 0)
            title = "";
        else
            Qt.callLater(name);
    }

    onCommandAtChanged: {
        if (listed.length > 0 && title === "Output" && command.length > 1 && commandAt - shownAt < nearby)
            title = command;
    }

    function close() {
        for (const item of root.listed)
            root.dismissed(item.key);
    }

    height: Math.min(parent.height * 0.45, headerHeight + Math.max(1, lineCount) * lineHeight + 20 * ratio)
    width: parent.width
    y: ground - height * reveal
    visible: reveal > 0
    clip: true

    Behavior on reveal {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(root.colors.panel_bg.r, root.colors.panel_bg.g, root.colors.panel_bg.b, 1)
    }

    Rectangle {
        width: parent.width
        height: Math.max(1, root.ratio) / Screen.devicePixelRatio
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha * 1.5)
    }

    // The command that printed it, and how much it printed.
    Item {
        width: parent.width
        height: root.headerHeight

        ChromeIcon {
            id: outputIcon
            x: 16 * root.ratio
            width: Math.round(root.typography.body * 1.05)
            height: parent.height
            glyph: "\ueb9d"
            pixelSize: width
            color: Qt.alpha(root.colors.subtext0, 0.85)
        }

        Text {
            x: outputIcon.x + outputIcon.width + 10 * root.ratio
            width: Math.max(0, lines.x - x - 12 * root.ratio)
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: root.title
            color: root.colors.text
            font.family: root.title.startsWith(":") ? (root.typography.primaryFamily || "Telar Forma") : "IBM Plex Sans"
            font.pixelSize: root.typography.body
            textFormat: Text.PlainText
            renderType: Text.NativeRendering
            elide: Text.ElideRight
        }

        ChromeText {
            id: lines
            x: closer.x - width - 14 * root.ratio
            width: implicitWidth
            height: parent.height
            text: root.lineCount === 1 ? "1 line" : root.lineCount + " lines"
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, 0.45)
        }

        ChromeIcon {
            id: closer
            objectName: "editorOutputClose"
            x: parent.width - width - 16 * root.ratio
            width: Math.round(root.typography.small * 0.95)
            height: parent.height
            glyph: "\uea76"
            pixelSize: width
            color: closeArea.containsMouse ? root.colors.text : root.colors.subtext0

            MouseArea {
                id: closeArea
                anchors.fill: parent
                anchors.margins: -8 * root.ratio
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.close()
            }
        }

        Rectangle {
            y: parent.height - height
            width: parent.width
            height: Math.max(1, root.ratio) / Screen.devicePixelRatio
            color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
        }
    }

    Flickable {
        id: scroller
        x: 16 * root.ratio
        y: root.headerHeight + 8 * root.ratio
        width: parent.width - 32 * root.ratio
        height: parent.height - y - 8 * root.ratio
        contentWidth: Math.max(width, output.contentWidth)
        contentHeight: output.contentHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        TextEdit {
            id: output
            objectName: "editorOutput"
            width: Math.max(scroller.width, contentWidth)
            text: root.text
            readOnly: true
            selectByMouse: true
            color: root.colors.subtext0
            selectionColor: Qt.alpha(root.colors.accent, 0.35)
            selectedTextColor: root.colors.text
            font.family: root.typography.primaryFamily || "Telar Forma"
            font.pixelSize: root.typography.body
            textFormat: TextEdit.PlainText
            renderType: Text.NativeRendering
            activeFocusOnPress: true
        }
    }
}
