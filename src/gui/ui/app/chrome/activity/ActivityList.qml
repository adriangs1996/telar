pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

ListView {
    id: root

    required property var colors
    required property var typography
    required property var geometry
    property real headerHeight: 0
    // The room above a section header, which its separator halves.
    property real sectionGap: 0
    property real ratio: 1
    property real textScale: 1
    property string hoverIdentity: ""
    property bool semanticHover: false
    signal selected(string key)
    signal peekRequested(string key)
    signal hovered(string key, Item card)
    // A click on an element a mod drew in a card; the window runs it.
    signal elementActivated(string slot, string key, string revision, int element)

    clip: true
    cacheBuffer: 0
    boundsBehavior: Flickable.StopAtBounds
    spacing: geometry.spacing

    delegate: Item {
        id: entry
        required property var record
        required property int index
        readonly property real gapAbove: index > 0 && record.header ? root.sectionGap : 0
        readonly property real cardHeight: record.header ? root.headerHeight : record.command ? root.geometry.height : root.geometry.agentHeight
        readonly property bool animate: y + height > root.contentY && y < root.contentY + root.height

        width: root.geometry.width
        height: cardHeight + gapAbove

        Rectangle {
            objectName: "activitySectionSeparator"
            x: root.geometry.padding
            y: Math.round(entry.gapAbove / 2)
            width: Math.max(0, root.geometry.width - 2 * x)
            height: 1 / Screen.devicePixelRatio
            color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
            visible: entry.record.header === true && entry.index > 0
        }

        Loader {
            y: entry.gapAbove
            width: root.geometry.width
            height: entry.cardHeight
            sourceComponent: entry.record.header ? sectionHeader : entry.record.command ? commandCard : agentCard
        }

        Component {
            id: sectionHeader

            Item {
                objectName: "activitySectionHeader"

                ProviderMark {
                    objectName: "activitySectionIcon"
                    x: root.geometry.padding + (root.geometry.markColumn - width) / 2
                    y: (parent.height - height) / 2
                    width: Math.round(14 * root.ratio)
                    height: width
                    symbol: entry.record.symbol ?? ""
                    color: root.colors.subtext0
                    visible: symbol.length > 0
                }

                ChromeText {
                    x: root.geometry.textInset
                    width: Math.max(0, parent.width - x - sectionCount.width - 2 * root.geometry.padding)
                    height: parent.height
                    text: entry.record.title.toUpperCase()
                    color: root.colors.text
                    pixelSize: root.typography.small
                    emphasized: true
                }

                ChromeText {
                    id: sectionCount
                    x: parent.width - width - root.geometry.padding
                    width: implicitWidth
                    height: parent.height
                    text: entry.record.count
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                }
            }
        }

        Component {
            id: agentCard

            AgentCard {
                id: agent
                objectName: "agentCard"
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
                onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
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
