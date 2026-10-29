pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    required property var metrics
    required property var colors
    required property var typography
    property real ratio: 1

    readonly property real groupPadding: 6 * ratio
    readonly property real childGap: 6 * ratio
    readonly property real cpuWidth: cpu.implicitWidth
    readonly property real memoryEnd: cpuWidth + (cpuWidth > 0 && memory.implicitWidth > 0 ? childGap : 0) + memory.implicitWidth
    readonly property real batteryEnd: memoryEnd + (memoryEnd > 0 && battery.implicitWidth > 0 ? childGap : 0) + battery.implicitWidth
    readonly property real availableWidth: Math.max(0, width - 2 * groupPadding)

    implicitWidth: batteryEnd + 2 * groupPadding

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
            visible: record.available && root.cpuWidth <= root.availableWidth
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
            visible: record.available && root.memoryEnd <= root.availableWidth
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
            visible: record.available && root.batteryEnd <= root.availableWidth
        }
    }
}
