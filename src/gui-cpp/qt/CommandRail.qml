pragma ComponentBehavior: Bound

import QtQuick

// A dot per command the shell ran, newest at the bottom, in the colour of how it ended: a
// minimap beside the pane. A click shows the command's block.
Item {
    id: root

    required property var view
    required property var colors
    property real ratio: 1
    property bool moving: true
    readonly property int shownDots: 14
    readonly property var dots: root.view.rail.slice(-root.shownDots)
    // The newest command drawn so far: a newer one pops in.
    property int newest: -1

    visible: root.dots.length > 0
    width: 13 * root.ratio
    opacity: hover.hovered ? 1 : 0.7

    onDotsChanged: Qt.callLater(() => root.newest = root.dots.length > 0 ? root.dots[root.dots.length - 1].index : -1)

    HoverHandler {
        id: hover
    }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(1, root.ratio)
        height: parent.height
        color: Qt.alpha(root.colors.overlay1, 0.3)
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        spacing: 7 * root.ratio

        Repeater {
            model: root.dots

            delegate: Item {
                id: dot

                required property var modelData
                readonly property string outcome: dot.modelData.state
                readonly property color tone: dot.outcome === "failed" ? root.colors.red : dot.outcome === "succeeded" ? root.colors.green : dot.outcome === "running" ? root.colors.accent : root.colors.overlay1

                width: 13 * root.ratio
                height: 7 * root.ratio

                Component.onCompleted: {
                    if (root.moving && dot.modelData.index > root.newest && root.newest >= 0) {
                        popIn.start();
                    }
                }

                // The block selected from the editor: a ring in the accent colour around its dot.
                Rectangle {
                    anchors.centerIn: parent
                    visible: dot.modelData.selected
                    width: 15 * root.ratio
                    height: width
                    radius: width / 2
                    color: "transparent"
                    border.width: Math.max(1, 1.5 * root.ratio)
                    border.color: root.colors.accent
                }

                // A failed command's dot keeps a halo, so it stands out among the rest.
                Rectangle {
                    anchors.centerIn: parent
                    visible: dot.outcome === "failed"
                    width: 13 * root.ratio
                    height: width
                    radius: width / 2
                    color: Qt.alpha(dot.tone, 0.22)
                    scale: core.scale
                }

                Rectangle {
                    id: core
                    anchors.centerIn: parent
                    width: 7 * root.ratio
                    height: width
                    radius: width / 2
                    color: dot.tone
                }

                NumberAnimation {
                    id: popIn
                    target: core
                    property: "scale"
                    from: 0.4
                    to: 1
                    duration: 320
                    easing.type: Easing.OutBack
                    easing.overshoot: 2.4
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -3 * root.ratio
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.view.selectBlock(dot.modelData.index)
                }
            }
        }
    }
}
