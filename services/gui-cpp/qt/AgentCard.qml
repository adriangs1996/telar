pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

ActivityFrame {
    id: root

    required property var typography
    property var controller: null
    // Mod content for this card and its pieces, by slot name.
    readonly property var elements: record.elements ?? ({})
    readonly property bool drawn: elements.agent_card !== undefined
    readonly property var builtins: ({agent_mark: markPiece, agent_title: titlePiece, agent_project: projectPiece, agent_status: statusPiece})

    implicitHeight: record.compact ? geometry.compactHeight : geometry.agentHeight

    ApplicationTile {
        objectName: "agentProviderMark"
        x: root.geometry.padding
        y: root.geometry.padding + (root.geometry.agentTitleRow - height) / 2
        width: root.geometry.tileWidth
        height: root.geometry.tileHeight
        radius: 4 * root.ratio
        visible: !root.drawn && root.elements.agent_mark === undefined
        mark: root.record
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
    }

    ChromeText {
        objectName: "agentTitleLabel"
        x: root.geometry.padding + root.geometry.tileWidth + root.geometry.gap
        y: root.geometry.padding
        width: Math.max(0, root.width - x - root.geometry.padding)
        height: root.geometry.agentTitleRow
        visible: !root.drawn && root.elements.agent_title === undefined
        text: root.record.title
        color: root.colors.chromeText
        pixelSize: root.typography.body
        emphasized: true
    }

    Item {
        id: detailRow
        x: root.geometry.padding
        y: root.geometry.agentDetailY
        width: Math.max(0, root.width - 2 * x)
        height: root.geometry.agentDetailRow
        visible: !root.drawn

        AgentStatus {
            id: status
            objectName: "agentStatus"
            x: detailRow.width / 2
            width: detailRow.width - x
            height: detailRow.height
            visible: root.elements.agent_status === undefined
            record: root.record
            colors: root.colors
            typography: root.typography
            geometry: root.geometry
            pulseAlpha: root.pulseAlpha
            running: root.animate && visible
        }

        ChromeText {
            objectName: "agentProjectLabel"
            width: Math.max(0, detailRow.width - status.usedWidth - root.geometry.gap)
            height: detailRow.height
            visible: root.elements.agent_project === undefined
            text: root.record.project
            color: root.colors.subtext0
            pixelSize: root.typography.small
        }
    }

    // A mod piece takes the place of the default piece it names.
    Repeater {
        model: root.drawn ? [] : [
            {slot: "agent_mark", x: root.geometry.padding, y: root.geometry.padding, width: root.geometry.tileWidth, height: root.geometry.agentTitleRow},
            {slot: "agent_title", x: root.geometry.padding + root.geometry.tileWidth + root.geometry.gap, y: root.geometry.padding, width: Math.max(0, root.width - 2 * root.geometry.padding - root.geometry.tileWidth - root.geometry.gap), height: root.geometry.agentTitleRow},
            {slot: "agent_project", x: detailRow.x, y: detailRow.y, width: Math.max(0, detailRow.width / 2 - root.geometry.gap), height: detailRow.height},
            {slot: "agent_status", x: detailRow.x + detailRow.width / 2, y: detailRow.y, width: detailRow.width / 2, height: detailRow.height},
        ].filter(piece => root.elements[piece.slot] !== undefined)

        delegate: ElementHost {
            required property var modelData
            x: modelData.x
            y: modelData.y
            width: modelData.width
            height: modelData.height
            content: root.elements[modelData.slot]
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            controller: root.controller
            builtins: root.builtins
        }
    }

    ElementHost {
        objectName: "agentCardElements"
        anchors.fill: parent
        visible: root.drawn
        content: root.elements.agent_card ?? null
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        controller: root.controller
        builtins: root.builtins
    }

    Component {
        id: markPiece
        ApplicationTile {
            implicitWidth: root.geometry.tileWidth
            implicitHeight: root.geometry.tileHeight
            radius: 4 * root.ratio
            mark: root.record
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
        }
    }

    Component {
        id: titlePiece
        ChromeText {
            implicitHeight: root.geometry.agentTitleRow
            text: root.record.title
            color: root.colors.chromeText
            pixelSize: root.typography.body
            emphasized: true
        }
    }

    Component {
        id: projectPiece
        ChromeText {
            implicitHeight: root.geometry.agentDetailRow
            text: root.record.project
            color: root.colors.subtext0
            pixelSize: root.typography.small
        }
    }

    Component {
        id: statusPiece
        AgentStatus {
            // Its label shortens to fit, so it asks for half a card and takes what it gets.
            implicitWidth: root.geometry.width / 2
            implicitHeight: root.geometry.agentDetailRow
            record: root.record
            colors: root.colors
            typography: root.typography
            geometry: root.geometry
            pulseAlpha: root.pulseAlpha
            running: root.animate
        }
    }

    Accessible.name: record.project + " " + record.title + " " + status.statusText + " " + record.detail
}
