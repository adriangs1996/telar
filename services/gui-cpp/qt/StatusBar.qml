pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui
import "ComponentFit.js" as ComponentFit

NativeRoundedRectangle {
    id: root

    required property var metrics
    required property var colors
    required property var typography
    property var controller: null
    property string diagnostic
    property var mode: ({kind: 0, hints: []})
    property string tlsColor
    property real ratio: 1
    signal diagnosticDismissed()

    readonly property real capsuleInset: 8 * ratio
    readonly property real margin: capsuleInset
    readonly property real trailingMargin: 2 * capsuleInset
    readonly property real capsuleHeight: 22 * ratio
    readonly property real badgeGap: 10 * ratio
    readonly property real diagnosticShare: 0.5
    readonly property real contentWidth: Math.max(0, width - margin - trailingMargin)
    readonly property real metricsWidth: Math.max(0, contentWidth - (tlsChip.visible ? tlsChip.width + badgeGap : 0))
    readonly property real density: Screen.devicePixelRatio
    // A mod's bottom bar replaces the components; mode, TLS and diagnostics stay native.
    readonly property var drawn: controller?.elementBars?.bottom_bar ?? null

    color: colors.bottombarBackground
    replaceBackground: true

    Item {
        id: row

        x: root.margin
        width: Math.max(0, root.metricsWidth - (diagnosticChip.visible ? diagnosticChip.width + root.badgeGap : 0))
        height: parent.height

        MetricsGroup {
            width: parent.width
            height: parent.height
            metrics: root.metrics
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            visible: root.mode.kind === 0 && root.controller === null
        }

        Item {
            id: components
            anchors.fill: parent
            visible: root.mode.kind === 0 && root.controller !== null && root.drawn === null
            readonly property var slots: root.controller?.componentBars ?? ({})
            readonly property real gap: 24 * root.ratio
            readonly property var fitted: ComponentFit.allocate([
                {nodes: leftSlot.fitNodes, gap: leftSlot.gap, width: leftSlot.implicitWidth, minimumWidth: leftSlot.errorWidth, tabs: false, overflowWidth: leftSlot.overflowWidth},
                {nodes: centerSlot.fitNodes, gap: centerSlot.gap, width: centerSlot.implicitWidth, minimumWidth: centerSlot.errorWidth, tabs: false, overflowWidth: centerSlot.overflowWidth},
                {nodes: rightSlot.fitNodes, gap: rightSlot.gap, width: rightSlot.implicitWidth, minimumWidth: rightSlot.errorWidth, tabs: false, overflowWidth: rightSlot.overflowWidth},
                {nodes: legacySlot.fitNodes, gap: legacySlot.gap, width: legacySlot.implicitWidth, minimumWidth: legacySlot.errorWidth, tabs: false, overflowWidth: legacySlot.overflowWidth},
            ], width, gap, 0, overflow.implicitWidth)
            readonly property real leftEnd: leftSlot.width + (leftSlot.width > 0 ? gap : 0)
            readonly property real contentEnd: width - (fitted.overflowWidth > 0 ? fitted.overflowWidth + gap : 0)
            readonly property real rightStart: (rightSlot.width > 0 ? rightSlot.x : legacySlot.width > 0 ? legacySlot.x : contentEnd) - (rightSlot.width > 0 || legacySlot.width > 0 ? gap : 0)
            readonly property var views: [
                {surface: slots.left, roots: leftSlot.hiddenRoots},
                {surface: slots.center, roots: centerSlot.hiddenRoots},
                {surface: slots.right, roots: rightSlot.hiddenRoots},
                {surface: slots.top, roots: legacySlot.hiddenRoots},
            ]
            readonly property var hiddenEntries: {
                let result = [];
                for (const view of views) {
                    for (const index of view.roots) {
                        result.push({surface: view.surface, index: index});
                    }
                }
                return result;
            }
            readonly property int maximumOverflowCount: [leftSlot.fitNodes, centerSlot.fitNodes, rightSlot.fitNodes, legacySlot.fitNodes].reduce((total, nodes) => total + nodes.filter(node => node.parent < 0).length, 0)

            Repeater {
                model: [leftSlot, centerSlot, rightSlot, legacySlot]

                delegate: NativeRoundedRectangle {
                    required property var modelData
                    objectName: "statusCapsule"
                    x: modelData.x - root.capsuleInset
                    y: (components.height - height) / 2
                    width: modelData.width + 2 * root.capsuleInset
                    height: root.capsuleHeight
                    radius: height / 2
                    color: Qt.alpha(root.colors.chromeText, 0.07)
                    visible: modelData.width > 0
                }
            }

            ComponentSlot {
                id: leftSlot
                controller: root.controller
                surface: components.slots.left ?? ({kind: "empty"})
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                width: components.fitted.widths[0]
                sharedOverflow: true
                fittedLevels: components.fitted.levels[0]
                height: parent.height
            }

            ComponentSlot {
                id: centerSlot
                x: Math.max(components.leftEnd, Math.min((components.width - width) / 2, components.rightStart - width))
                controller: root.controller
                surface: components.slots.center ?? ({kind: "empty"})
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                width: components.fitted.widths[1]
                sharedOverflow: true
                fittedLevels: components.fitted.levels[1]
                height: parent.height
            }

            ComponentSlot {
                id: rightSlot
                x: legacySlot.x - (legacySlot.width > 0 ? components.gap : 0) - width
                controller: root.controller
                surface: components.slots.right ?? ({kind: "empty"})
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                width: components.fitted.widths[2]
                sharedOverflow: true
                fittedLevels: components.fitted.levels[2]
                height: parent.height
            }

            ComponentSlot {
                id: legacySlot
                x: components.contentEnd - width
                controller: root.controller
                surface: components.slots.top ?? ({kind: "empty"})
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                width: components.fitted.widths[3]
                sharedOverflow: true
                fittedLevels: components.fitted.levels[3]
                height: parent.height
            }

            ComponentOverflow {
                id: overflow
                controller: root.controller
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                entries: components.hiddenEntries
                maximumCount: components.maximumOverflowCount
                x: components.width - width
                width: components.fitted.overflowWidth
                height: parent.height
            }
        }

        ElementHost {
            objectName: "bottomBarElements"
            anchors.fill: parent
            visible: root.mode.kind === 0 && root.drawn !== null
            content: root.drawn
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            controller: root.controller
            builtins: ({metrics: metricsPiece, bar_left: leftPiece, bar_center: centerPiece, bar_right: rightPiece})
        }

        component BarPiece: ComponentSlot {
            implicitHeight: root.capsuleHeight
            controller: root.controller
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
        }

        Component {
            id: metricsPiece
            MetricsGroup {
                implicitHeight: root.capsuleHeight
                metrics: root.metrics
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
            }
        }

        Component {
            id: leftPiece
            BarPiece {
                surface: components.slots.left ?? ({kind: "empty"})
            }
        }

        Component {
            id: centerPiece
            BarPiece {
                surface: components.slots.center ?? ({kind: "empty"})
            }
        }

        Component {
            id: rightPiece
            BarPiece {
                surface: components.slots.right ?? ({kind: "empty"})
            }
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

        x: root.width - root.trailingMargin - width
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
            cursorShape: Qt.PointingHandCursor
            onClicked: root.diagnosticDismissed()
        }

        Accessible.role: Accessible.Button
        Accessible.name: root.diagnostic
        Accessible.onPressAction: root.diagnosticDismissed()
    }
}
