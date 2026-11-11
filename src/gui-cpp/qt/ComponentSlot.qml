pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

Item {
    id: root

    required property var controller
    required property var surface
    required property var colors
    required property var typography
    property real ratio: 1
    property bool sharedOverflow: false
    property var fittedLevels: null
    readonly property var hiddenRoots: visual.item?.hiddenRoots ?? []
    readonly property var fitNodes: visual.item?.fitNodes ?? []
    readonly property real overflowWidth: visual.item?.overflowWidth ?? 0
    readonly property real gap: 12 * ratio
    readonly property real diagnosticWidth: 8 * ratio
    readonly property real errorWidth: (surface.error ?? "").length > 0 ? diagnosticWidth : 0
    implicitWidth: Math.max(visual.item?.implicitWidth ?? 0, errorWidth)
    clip: true

    Loader {
        id: visual
        anchors.fill: parent
        // Legacy tabs slots are ignored here; navigation owns the tab strip.
        active: root.surface.kind !== "empty" && root.surface.kind !== "tabs"
        sourceComponent: content
    }

    ToolTip.visible: pointer.hovered && root.errorWidth > 0
    ToolTip.text: surface.error ?? ""
    HoverHandler { id: pointer }
    Text {
        anchors.right: parent.right
        width: root.diagnosticWidth
        height: parent.height
        visible: (root.surface.error ?? "").length > 0
        text: "!"
        color: root.colors.red
        font.family: "IBM Plex Sans"
        font.pixelSize: root.typography.small
        font.weight: Font.DemiBold
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter
        Accessible.name: root.surface.error ?? ""
    }

    Component {
        id: content
        Item {
            readonly property var hiddenRoots: tree.hiddenRoots
            readonly property var fitNodes: tree.fitNodes
            readonly property real overflowWidth: tree.overflowWidth
            implicitWidth: tree.fullWidth
            ComponentTree {
                id: tree
                anchors.fill: parent
                controller: root.controller
                surface: root.surface
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.height
                gap: root.gap
                fit: !root.sharedOverflow
                fittedLevels: root.fittedLevels
            }
        }
    }
}
