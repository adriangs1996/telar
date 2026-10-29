pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

ListView {
    id: root

    required property var colors
    required property var typography
    required property real rowHeight
    property real ratio: 1
    signal selected(string key)

    readonly property real scrollGutter: 6 * ratio
    readonly property real scrollWidth: 3 * ratio

    clip: true
    cacheBuffer: 0
    boundsBehavior: Flickable.StopAtBounds

    delegate: ProjectRow {
        width: Math.max(0, root.width - root.scrollGutter)
        height: root.rowHeight
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        onSelected: key => root.selected(key)
    }

    ChromeText {
        anchors.fill: parent
        text: "No workspaces"
        color: root.colors.subtext0
        pixelSize: root.typography.body
        visible: root.count === 0
    }

    ScrollBar.vertical: ScrollBar {
        width: root.scrollWidth
        padding: 0
        policy: root.contentHeight > root.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        contentItem: Rectangle {
            color: root.colors.overlay0
        }
        background: null
    }
}
