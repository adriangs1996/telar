pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

PaneHeaderLayout {
    id: root

    required property var record
    required property var colors
    required property var typography
    property bool focused: false
    // Preserve program and state before numbering, context and progress.
    readonly property bool compact: statusChip.implicitWidth > 0 && width < statusChip.implicitWidth + 4 * typography.body + (22 + 16 + 6 + 8) * ratio
    readonly property real indexSide: compact ? 0 : 22 * ratio
    measurements: ({
        index: root.indexSide,
        name: nameLabel.implicitWidth,
        chip: statusChip.implicitWidth,
        paused: root.record.imagesPaused ? pausedLabel.implicitWidth : 0,
        progress: root.compact ? 0 : progress.fullWidth,
        compactProgress: root.compact ? 0 : progress.compactWidth,
        needsAttention: root.record.needsAttention ?? false
    })

    NativeRoundedRectangle {
        objectName: "paneIndexBackground"
        x: root.indexBounds.x
        y: root.indexBounds.y + (root.indexBounds.height - height) / 2
        width: Math.min(root.indexSide, root.indexBounds.width)
        height: width
        radius: ChromeStyle.smallRadius * root.ratio
        visible: root.indexSide > 0
        color: Qt.alpha(root.focused ? root.colors.accent : root.colors.text, root.focused ? 0.16 : 0.06)
    }

    ChromeText {
        id: indexLabel
        objectName: "paneIndex"
        x: root.indexBounds.x
        y: root.indexBounds.y
        width: Math.min(root.indexSide, root.indexBounds.width)
        height: root.indexBounds.height
        text: root.record.index
        visible: root.indexSide > 0
        emphasized: true
        pixelSize: root.typography.body
        color: root.focused ? root.colors.accent : root.colors.chromeText
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideNone
    }

    ChromeText {
        id: nameLabel
        objectName: "paneProgram"
        x: root.nameBounds.x
        y: root.nameBounds.y
        width: root.nameBounds.width
        height: root.nameBounds.height
        text: root.compact ? root.record.index + " " + root.record.program : root.record.context && width >= 4 * root.typography.body ? root.record.program + " · " + root.record.context : root.record.program
        pixelSize: root.typography.body + 2 * root.ratio
        color: root.colors.chromeText
        emphasized: root.focused
        elide: implicitWidth > width ? Text.ElideMiddle : Text.ElideNone
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
