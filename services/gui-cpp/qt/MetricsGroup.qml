pragma ComponentBehavior: Bound

import QtQuick
import "ComponentFit.js" as ComponentFit

Item {
    id: root

    required property var metrics
    required property var colors
    required property var typography
    property real ratio: 1
    property var nodes: []
    property var fittedLevels: ({})

    readonly property real chromeWidth: groupPadding
    readonly property real leadingGap: childGap
    readonly property var metricWidths: [cpu.implicitWidth, memory.implicitWidth, battery.implicitWidth]
    readonly property var fitNodes: nodes.filter(node => node.kind === "metric").map(node => ({
        index: node.index, parent: node.parent, priority: node.priority,
        group: false, meter: false, compactDelta: 0, width: metricWidths[node.metric],
    }))
    readonly property real unreducedWidth: chromeWidth + fitNodes.reduce((total, node) => total + (node.width > 0 ? childGap + node.width : 0), 0)
    readonly property real fittedWidth: chromeWidth + fitNodes.reduce((total, node) => total + (node.width > 0 && (fittedLevels[node.index] ?? ComponentFit.Level.full) !== ComponentFit.Level.hidden ? childGap + node.width : 0), 0)

    function metricVisible(metric) {
        const node = nodes.find(node => node.kind === "metric" && node.metric === metric);
        return node !== undefined && (fittedLevels[node.index] ?? ComponentFit.Level.full) !== ComponentFit.Level.hidden;
    }

    readonly property real groupPadding: 6 * ratio
    readonly property real childGap: 6 * ratio
    readonly property real cpuWidth: cpu.implicitWidth
    readonly property real memoryEnd: cpuWidth + (cpuWidth > 0 && memory.implicitWidth > 0 ? childGap : 0) + memory.implicitWidth
    readonly property real batteryEnd: memoryEnd + (memoryEnd > 0 && battery.implicitWidth > 0 ? childGap : 0) + battery.implicitWidth
    readonly property real availableWidth: Math.max(0, width - 2 * groupPadding)

    implicitWidth: nodes.length > 0 ? fittedWidth : batteryEnd + 2 * groupPadding

    Row {
        x: root.groupPadding
        height: parent.height
        spacing: root.childGap

        BarMetric {
            id: cpu
            objectName: "cpuMetric"

            width: implicitWidth
            height: parent.height
            record: root.metrics.cpu
            samples: root.metrics.history
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            visible: record.available && (root.nodes.length > 0 ? root.metricVisible(0) : root.cpuWidth <= root.availableWidth)
        }

        BarMetric {
            id: memory
            objectName: "memoryMetric"

            width: implicitWidth
            height: parent.height
            record: root.metrics.memory
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            visible: record.available && (root.nodes.length > 0 ? root.metricVisible(1) : root.memoryEnd <= root.availableWidth)
        }

        BarMetric {
            id: battery
            objectName: "batteryMetric"

            width: implicitWidth
            height: parent.height
            record: root.metrics.battery
            battery: true
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            visible: record.available && (root.nodes.length > 0 ? root.metricVisible(2) : root.batteryEnd <= root.availableWidth)
        }
    }
}
