pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

PaneHeaderLayout {
    id: root

    required property var record
    required property var colors
    required property var typography
    property bool focused: false
    property bool prefixPending: false
    // Preserve program and state before the mark, context and progress.
    readonly property bool compact: statusChip.implicitWidth > 0 && width < statusChip.implicitWidth + 4 * typography.body + (18 + 20 + 6 + 8) * ratio
    readonly property real tileWidth: compact ? 0 : 18 * ratio
    readonly property real contextGap: 8 * ratio
    measurements: ({
        index: root.tileWidth,
        name: nameLabel.implicitWidth + (contextLabel.text.length > 0 ? root.contextGap + contextLabel.implicitWidth : 0),
        chip: statusChip.implicitWidth,
        paused: root.record.imagesPaused ? pausedLabel.implicitWidth : 0,
        progress: root.compact ? 0 : progress.fullWidth,
        compactProgress: root.compact ? 0 : progress.compactWidth,
        needsAttention: root.record.needsAttention ?? false
    })

    ApplicationTile {
        objectName: "paneMark"
        x: root.indexBounds.x
        y: root.indexBounds.y + (root.indexBounds.height - height) / 2
        width: Math.min(root.tileWidth, root.indexBounds.width)
        height: 14 * root.ratio
        radius: 4 * root.ratio
        visible: root.tileWidth > 0
        mark: root.record
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        number: root.prefixPending ? root.record.index : ""
    }

    ChromeText {
        id: nameLabel
        objectName: "paneProgram"
        x: root.nameBounds.x
        y: root.nameBounds.y
        width: Math.min(root.nameBounds.width, implicitWidth)
        height: root.nameBounds.height
        text: (root.compact && root.prefixPending ? root.record.index + " " : "") + root.record.program
        pixelSize: root.typography.title
        color: root.focused ? root.colors.chromeText : root.colors.text
        emphasized: true
        elide: Text.ElideRight
    }

    ChromeText {
        id: contextLabel
        objectName: "paneContext"
        x: nameLabel.x + nameLabel.width + root.contextGap
        y: root.nameBounds.y
        width: Math.max(0, root.nameBounds.x + root.nameBounds.width - x)
        height: root.nameBounds.height
        text: root.record.context ?? ""
        pixelSize: root.typography.small
        color: root.colors.subtext0
        visible: width >= 4 * root.typography.body && text.length > 0
        elide: Text.ElideRight
    }

    ChromeText {
        id: pausedLabel
        objectName: "paneImagesPaused"
        x: root.pausedBounds.x
        y: root.pausedBounds.y
        width: root.pausedBounds.width
        height: root.pausedBounds.height
        text: "images paused"
        pixelSize: root.typography.body
        color: root.colors.yellow
        elide: Text.ElideNone
        visible: root.pausedBounds.width > 0
    }

    PaneStatusChip {
        id: statusChip
        objectName: "paneStatus"
        x: root.chipBounds.x
        y: root.chipBounds.y
        width: root.chipBounds.width
        height: root.chipBounds.height
        record: root.record.agent ?? ({})
        colors: root.colors
        typography: root.typography
        geometry: root.style
        needsAttention: root.record.needsAttention ?? false
        visible: root.chipBounds.width > 0
    }

    PaneProgress {
        id: progress
        objectName: "paneProgress"
        x: root.progressBounds.x
        y: root.progressBounds.y
        width: root.progressBounds.width
        height: root.progressBounds.height
        ratio: root.ratio
        record: root.record
        colors: root.colors
        typography: root.typography
        geometry: root.style
        compact: root.compactProgress
        visible: root.progressBounds.width > 0
    }
}
