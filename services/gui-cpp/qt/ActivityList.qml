pragma ComponentBehavior: Bound

import QtQuick

ListView {
    id: root

    required property var colors
    required property var typography
    required property var geometry
    property real ratio: 1
    property real textScale: 1
    signal selected(string key)

    clip: true
    cacheBuffer: 0
    boundsBehavior: Flickable.StopAtBounds
    spacing: geometry.spacing

    delegate: Item {
        id: entry
        required property var record
        required property int index
        readonly property real groupGap: index > 0 && record.startsProject ? root.geometry.groupGap : 0
        readonly property real cardHeight: record.compact ? root.geometry.compactHeight : root.geometry.height
        readonly property real indentation: Math.min(root.geometry.width / 3, (record.depth ?? 0) * root.geometry.taskIndent)
        readonly property bool animate: y + height > root.contentY && y < root.contentY + root.height

        width: root.geometry.width
        height: cardHeight + groupGap

        Loader {
            x: entry.indentation
            y: entry.groupGap
            width: Math.max(0, root.geometry.width - x)
            height: entry.cardHeight
            sourceComponent: entry.record.command ? commandCard : entry.record.task ? taskCard : agentCard
        }

        Component {
            id: agentCard

            AgentCard {
                objectName: "agentCard"
                record: entry.record
                geometry: root.geometry
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                animate: entry.animate
                onSelected: key => root.selected(key)
            }
        }

        Component {
            id: taskCard

            TaskCard {
                objectName: "taskCard"
                record: entry.record
                geometry: root.geometry
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                animate: entry.animate
                onSelected: key => root.selected(key)
            }
        }

        Component {
            id: commandCard

            CommandCard {
                objectName: "commandCard"
                record: entry.record
                geometry: root.geometry
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                onSelected: key => root.selected(key)
            }
        }
    }

    Rectangle {
        parent: root
        anchors.right: parent.right
        y: root.contentY * (root.height - height) / Math.max(1, root.contentHeight - root.height)
        width: root.geometry.scrollbarWidth
        height: Math.min(root.height, Math.max(root.geometry.context.height, root.height * root.height / Math.max(1, root.contentHeight)))
        color: root.colors.overlay0
        visible: root.contentHeight > root.height
    }

    ChromeText {
        parent: root
        anchors.fill: parent
        text: "No activity"
        color: root.colors.subtext0
        pixelSize: root.typography.body
        visible: root.count === 0
    }
}
