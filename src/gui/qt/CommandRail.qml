pragma ComponentBehavior: Bound

import QtQuick

// A map of the scrollback beside the pane: a segment per command the shell ran, as tall as its
// share of the rows and in the colour of how it ended, and the view over them. A click on a
// segment shows its command; elsewhere it glides there; the view drags.
Item {
    id: root

    required property var view
    required property var colors
    property real ratio: 1
    property bool moving: true
    readonly property var segments: root.view ? root.view.railSegments : []
    readonly property real viewTop: root.view ? root.view.railTop : 0
    readonly property real viewHeight: root.view ? root.view.railHeight : 1
    // Only while there is more than a view to map.
    readonly property bool useful: root.viewHeight < 1

    visible: root.useful || (root.view && root.view.railMatches.length > 0)
    width: (hover.hovered || dragArea.pressed ? 12 : 8) * root.ratio
    opacity: hover.hovered || dragArea.pressed ? 1 : 0.7

    Behavior on width {
        enabled: root.moving
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    HoverHandler {
        id: hover
    }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(1, root.ratio)
        height: parent.height
        color: Qt.alpha(root.colors.overlay1, 0.3)
    }

    // A click glides the view there.
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: (mouse) => root.view.scrollToFraction(mouse.y / root.height, true)
    }

    Repeater {
        model: root.segments

        delegate: Rectangle {
            id: segment

            required property var modelData
            readonly property string outcome: segment.modelData.state
            readonly property color tone: segment.outcome === "failed" ? root.colors.red : segment.outcome === "succeeded" ? root.colors.green : segment.outcome === "running" ? root.colors.accent : segment.outcome === "session" ? root.colors.mauve : root.colors.overlay1

            x: 1 * root.ratio
            y: segment.modelData.top * root.height
            width: root.width - 2 * root.ratio
            height: Math.max(2 * root.ratio, segment.modelData.height * root.height - root.ratio)
            radius: Math.min(width / 2, 2 * root.ratio)
            color: segment.tone
            opacity: segment.modelData.folded ? 0.3 : segment.outcome === "failed" ? 0.9 : 0.55
            border.width: segment.modelData.selected ? Math.max(1, root.ratio) : 0
            border.color: root.colors.accent

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.view.selectBlock(segment.modelData.index)
            }
        }
    }

    // The scrollback search's matches, a tick each.
    Repeater {
        model: root.view ? root.view.railMatches : []

        delegate: Rectangle {
            required property real modelData
            x: -5 * root.ratio
            y: modelData * root.height
            width: 4 * root.ratio
            height: Math.max(1, 2 * root.ratio)
            radius: height / 2
            color: root.colors.yellow
        }
    }

    // The view, which drags the rows one to one.
    Rectangle {
        id: thumb
        x: -2 * root.ratio
        y: root.viewTop * root.height
        width: root.width + 4 * root.ratio
        height: Math.max(14 * root.ratio, root.viewHeight * root.height)
        radius: 3 * root.ratio
        color: Qt.alpha(root.colors.text, dragArea.pressed ? 0.14 : 0.07)
        border.width: Math.max(1, root.ratio)
        border.color: Qt.alpha(root.colors.text, 0.5)

        MouseArea {
            id: dragArea
            property real grab: 0
            anchors.fill: parent
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            onPressed: (mouse) => dragArea.grab = mouse.y
            onPositionChanged: (mouse) => {
                if (!dragArea.pressed) {
                    return;
                }
                const top = thumb.y + mouse.y - dragArea.grab;
                root.view.scrollToFraction((top + thumb.height / 2) / root.height, false);
            }
        }
    }
}
