pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

NativeTabActivity {
    id: root

    required property var colors
    required property var typography
    required property var geometry
    color: colors[record.activityColor ?? "teal"]
    readonly property real fullWidth: record.progressText.length > 0 ? geometry.progressSide + 3 * geometry.progressPadding + measure.implicitWidth : 0
    readonly property real compactWidth: record.progressText.length > 0 ? geometry.progressSide + 2 * geometry.progressPadding : 0
    readonly property real capsuleHeight: Math.min(height, geometry.progressHeight)
    readonly property real ringSide: Math.max(0, Math.min(geometry.progressSide, capsuleHeight - geometry.progressInset, width - 2 * geometry.progressPadding))

    NativeChromeText {
        id: measure
        text: root.record.progressText
        pixelSize: root.typography.small
        visible: false
    }

    ChromeText {
        objectName: "paneProgressLabel"
        x: root.geometry.progressPadding + root.ringSide + root.geometry.progressPadding
        y: (root.height - root.capsuleHeight) / 2
        width: Math.max(0, root.width - root.geometry.progressPadding - x)
        height: root.capsuleHeight
        text: root.record.progressText
        pixelSize: root.typography.small
        color: root.color
        elide: Text.ElideNone
        visible: !root.compact && root.ringSide > 0
    }
}
