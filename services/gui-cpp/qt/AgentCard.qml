pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

ActivityFrame {
    id: root

    required property var typography

    Item {
        id: contextRow
        x: root.geometry.context.x
        y: root.geometry.context.y
        width: Math.max(0, root.width - 2 * x)
        height: root.geometry.context.height

        readonly property real statusReservation: Math.min(width / 2, root.geometry.projectSide + root.geometry.projectLabelGap + root.geometry.minimumProjectLabel)
        readonly property real projectWidth: Math.max(0, width - status.usedWidth - root.geometry.gap)

        AgentStatus {
            id: status
            objectName: "agentStatus"
            x: contextRow.statusReservation
            width: contextRow.width - x
            height: contextRow.height
            record: root.record
            colors: root.colors
            typography: root.typography
            geometry: root.geometry
            pulseAlpha: root.pulseAlpha
            running: root.animate
        }

        ChromeIcon {
            width: root.geometry.projectSide
            height: contextRow.height
            glyph: "\uf07b"
            color: root.colors.subtext0
            pixelSize: root.typography.small
            primaryFamily: root.typography.primaryFamily ?? ""
            primaryStyle: root.typography.primaryStyle ?? ""
            visible: contextRow.projectWidth >= width
        }

        ChromeText {
            objectName: "agentProjectLabel"
            x: root.geometry.projectSide + root.geometry.projectLabelGap
            width: Math.max(0, contextRow.projectWidth - x)
            height: contextRow.height
            text: root.record.project
            color: root.colors.subtext0
            pixelSize: root.typography.small
            visible: contextRow.projectWidth >= root.geometry.projectSide
        }
    }

    ChromeText {
        objectName: "agentTitleLabel"
        x: root.geometry.title.x
        y: root.geometry.title.y
        width: Math.max(0, root.width - 2 * x)
        height: root.geometry.title.height
        text: root.record.title
        color: root.colors.text
        pixelSize: root.typography.title
    }

    Item {
        id: detailRow
        x: root.geometry.detail.x
        y: root.geometry.detail.y
        width: Math.max(0, root.width - 2 * x)
        height: root.geometry.detail.height

        readonly property bool markFits: root.geometry.providerSide <= width

        ApplicationMark {
            objectName: "agentProviderMark"
            x: detailRow.width - width
            y: (detailRow.height - height) / 2
            width: root.geometry.providerSide
            height: width
            mark: root.record
            colors: root.colors
            ratio: root.ratio
            pixelSize: root.typography.small
            opacity: root.geometry.providerAlpha
            primaryFamily: root.typography.primaryFamily ?? ""
            primaryStyle: root.typography.primaryStyle ?? ""
            visible: detailRow.markFits
        }

        ChromeText {
            objectName: "agentDetailLabel"
            width: Math.max(0, detailRow.width - (detailRow.markFits ? root.geometry.providerSide + root.geometry.gap : 0))
            height: detailRow.height
            text: root.record.detail
            color: root.colors.overlay1
            pixelSize: root.typography.small
        }
    }

    Accessible.name: record.project + " " + record.title + " " + status.statusText + " " + record.detail
}
