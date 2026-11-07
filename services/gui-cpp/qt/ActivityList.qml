pragma ComponentBehavior: Bound

import QtQuick

ListView {
    id: root

    required property var colors
    required property var typography
    required property var geometry
    property real ratio: 1
    property real textScale: 1
    property var controller: null
    property string hoverIdentity: ""
    property bool semanticHover: false
    signal selected(string key)
    signal peekRequested(string key)
    signal hovered(string key, Item card)

    clip: true
    cacheBuffer: 0
    boundsBehavior: Flickable.StopAtBounds
    spacing: geometry.spacing

    delegate: Item {
        id: entry
        required property var record
        required property int index
        readonly property real groupGap: index > 0 && record.startsProject ? root.geometry.groupGap : 0
        readonly property real cardHeight: record.compact ? root.geometry.compactHeight : record.command || record.task ? root.geometry.height : root.geometry.agentHeight
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
                id: agent
                objectName: "agentCard"
                controller: root.controller
                record: entry.record
                geometry: root.geometry
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                animate: entry.animate
                heldHover: entry.record.key === root.hoverIdentity
                semanticHover: root.semanticHover
                onHoverRequested: key => root.hovered(key, agent)
                onSelected: key => root.selected(key)
                onPeekRequested: key => root.peekRequested(key)
            }
        }

        Component {
            id: taskCard

            TaskCard {
                id: task
                objectName: "taskCard"
                record: entry.record
                geometry: root.geometry
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                animate: entry.animate
                heldHover: entry.record.key === root.hoverIdentity
                semanticHover: root.semanticHover
                onHoverRequested: key => root.hovered(key, task)
                onSelected: key => root.selected(key)
                onPeekRequested: key => root.peekRequested(key)
            }
        }

        Component {
            id: commandCard

            CommandCard {
                id: command
                objectName: "commandCard"
                record: entry.record
                geometry: root.geometry
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                heldHover: entry.record.key === root.hoverIdentity
                semanticHover: root.semanticHover
                onHoverRequested: key => root.hovered(key, command)
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
        x: 8 * root.ratio
        y: 4 * root.ratio
        width: Math.max(0, root.width - 2 * x)
        height: root.typography.bodyRow ?? root.typography.body * 1.3
        text: "No activity"
        color: root.colors.subtext0
        pixelSize: root.typography.body
        visible: root.count === 0
    }
}
