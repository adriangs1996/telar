pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

// One indicator for a summary group's metrics and meters: a ring with an arc
// per entry in its entry's state, named by the worst entry once any crosses
// its threshold, with "+N" for the others that did. Hovering or clicking it
// shows every entry.
Item {
    id: root

    required property var controller
    required property var surface
    required property var node
    required property var colors
    required property var typography
    property real ratio: 1
    property real rowHeight: 26 * ratio
    property bool pinned: false

    readonly property var metricNames: ["cpu", "memory", "battery"]
    readonly property var metrics: controller?.hostMetrics ?? ({})
    // severity: -1 unknown, 0 normal, 1 warning, 2 danger.
    readonly property var entries: {
        const result = [];
        for (const child of surface.nodes ?? []) {
            if (child.parent !== node.index || child.tooltip) {
                continue;
            }

            if (child.kind === "metric") {
                const record = metrics[metricNames[child.metric]] ?? null;
                if (record === null || record.absent) {
                    continue;
                }

                result.push({name: record.name, value: record.text, fraction: record.percent / 100, severity: record.available ? record.severity : -1});
            } else if (child.kind === "meter") {
                result.push({name: child.text, value: child.detail.length > 0 ? child.detail : Math.round(child.value * 100) + "%", fraction: child.value, severity: child.tone === 5 ? 2 : child.tone === 4 ? 1 : 0});
            }
        }

        return result;
    }
    // Worst first; the sort is stable, so ties keep the group's order.
    readonly property var alerts: entries.filter(entry => entry.severity > 0).sort((left, right) => right.severity - left.severity)
    readonly property int severity: alerts.length > 0 ? alerts[0].severity : 0
    readonly property bool measured: entries.some(entry => entry.severity >= 0)
    readonly property var segments: entries.map(entry => tone(entry.severity))

    // Bar chrome follows the chrome text, which scales with the terminal font; 12 px is its default.
    readonly property real barScale: ratio * (typography.small ?? 12) / 12
    readonly property real pillHeight: Math.min(rowHeight, 22 * barScale)
    readonly property real leading: 3 * barScale
    readonly property real trailing: 9 * barScale
    readonly property real partGap: 6 * barScale
    readonly property real chromeWidth: implicitWidth
    readonly property real unreducedWidth: implicitWidth
    readonly property var fitNodes: []

    implicitWidth: leading + ring.width + partGap + label.implicitWidth + (extra.visible ? partGap + extra.implicitWidth : 0) + trailing
    implicitHeight: rowHeight

    function tone(severity) {
        return severity === 2 ? colors.red : severity === 1 ? colors.yellow : severity === 0 ? colors.overlay1 : colors.surface1;
    }

    onSeverityChanged: if (severity === 2) pulse.restart()

    BarPill {
        y: Math.round((root.height - height) / 2)
        width: root.width
        height: root.pillHeight
        colors: root.colors
        severity: root.severity
        ratio: root.ratio
    }

    BarRing {
        id: ring
        objectName: "systemSummaryRing"
        x: root.leading
        y: Math.round((root.height - height) / 2)
        width: implicitWidth
        height: implicitHeight
        side: 16 * root.barScale
        segments: root.segments
        ratio: root.ratio

        // One beat when the summary turns to danger; nothing moves while it stays there.
        SequentialAnimation on opacity {
            id: pulse
            running: false
            NumberAnimation { to: 0.35; duration: 300; easing.type: Easing.OutQuad }
            NumberAnimation { to: 1; duration: 300; easing.type: Easing.InQuad }
        }
    }

    ChromeText {
        id: label
        objectName: "systemSummaryLabel"
        x: ring.x + ring.width + root.partGap
        width: implicitWidth
        height: root.height
        text: root.alerts.length > 0 ? root.alerts[0].name + " " + root.alerts[0].value : root.node.text
        color: root.severity > 0 ? root.tone(root.severity) : root.colors.subtext0
        pixelSize: root.typography.small
        elide: Text.ElideNone
    }

    ChromeText {
        id: extra
        objectName: "systemSummaryExtra"
        x: label.x + label.width + root.partGap
        width: implicitWidth
        height: root.height
        text: "+" + (root.alerts.length - 1)
        color: root.colors.overlay1
        pixelSize: root.typography.small
        elide: Text.ElideNone
        visible: root.alerts.length > 1
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        enabled: !root.node.clickable
        onTapped: root.pinned = !root.pinned
    }

    Accessible.role: Accessible.Button
    Accessible.name: label.text + (extra.visible ? " " + extra.text : "")
    Accessible.onPressAction: if (!root.node.clickable) root.pinned = !root.pinned

    Popup {
        id: breakdown
        objectName: "systemSummaryBreakdown"
        parent: root
        visible: (hover.hovered || root.pinned) && root.entries.length > 0
        y: -height - root.partGap
        width: 240 * root.barScale
        padding: 12 * root.ratio
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        onClosed: root.pinned = false
        background: DialogSurface { colors: root.colors; ratio: root.ratio }
        contentItem: Column {
            spacing: 6 * root.ratio

            ChromeText {
                width: parent.width
                height: 18 * root.ratio
                text: root.node.text
                color: root.colors.text
                emphasized: true
                pixelSize: root.typography.small
            }

            ChromeText {
                width: parent.width
                height: 18 * root.ratio
                text: "No samples yet"
                color: root.colors.subtext0
                pixelSize: root.typography.small
                visible: !root.measured
            }

            Repeater {
                model: root.measured ? root.alerts.concat(root.entries.filter(entry => entry.severity <= 0)) : []

                delegate: Item {
                    id: row
                    required property var modelData
                    objectName: "systemSummaryRow"
                    width: parent.width
                    height: 20 * root.barScale

                    BarRing {
                        anchors.verticalCenter: parent.verticalCenter
                        width: implicitWidth
                        height: implicitHeight
                        segments: [row.modelData.severity > 0 ? root.tone(row.modelData.severity) : root.colors.subtext0]
                        fraction: row.modelData.severity < 0 ? 0 : Math.max(0, Math.min(1, row.modelData.fraction))
                        trackColor: root.colors.surface1
                        side: 16 * root.barScale
                        ratio: root.ratio
                    }

                    ChromeText {
                        x: 24 * root.barScale
                        width: Math.max(0, parent.width - x - value.width)
                        height: parent.height
                        text: row.modelData.name
                        color: root.colors.subtext0
                        pixelSize: root.typography.small
                    }

                    ChromeText {
                        id: value
                        x: parent.width - width
                        width: implicitWidth
                        height: parent.height
                        text: row.modelData.severity < 0 ? "—" : row.modelData.value
                        color: row.modelData.severity > 0 ? root.tone(row.modelData.severity) : root.colors.text
                        pixelSize: root.typography.small
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideNone
                    }
                }
            }
        }
    }
}
