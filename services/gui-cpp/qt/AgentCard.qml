pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

ActivityFrame {
    id: root

    required property var typography

    implicitHeight: record.compact ? geometry.compactHeight : geometry.agentHeight

    ApplicationTile {
        objectName: "agentProviderMark"
        x: root.geometry.padding
        y: root.geometry.padding + (root.geometry.agentTitleRow - height) / 2
        width: root.geometry.tileWidth
        height: root.geometry.tileHeight
        radius: 4 * root.ratio
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

        AgentStatus {
            id: status
            objectName: "agentStatus"
            x: detailRow.width / 2
            width: detailRow.width - x
            height: detailRow.height
            record: root.record
            colors: root.colors
            typography: root.typography
            geometry: root.geometry
            pulseAlpha: root.pulseAlpha
            running: root.animate
        }

        ChromeText {
            objectName: "agentProjectLabel"
            width: Math.max(0, detailRow.width - status.usedWidth - root.geometry.gap)
            height: detailRow.height
            text: root.record.project
            color: root.colors.subtext0
            pixelSize: root.typography.small
        }
    }

    Accessible.name: record.project + " " + record.title + " " + status.statusText + " " + record.detail
}
