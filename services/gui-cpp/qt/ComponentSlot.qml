pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

Item {
    id: root

    required property var controller
    required property var surface
    required property var colors
    required property var typography
    property real ratio: 1
    property real textScale: 1
    property bool sharedOverflow: false
    property var fittedLevels: null
    readonly property var hiddenRoots: visual.item?.hiddenRoots ?? []
    readonly property var fitNodes: visual.item?.fitNodes ?? []
    readonly property real overflowWidth: visual.item?.overflowWidth ?? 0
    readonly property bool tabs: surface.kind === "tabs"
    readonly property real diagnosticWidth: 8 * ratio
    readonly property real errorWidth: (surface.error ?? "").length > 0 ? diagnosticWidth : 0
    implicitWidth: Math.max(tabs ? 200 * ratio : visual.item?.implicitWidth ?? 0, errorWidth)
    clip: true

    Loader {
        id: visual
        anchors.fill: parent
        active: root.surface.kind !== "empty"
        sourceComponent: {
            switch (root.surface.kind) {
            case "tabs": return tabStrip;
            case "metrics": return metrics;
            case "machines": return machines;
            default: return content;
            }
        }
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
        id: tabStrip
        TerminalTabs {
            controller: root.controller
            model: root.controller.tabs
            prefixPending: root.controller.prefixPending
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            textScale: root.textScale
            onSelected: key => root.controller.execute(GuiController.Action.select_tab, key)
            onClosed: key => root.controller.execute(GuiController.Action.close_tab, key)
            onRenamed: root.controller.execute(GuiController.Action.rename_tab)
            onCreated: root.controller.execute(GuiController.Action.new_tab)
        }
    }

    Component {
        id: metrics
        MetricsGroup {
            metrics: root.controller.hostMetrics
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
        }
    }

    Component {
        id: machines
        MachineChrome {
            controller: root.controller
            colors: root.colors
            implicitWidth: preferredWidth
        }
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
                fit: !root.sharedOverflow
                fittedLevels: root.fittedLevels
            }
        }
    }
}
