pragma ComponentBehavior: Bound

import QtQuick

Rectangle {
    id: root

    required property var metrics
    required property var colors
    required property var typography
    property string diagnostic
    property var mode: ({kind: 0, hints: []})
    property string tlsColor
    property real ratio: 1
    signal diagnosticDismissed()

    readonly property real margin: 8 * ratio
    readonly property real badgeGap: 10 * ratio
    readonly property real diagnosticShare: 0.5
    readonly property real contentWidth: Math.max(0, width - 2 * margin)
    readonly property real metricsWidth: Math.max(0, contentWidth - (tlsChip.visible ? tlsChip.width + badgeGap : 0))
    readonly property real density: Screen.devicePixelRatio

    color: colors.panelBackground

    Item {
        id: row

        x: root.margin
        width: Math.max(0, root.metricsWidth - (diagnosticChip.visible ? diagnosticChip.width + root.badgeGap : 0))
        height: parent.height
        clip: true

        MetricsGroup {
            width: parent.width
            height: parent.height
            metrics: root.metrics
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            visible: root.mode.kind === 0
        }

        ModeBar {
            anchors.fill: parent
            mode: root.mode
            grid: root.typography.grid ?? ({})
            colors: root.colors
            ratio: root.ratio
            visible: root.mode.kind !== 0
        }
    }

    BarBadge {
        id: tlsChip

        x: root.width - root.margin - width
        y: Math.round((root.height - height) * root.density / 2) / root.density
        width: Math.min(implicitWidth, root.contentWidth)
        height: implicitHeight
        text: "TLS"
        ink: root.tlsColor.length > 0 ? root.colors[root.tlsColor] : "transparent"
        pixelSize: root.typography.small
        ratio: root.ratio
        visible: root.tlsColor.length > 0 && width > 0
    }

    BarBadge {
        id: diagnosticChip

        x: root.margin + root.metricsWidth - width
        y: Math.round((root.height - height) * root.density / 2) / root.density
        width: Math.min(implicitWidth, root.metricsWidth * root.diagnosticShare)
        height: implicitHeight
        text: root.diagnostic
        ink: root.colors.red
        pixelSize: root.typography.small
        ratio: root.ratio
        visible: root.diagnostic.length > 0 && width > 0

        MouseArea {
            anchors.fill: parent
            onClicked: root.diagnosticDismissed()
        }

        Accessible.role: Accessible.Button
        Accessible.name: root.diagnostic
        Accessible.onPressAction: root.diagnosticDismissed()
    }
}
