pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

NativeAgentStatus {
    id: root

    required property var colors
    required property var typography
    required property var geometry
    property bool needsAttention: false
    readonly property color stateColor: colors[record.statusColor ?? "overlay1"]
    displayMode: NativeAgentStatus.DisplayMode.pane_chip
    implicitWidth: statusText.length > 0 ? Math.ceil((measure.implicitWidth + 2 * geometry.chipInset) * geometry.density) / geometry.density : 0

    NativeChromeText {
        id: measure
        text: root.statusText
        pixelSize: root.typography.small
        visible: false
    }

    NativeRoundedRectangle {
        objectName: "paneStatusBackground"
        readonly property real chipHeight: Math.min(root.height, root.geometry.chipHeight)
        y: Math.floor((root.height - chipHeight) * root.geometry.density / 2) / root.geometry.density
        width: root.width
        height: chipHeight
        radius: root.geometry.chipRadius
        color: Qt.alpha(root.stateColor, 0.14)
    }

    ChromeText {
        objectName: "paneStatusLabel"
        x: root.geometry.chipInset
        width: Math.max(0, root.width - 2 * root.geometry.chipInset)
        height: root.height
        text: root.statusText
        pixelSize: root.typography.small
        color: root.stateColor
        elide: Text.ElideNone
    }
}
