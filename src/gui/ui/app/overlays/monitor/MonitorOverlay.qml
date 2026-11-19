pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick

// The monitor over the window, as btop draws it: the processors, memory, disks and network of the
// active machine, then every process, sortable and filterable, and the actions on the selected one.
FocusScope {
    id: root

    required property MonitorController controller
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var host: controller.host
    readonly property var view: controller.view
    readonly property var detail: controller.detail
    readonly property real gap: 8 * ratio
    readonly property real rowHeight: Math.round(typography.bodyRow ?? (typography.body * 1.6))
    readonly property real physicalPixel: 1 / Screen.devicePixelRatio
    // An action that asks before it runs: KILL, and attaching a debugger.
    property string confirming: ""

    visible: telar.dialogs.kind === Store.Dialog.monitor
    z: 50
    onVisibleChanged: {
        confirming = "";
        if (visible)
            table.forceActiveFocus();
    }

    function bytes(value) {
        const units = ["B", "K", "M", "G", "T"];
        let amount = value;
        let unit = 0;
        while (amount >= 1024 && unit + 1 < units.length) {
            amount /= 1024;
            unit += 1;
        }
        return unit === 0 ? amount.toFixed(0) + "B" : amount.toFixed(1) + units[unit];
    }

    function percent(value) {
        return value.toFixed(1) + "%";
    }

    function sortBy(column) {
        if (root.view.sort === column)
            root.controller.toggleReverse();
        else
            root.controller.setSort(column);
    }

    function act(name) {
        if (name === "KILL" || name === "debug") {
            if (root.confirming !== name) {
                root.confirming = name;
                return;
            }
        }
        root.confirming = "";
        if (name === "debug")
            root.controller.review("debug");
        else
            root.controller.signal(name);
    }

    Connections {
        target: root.controller

        function onFilterRequested() {
            filter.forceActiveFocus();
        }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            if (root.view.selected > 0)
                root.controller.clearSelection();
            else
                root.controller.close();
            event.accepted = true;
        } else if (event.key === Qt.Key_Slash) {
            filter.forceActiveFocus();
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.colors.background
        opacity: 0.6
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: mouse => mouse.accepted = true
        onWheel: wheel => wheel.accepted = true
    }

    Rectangle {
        id: panel
        anchors.fill: parent
        anchors.margins: 24 * root.ratio
        color: root.colors.panel_bg
        border.color: root.colors.surface1
        border.width: root.physicalPixel
        radius: 8 * root.ratio

        Column {
            anchors.fill: parent
            anchors.margins: root.gap * 1.5
            spacing: root.gap

            // Title, filter, scope, tree, close.
            Row {
                id: header
                width: parent.width
                height: root.rowHeight
                spacing: root.gap * 1.5

                ChromeText {
                    width: 90 * root.ratio
                    height: parent.height
                    text: "Monitor"
                    pixelSize: root.typography.body
                    emphasized: true
                    color: root.colors.accent
                }

                Rectangle {
                    width: 280 * root.ratio
                    height: parent.height
                    radius: 4 * root.ratio
                    color: root.colors.surface0
                    border.color: filter.activeFocus ? root.colors.accent : "transparent"
                    border.width: root.physicalPixel

                    TextInput {
                        id: filter
                        anchors.fill: parent
                        anchors.leftMargin: root.gap
                        anchors.rightMargin: root.gap
                        verticalAlignment: TextInput.AlignVCenter
                        color: root.colors.text
                        font.pixelSize: root.typography.body
                        clip: true
                        text: root.view.filter ?? ""
                        onTextEdited: root.controller.setFilter(text)
                        Keys.onEscapePressed: table.forceActiveFocus()
                        Keys.onDownPressed: table.forceActiveFocus()
                        Accessible.name: "Filter processes"

                        ChromeText {
                            anchors.fill: parent
                            text: "/ filter by name, command, user or pid"
                            pixelSize: root.typography.small
                            color: root.colors.overlay1
                            visible: filter.text.length === 0 && !filter.activeFocus
                        }
                    }
                }

                Repeater {
                    model: [["all", "All"], ["telar", "In panes"], ["agents", "Agents"]]

                    delegate: Chip {
                        required property var modelData
                        label: modelData[1]
                        active: root.view.scope === modelData[0]
                        onClicked: root.controller.setScope(modelData[0])
                    }
                }

                Chip {
                    label: "Tree"
                    active: root.view.tree ?? false
                    onClicked: root.controller.toggleTree()
                }

                ChromeText {
                    width: 260 * root.ratio
                    height: parent.height
                    text: (root.host.ready ?? false) ? root.host.processes + " processes · " + root.host.threads + " threads" : (root.controller.available ? "Reading the processes…" : "This machine's runtime has no monitor; update telar there")
                    pixelSize: root.typography.small
                    color: root.colors.subtext0
                }
            }

            // Processors, memory, disks and network.
            Row {
                id: gauges
                width: parent.width
                height: 150 * root.ratio
                spacing: root.gap

                Box {
                    width: (gauges.width - 3 * root.gap) * 0.34
                    height: gauges.height
                    title: "CPU " + root.percent(root.host.cpu ?? 0)

                    Flow {
                        anchors.fill: parent
                        anchors.topMargin: root.rowHeight
                        spacing: 4 * root.ratio

                        Repeater {
                            model: root.host.cores ?? []

                            delegate: Meter {
                                required property var modelData
                                required property int index
                                width: 64 * root.ratio
                                label: String(index)
                                fraction: modelData / 100
                                caption: modelData.toFixed(0) + "%"
                            }
                        }
                    }
                }

                Box {
                    width: (gauges.width - 3 * root.gap) * 0.22
                    height: gauges.height
                    title: "Memory"

                    Column {
                        anchors.fill: parent
                        anchors.topMargin: root.rowHeight
                        spacing: 4 * root.ratio

                        Meter {
                            width: parent.width
                            label: "Used"
                            fraction: (root.host.memoryUsed ?? 0) / Math.max(1, root.host.memoryTotal ?? 1)
                            caption: root.bytes(root.host.memoryUsed ?? 0) + " / " + root.bytes(root.host.memoryTotal ?? 0)
                        }

                        Meter {
                            width: parent.width
                            label: "Cached"
                            fraction: (root.host.memoryCached ?? 0) / Math.max(1, root.host.memoryTotal ?? 1)
                            caption: root.bytes(root.host.memoryCached ?? 0)
                        }

                        Meter {
                            width: parent.width
                            label: "Swap"
                            fraction: (root.host.swapUsed ?? 0) / Math.max(1, root.host.swapTotal ?? 1)
                            caption: root.bytes(root.host.swapUsed ?? 0) + " / " + root.bytes(root.host.swapTotal ?? 0)
                        }
                    }
                }

                Box {
                    width: (gauges.width - 3 * root.gap) * 0.22
                    height: gauges.height
                    title: "Disks  ↓" + root.bytes(root.host.diskRead ?? 0) + "/s ↑" + root.bytes(root.host.diskWritten ?? 0) + "/s"

                    Column {
                        anchors.fill: parent
                        anchors.topMargin: root.rowHeight
                        spacing: 4 * root.ratio

                        Repeater {
                            model: root.host.disks ?? []

                            delegate: Meter {
                                required property var modelData
                                width: parent.width
                                label: modelData.path
                                fraction: modelData.used / Math.max(1, modelData.total)
                                caption: root.bytes(modelData.available) + " free"
                            }
                        }
                    }
                }

                Box {
                    width: (gauges.width - 3 * root.gap) * 0.22
                    height: gauges.height
                    title: "Network"

                    Column {
                        anchors.fill: parent
                        anchors.topMargin: root.rowHeight
                        spacing: 2 * root.ratio

                        Repeater {
                            model: (root.host.interfaces ?? []).filter(item => item.received > 0 || item.sent > 0)

                            delegate: ChromeText {
                                required property var modelData
                                width: parent.width
                                height: root.typography.smallRow ?? root.rowHeight
                                text: modelData.name + "  ↓" + root.bytes(modelData.received) + "/s  ↑" + root.bytes(modelData.sent) + "/s"
                                pixelSize: root.typography.small
                                color: root.colors.text
                            }
                        }
                    }
                }
            }

            // The column titles; a click sorts by it, a second click reverses.
            Row {
                id: columns
                width: parent.width
                height: root.rowHeight
                spacing: 0

                Repeater {
                    model: [["pid", "PID", 0.07], ["", "USER", 0.10], ["cpu", "CPU%", 0.07], ["memory", "MEM", 0.08], ["threads", "THR", 0.05], ["", "S", 0.03], ["", "PANE", 0.05], ["name", "PROGRAM", 0.15], ["", "COMMAND", 0.40]]

                    delegate: Item {
                        id: column
                        required property var modelData
                        width: columns.width * modelData[2]
                        height: columns.height

                        ChromeText {
                            anchors.fill: parent
                            text: column.modelData[1] + (root.view.sort === column.modelData[0] && column.modelData[0] !== "" ? (root.view.reverse ? " ▲" : " ▼") : "")
                            pixelSize: root.typography.small
                            emphasized: root.view.sort === column.modelData[0]
                            color: root.view.sort === column.modelData[0] ? root.colors.accent : root.colors.subtext0
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: column.modelData[0] !== ""
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.sortBy(column.modelData[0])
                        }
                    }
                }
            }

            ListView {
                id: table
                width: parent.width
                height: parent.height - header.height - gauges.height - columns.height - details.height - 4 * root.gap
                clip: true
                model: root.controller.rows
                focus: true
                boundsBehavior: Flickable.StopAtBounds
                keyNavigationEnabled: true
                highlightMoveDuration: 0
                currentIndex: -1
                onCurrentIndexChanged: {
                    const item = currentItem as ProcessRow;
                    if (item !== null)
                        root.controller.select(item.record.pid, item.record.started);
                }
                Keys.onReturnPressed: details.forceActiveFocus()

                delegate: ProcessRow {}
            }

            Rectangle {
                id: details
                width: parent.width
                height: (root.detail.pid ?? 0) > 0 ? 4 * root.rowHeight : (root.controller.error.length > 0 ? root.rowHeight : 0)
                color: root.colors.surface0
                radius: 4 * root.ratio
                visible: height > 0

                Column {
                    anchors.fill: parent
                    anchors.margins: root.gap / 2
                    spacing: 0

                    ChromeText {
                        width: parent.width
                        height: root.rowHeight
                        visible: root.controller.error.length > 0
                        text: root.controller.error
                        pixelSize: root.typography.small
                        color: root.colors.red
                    }

                    ChromeText {
                        width: parent.width
                        height: root.rowHeight
                        visible: (root.detail.pid ?? 0) > 0
                        text: (root.detail.program ?? "") + "  ·  pid " + (root.detail.pid ?? "") + "  ·  " + (root.detail.user ?? "") + "  ·  " + (root.detail.state ?? "") + "  ·  nice " + (root.detail.nice ?? 0) + ((root.detail.pane ?? 0) > 0 ? "  ·  pane " + root.detail.pane : "") + ((root.detail.ports ?? "").length > 0 ? "  ·  ports " + root.detail.ports : "") + "  ·  " + (root.detail.directory ?? "")
                        pixelSize: root.typography.small
                        emphasized: true
                        color: root.colors.text
                    }

                    ChromeText {
                        width: parent.width
                        height: root.rowHeight
                        visible: (root.detail.pid ?? 0) > 0
                        text: root.detail.arguments ?? ""
                        pixelSize: root.typography.small
                        color: root.colors.subtext0
                    }

                    Row {
                        height: root.rowHeight
                        spacing: root.gap
                        visible: (root.detail.pid ?? 0) > 0

                        Chip {
                            label: "Pause"
                            onClicked: root.act("STOP")
                        }

                        Chip {
                            label: "Resume"
                            onClicked: root.act("CONT")
                        }

                        Chip {
                            label: "Terminate"
                            onClicked: root.act("TERM")
                        }

                        Chip {
                            label: root.confirming === "KILL" ? "Kill? click again" : "Kill"
                            danger: true
                            onClicked: root.act("KILL")
                        }

                        Chip {
                            label: "Nice +5"
                            onClicked: root.controller.renice((root.detail.nice ?? 0) + 5)
                        }

                        Chip {
                            label: "Copy command"
                            onClicked: root.controller.copyCommand()
                        }

                        Chip {
                            label: "Go to pane"
                            visible: (root.detail.pane ?? 0) > 0
                            onClicked: root.controller.focusPane()
                        }

                        Repeater {
                            model: [["stack", "Stack"], ["files", "Files"], ["logs", "Logs"]]

                            delegate: Chip {
                                required property var modelData
                                label: "Review " + modelData[1].toLowerCase()
                                onClicked: root.controller.review(modelData[0])
                            }
                        }

                        Chip {
                            label: root.confirming === "debug" ? "Debug stops it; click again" : "Debug"
                            danger: true
                            onClicked: root.act("debug")
                        }
                    }
                }
            }
        }
    }

    component Chip: Rectangle {
        id: chip
        property string label
        property bool active: false
        property bool danger: false
        signal clicked

        width: chipText.implicitWidth + 2 * root.gap
        height: root.rowHeight
        radius: 4 * root.ratio
        color: active ? Qt.alpha(root.colors.accent, 0.25) : chipMouse.containsMouse ? root.colors.surface1 : root.colors.surface0
        border.color: danger ? root.colors.red : active ? root.colors.accent : "transparent"
        border.width: root.physicalPixel

        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            color: chip.danger ? root.colors.red : root.colors.text
            font.pixelSize: root.typography.small
        }

        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }

        Accessible.role: Accessible.Button
        Accessible.name: label
    }

    component Box: Rectangle {
        id: box
        property string title
        color: root.colors.surface0
        radius: 4 * root.ratio
        clip: true

        ChromeText {
            x: root.gap
            width: parent.width - 2 * root.gap
            height: root.rowHeight
            text: box.title
            pixelSize: root.typography.small
            emphasized: true
            color: root.colors.accent
        }
    }

    component Meter: Item {
        id: meter
        property string label
        property real fraction: 0
        property string caption
        height: root.typography.smallRow ?? root.rowHeight

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: root.gap
            anchors.rightMargin: root.gap
            radius: 2 * root.ratio
            color: root.colors.surface1

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, meter.fraction))
                height: parent.height
                radius: parent.radius
                color: meter.fraction > 0.85 ? root.colors.red : meter.fraction > 0.6 ? root.colors.yellow : root.colors.green
                opacity: 0.55
            }
        }

        ChromeText {
            x: root.gap * 1.5
            width: parent.width - 3 * root.gap
            height: parent.height
            text: meter.label + "  " + meter.caption
            pixelSize: root.typography.small
            color: root.colors.text
        }
    }

    component ProcessRow: Rectangle {
        id: row
        required property var record
        required property int index
        readonly property bool current: record.pid === root.view.selected
        width: ListView.view.width
        height: root.rowHeight
        color: current ? Qt.alpha(root.colors.accent, 0.2) : index % 2 === 0 ? "transparent" : Qt.alpha(root.colors.surface0, 0.4)

        Row {
            anchors.fill: parent

            Repeater {
                model: [
                    [String(row.record.pid), 0.07],
                    [row.record.user, 0.10],
                    [row.record.measured ? row.record.cpu.toFixed(1) : "-", 0.07],
                    [row.record.measured ? root.bytes(row.record.memory) : "-", 0.08],
                    [row.record.measured ? String(row.record.threads) : "-", 0.05],
                    [row.record.state.substring(0, 1).toUpperCase(), 0.03],
                    [row.record.pane > 0 ? String(row.record.pane) : "-", 0.05],
                    ["  ".repeat(row.record.depth) + row.record.program, 0.15],
                    [row.record.command, 0.40]
                ]

                delegate: ChromeText {
                    required property var modelData
                    width: row.width * modelData[1]
                    height: row.height
                    text: modelData[0]
                    pixelSize: root.typography.small
                    color: row.record.agent ? root.colors.mauve : row.record.cpu >= 50 ? root.colors.peach : root.colors.text
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: {
                row.ListView.view.currentIndex = row.index;
                row.ListView.view.forceActiveFocus();
            }
        }
    }
}
