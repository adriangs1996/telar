pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

PaneHeaderLayout {
    id: root

    required property var record
    required property var colors
    required property var typography
    measurements: ({
        index: indexLabel.implicitWidth,
        name: nameLabel.implicitWidth,
        chip: statusChip.implicitWidth,
        paused: root.record.imagesPaused ? pausedLabel.implicitWidth : 0,
        progress: progress.fullWidth,
        compactProgress: progress.compactWidth,
        needsAttention: root.record.needsAttention ?? false
    })

    ChromeText {
        id: indexLabel
        objectName: "paneIndex"
        x: root.indexBounds.x
        y: root.indexBounds.y
        width: root.indexBounds.width
        height: root.indexBounds.height
        text: root.record.index
        emphasized: true
        pixelSize: root.typography.body
        color: root.colors.text
        elide: Text.ElideNone
    }

    ChromeText {
        id: nameLabel
        objectName: "paneProgram"
        x: root.nameBounds.x
        y: root.nameBounds.y
        width: root.nameBounds.width
        height: root.nameBounds.height
        text: root.record.program
        pixelSize: root.typography.body
        color: root.colors.subtext0
        elide: Text.ElideNone
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
