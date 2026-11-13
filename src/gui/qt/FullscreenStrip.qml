pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

FullscreenStripLayout {
    id: root

    required property var record
    required property var colors
    required property var typography
    signal selected(string key)
    signal leaveFullscreen()

    pixelSize: typography.body
    measurements: ({
        chip: chip.implicitWidth,
        progress: progress.fullWidth,
        compactProgress: progress.compactWidth
    })

    Repeater {
        model: root.items

        delegate: Item {
            id: pane

            required property var modelData
            readonly property var entry: modelData.entry
            readonly property bool lit: entry.focused || pointer.containsMouse
            x: modelData.bounds.x
            y: modelData.bounds.y
            width: modelData.bounds.width
            height: modelData.bounds.height
            objectName: "fullscreenPaneEntry"

            ApplicationMark {
                x: pane.modelData.mark.x
                y: pane.modelData.mark.y
                width: pane.modelData.mark.width
                height: pane.modelData.mark.height
                mark: pane.entry
                colors: root.colors
                pixelSize: root.typography.body
                primaryFamily: root.typography.primaryFamily ?? ""
                primaryStyle: root.typography.primaryStyle ?? ""
                ratio: root.ratio
                dimmed: !pane.lit
            }

            ChromeText {
                objectName: "fullscreenPaneIndex"
                x: pane.modelData.index.x
                y: pane.modelData.index.y
                width: pane.modelData.index.width
                height: pane.modelData.index.height
                text: pane.entry.index
                color: pane.lit ? root.colors.text : root.colors.overlay1
                pixelSize: root.typography.body
                emphasized: pane.entry.focused
                elide: Text.ElideNone
            }

            ChromeText {
                objectName: "fullscreenPaneName"
                x: pane.modelData.name.x
                y: pane.modelData.name.y
                width: pane.modelData.name.width
                height: pane.modelData.name.height
                text: pane.entry.program
                color: pane.entry.focused ? root.colors.subtext0 : pane.lit ? root.colors.text : root.colors.overlay1
                pixelSize: root.typography.body
                visible: width > 0
                elide: Text.ElideNone
            }

            NativeRoundedRectangle {
                x: pane.modelData.attention.x
                y: pane.modelData.attention.y
                width: pane.modelData.attention.width
                height: pane.modelData.attention.height
                radius: Math.max(width, height)
                color: root.colors[pane.entry.attentionColor || "overlay1"]
                visible: width > 0
            }

            MouseArea {
                id: pointer
                anchors.fill: parent
                enabled: !pane.entry.focused
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : undefined
                onPressed: root.selected(pane.entry.key)
            }
        }
    }

    PaneStatusChip {
        id: chip
        objectName: "fullscreenPaneStatus"
        x: root.chipBounds.x
        y: root.chipBounds.y
        width: root.chipBounds.width
        height: root.chipBounds.height
        record: root.record.agent ?? ({})
        colors: root.colors
        typography: root.typography
        geometry: root.style
        needsAttention: root.record.needsAttention ?? false
        visible: width > 0
    }

    PaneProgress {
        id: progress
        objectName: "fullscreenPaneProgress"
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
        visible: width > 0
    }

    Item {
        objectName: "leavePaneFullscreen"
        x: root.leaveBounds.x
        y: root.leaveBounds.y
        width: root.leaveBounds.width
        height: root.leaveBounds.height
        visible: width > 0

        ChromeText {
            anchors.fill: parent
            text: "\u26f6"
            pixelSize: root.typography.body
            color: leavePointer.containsMouse ? root.colors.text : root.colors.subtext0
            elide: Text.ElideNone
            horizontalAlignment: Text.AlignHCenter
            wholePixelCentering: true
        }

        MouseArea {
            id: leavePointer
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPressed: root.leaveFullscreen()
        }
    }
}
