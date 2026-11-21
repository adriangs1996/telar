pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick
import QtQuick.Controls.Basic

// The monitor over the window, as btop draws it: the processors, memory, disks and network of the
// active machine, then every process with what it is to telar, and the actions on the selected
// one. The process table is set in the terminal's font; the controller gives every cell its text.
FocusScope {
    id: root

    required property MonitorController controller
    required property var colors
    required property var typography
    property real ratio: 1
    // Where the window's top bar ends: the monitor starts below it, clear of the window's buttons.
    property real topInset: 0

    readonly property var header: controller.header
    readonly property var panels: controller.panels
    readonly property var view: controller.view
    readonly property var detail: controller.detail
    readonly property var footer: controller.footer
    readonly property var grid: typography.grid ?? ({})
    readonly property real cell: grid.cellWidth ?? 8
    readonly property real line: Math.ceil((grid.cellHeight ?? 16) * 1.2)
    readonly property real gap: 10 * ratio
    readonly property real inset: 16 * ratio
    readonly property real controlHeight: Math.round(typography.bodyRow ?? (typography.body * 1.8))
    readonly property real radius: ChromeStyle.surfaceRadius * ratio
    readonly property real hairline: 1 / Screen.devicePixelRatio
    readonly property bool hasDetail: (detail.pid ?? 0) > 0
    // An action that asks before it runs: TERM, KILL, and attaching a debugger.
    property string confirming: ""

    visible: telar.dialogs.kind === Store.Dialog.monitor
    z: 50
    onVisibleChanged: {
        confirming = "";
        if (visible)
            table.forceActiveFocus();
    }

    function toneColor(tone) {
        return tone === "hot" ? colors.red : tone === "warm" ? colors.yellow : colors.text;
    }

    function run(action) {
        confirming = "";
        if (action === "debug")
            controller.review("debug");
        else
            controller.signal(action);
    }

    function ask(action) {
        if (hasDetail)
            confirming = action;
    }

    function key(event) {
        const pressed = event.key;
        if (confirming !== "") {
            if (pressed === Qt.Key_Return || pressed === Qt.Key_Enter) {
                run(confirming);
                event.accepted = true;
                return;
            }
            if (pressed === Qt.Key_Escape) {
                confirming = "";
                event.accepted = true;
                return;
            }
        }

        const page = Math.max(1, Math.floor(table.height / line) - 1);
        const far = 1000000;
        const moves = {
            [Qt.Key_Up]: -1,
            [Qt.Key_Down]: 1,
            [Qt.Key_PageUp]: -page,
            [Qt.Key_PageDown]: page,
            [Qt.Key_Home]: -far,
            [Qt.Key_End]: far
        };
        event.accepted = true;
        if (moves[pressed] !== undefined) {
            controller.move(moves[pressed]);
        } else if (pressed === Qt.Key_Left || pressed === Qt.Key_Right) {
            controller.foldSelected(pressed === Qt.Key_Left);
        } else if (pressed === Qt.Key_Slash) {
            filter.forceActiveFocus();
        } else if (pressed === Qt.Key_Escape) {
            if (hasDetail)
                controller.clearSelection();
            else
                controller.close();
        } else if (event.text === "e") {
            controller.toggleTree();
        } else if (event.text === "s") {
            controller.cycleSort();
        } else if (event.text === "r") {
            controller.toggleReverse();
        } else if (event.text === "t") {
            ask("TERM");
        } else if (event.text === "k") {
            ask("KILL");
        } else if (event.text === "g" && (detail.pane ?? false)) {
            controller.focusPane();
        } else if (event.text === "c" && hasDetail) {
            controller.copyCommand();
        } else {
            event.accepted = false;
        }
    }

    Connections {
        target: root.controller

        function onFilterRequested() {
            filter.forceActiveFocus();
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.colors.background
        opacity: 0.55
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: mouse => mouse.accepted = true
        onWheel: wheel => wheel.accepted = true
    }

    DialogSurface {
        id: surface

        x: root.inset
        y: root.topInset + root.gap
        width: root.width - 2 * root.inset
        height: Math.max(0, root.height - y - root.inset)
        colors: root.colors
        ratio: root.ratio
    }

    Item {
        id: body

        x: surface.x + root.inset
        y: surface.y + root.gap
        width: surface.width - 2 * root.inset
        height: surface.height - 2 * root.gap

        // Title, the machine shown, and the others the window keeps.
        OverlayHeader {
            id: title

            width: body.width
            height: root.controlHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            title: "Monitor"
            note: root.header.note ?? ""

            Repeater {
                model: root.controller.machines.length > 1 ? root.controller.machines : []

                delegate: ChromeButton {
                    id: machine

                    required property var modelData

                    height: root.controlHeight
                    leftPadding: 8 * root.ratio
                    rightPadding: 8 * root.ratio
                    colors: root.colors
                    pixelSize: root.typography.small
                    checked: modelData.active
                    enabled: modelData.live || modelData.active
                    text: modelData.label + (modelData.status.length > 0 ? " · " + modelData.status : "")
                    emphasized: modelData.active
                    onClicked: root.controller.selectMachine(modelData.slot)
                    Accessible.name: "Show " + modelData.label + " in the monitor"
                }
            }
        }

        // The filter, which processes, and how they are laid out.
        Item {
            id: toolbar

            y: title.y + title.height + root.gap
            width: body.width
            height: root.controlHeight

            Rectangle {
                id: filterBox

                width: Math.min(40 * root.cell, toolbar.width / 3)
                height: toolbar.height
                radius: ChromeStyle.controlRadius * root.ratio
                color: root.colors.surface0
                border.width: root.hairline
                border.color: filter.activeFocus ? root.colors.accent : "transparent"

                FormTextField {
                    id: filter

                    x: 8 * root.ratio
                    width: filterBox.width - 16 * root.ratio
                    height: filterBox.height
                    colors: root.colors
                    typography: root.typography
                    ratio: root.ratio
                    placeholderPrefix: "/"
                    placeholderText: " filter by name, command, user or pid"
                    onTextEdited: root.controller.setFilter(text)
                    Keys.onDownPressed: table.forceActiveFocus()
                    Keys.onReturnPressed: table.forceActiveFocus()
                    Keys.onEnterPressed: table.forceActiveFocus()
                    Keys.onEscapePressed: {
                        if (!filter.cancelComposition())
                            table.forceActiveFocus();
                    }
                    Accessible.name: "Filter processes"
                }
            }

            Segmented {
                x: filterBox.width + root.gap
                options: [
                    {
                        key: "all",
                        label: "All",
                        count: root.view.all ?? 0
                    },
                    {
                        key: "telar",
                        label: "In telar",
                        count: root.view.telar ?? 0
                    },
                    {
                        key: "agents",
                        label: "Agents",
                        count: root.view.agents ?? 0
                    }
                ]
                current: root.view.scope ?? "all"
                onChosen: key => root.controller.setScope(key)
            }

            Segmented {
                x: toolbar.width - width
                options: [
                    {
                        key: "flat",
                        label: "List"
                    },
                    {
                        key: "tree",
                        label: "Tree"
                    },
                    {
                        key: "owner",
                        label: "By owner"
                    }
                ]
                current: root.view.layout ?? "flat"
                onChosen: key => root.controller.setLayout(key)
            }
        }

        // Processors, memory, disks and network.
        Row {
            id: gauges

            readonly property real share: (body.width - 3 * root.gap) / 4.35

            y: toolbar.y + toolbar.height + root.gap
            width: body.width
            height: Math.max(cpuPanel.implicitHeight, memoryPanel.implicitHeight, diskPanel.implicitHeight, networkPanel.implicitHeight)
            spacing: root.gap

            Panel {
                id: cpuPanel

                width: gauges.share * 1.35
                height: gauges.height
                title: "cpu"
                value: root.panels.cpu ?? ""

                // The newest share at the right edge, as the history fills from the right.
                Item {
                    width: cpuPanel.contentWidth
                    height: 2 * root.line

                    BarSparkline {
                        x: parent.width - width
                        width: implicitWidth
                        height: parent.height
                        samples: root.panels.history ?? []
                        maximumColumns: 60
                        columnGap: 1 * root.ratio
                        columnWidth: Math.max(1, (parent.width - (maximumColumns - 1) * columnGap) / maximumColumns)
                        chartHeight: height
                    color: Number(root.panels.cpu ? parseFloat(root.panels.cpu) : 0) > 85 ? root.colors.red : root.colors.green
                        trackColor: Qt.alpha(root.colors.text, 0.06)
                        ratio: root.ratio
                    }
                }

                Grid {
                    id: cores

                    columns: (root.panels.cores ?? []).length > 8 ? 4 : 2
                    columnSpacing: 2 * root.cell
                    width: cpuPanel.contentWidth

                    Repeater {
                        model: root.panels.cores ?? []

                        delegate: MeterRow {
                            required property var modelData

                            width: (cores.width - (cores.columns - 1) * cores.columnSpacing) / cores.columns
                            height: root.line
                            colors: root.colors
                            grid: root.grid
                            ratio: root.ratio
                            labelWidth: 3 * root.cell
                            valueWidth: 5 * root.cell
                            label: modelData.label
                            value: modelData.value
                            fraction: modelData.fraction
                            tone: modelData.tone
                        }
                    }
                }
            }

            Panel {
                id: memoryPanel

                width: gauges.share
                height: gauges.height
                title: "memory"
                value: root.panels.memoryTotal ?? ""

                Meters {
                    panel: memoryPanel
                    model: root.panels.memory ?? []
                }
            }

            Panel {
                id: diskPanel

                width: gauges.share
                height: gauges.height
                title: "disks"

                Meters {
                    panel: diskPanel
                    model: root.panels.disks ?? []
                }
            }

            Panel {
                id: networkPanel

                width: gauges.share
                height: gauges.height
                title: "network"

                Meters {
                    panel: networkPanel
                    model: root.panels.network ?? []
                }
            }
        }

        // The columns' titles; a click sorts by one, a second click reverses.
        Item {
            id: columnTitles

            y: gauges.y + gauges.height + root.gap
            width: table.width
            height: root.line

            Repeater {
                model: root.controller.columns

                delegate: Item {
                    id: titleCell

                    required property var modelData

                    x: modelData.x
                    width: modelData.width
                    height: columnTitles.height

                    CellText {
                        anchors.fill: parent
                        text: titleCell.modelData.title
                        grid: root.grid
                        color: titleCell.modelData.owner ? root.colors.yellow : titleCell.modelData.sorted ? root.colors.text : root.colors.subtext0
                        bold: titleCell.modelData.sorted
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: titleCell.modelData.sort.length > 0
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root.controller.setSort(titleCell.modelData.sort)
                    }
                }
            }

            Rectangle {
                y: parent.height - height
                width: parent.width
                height: root.hairline
                color: root.colors.surface1
            }
        }

        // The processes the table shows; the controller holds what is above and below them.
        Item {
            id: table

            readonly property real scrollbarWidth: 6 * root.ratio
            property real wheelRest: 0

            y: columnTitles.y + columnTitles.height + 2 * root.ratio
            width: body.width
            height: Math.max(root.line, (details.visible ? details.y : (confirmBar.visible ? confirmBar.y : footerBar.y)) - root.gap - y)
            clip: true
            focus: true
            activeFocusOnTab: true

            function measure() {
                root.controller.setTable(Qt.size(width - scrollbarWidth - root.gap, height), Qt.size(root.cell, root.line));
            }

            // Later, not inside the binding that resized the table: measuring changes what it binds to.
            onWidthChanged: Qt.callLater(measure)
            onHeightChanged: Qt.callLater(measure)
            Component.onCompleted: Qt.callLater(measure)
            Keys.onPressed: event => root.key(event)

            Connections {
                target: root

                function onCellChanged() {
                    Qt.callLater(table.measure);
                }

                function onLineChanged() {
                    Qt.callLater(table.measure);
                }
            }

            Repeater {
                model: root.controller.rows

                delegate: TableRow {}
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: wheel => {
                    const delta = wheel.pixelDelta.y !== 0 ? -wheel.pixelDelta.y / root.line : -wheel.angleDelta.y / 40;
                    table.wheelRest += delta;
                    const steps = Math.trunc(table.wheelRest);
                    if (steps !== 0) {
                        table.wheelRest -= steps;
                        root.controller.scroll(steps);
                    }
                    wheel.accepted = true;
                }
            }

            Rectangle {
                x: table.width - table.scrollbarWidth
                y: table.height * (root.footer.position ?? 0)
                width: table.scrollbarWidth
                height: Math.max(2 * root.line, table.height * (root.footer.size ?? 1))
                radius: width / 2
                color: Qt.alpha(root.colors.text, 0.18)
                visible: (root.footer.size ?? 1) < 1
            }
        }

        // The selected process: what it is, and what telar knows of it, with its actions.
        Row {
            id: details

            y: (confirmBar.visible ? confirmBar.y : footerBar.y) - root.gap - height
            width: body.width
            height: 6 * root.line
            spacing: root.gap
            visible: root.hasDetail

            Panel {
                width: (details.width - root.gap) / 2
                height: details.height
                title: root.detail.program ?? ""
                value: "pid " + (root.detail.pid ?? "") + " · " + (root.detail.state ?? "") + " · nice " + (root.detail.nice ?? 0)

                Facts {
                    rows: [["command", root.detail.arguments ?? ""], ["directory", root.detail.directory ?? ""], ["ports", root.detail.ports ?? ""], ["usage", root.detail.usage ?? ""]]
                }
            }

            Panel {
                id: telarPanel

                width: (details.width - root.gap) / 2
                height: details.height
                title: "in telar"

                Facts {
                    rows: [["owner", root.detail.owner ?? ""], ["parents", root.detail.lineage ?? ""], ["children", root.detail.children ?? ""]]
                }

                Row {
                    height: root.controlHeight
                    spacing: 6 * root.ratio

                    DetailButton {
                        id: reviewButton

                        text: "Review ▾"
                        onClicked: reviewMenu.open()

                        Popup {
                            id: reviewMenu

                            y: -height - 4 * root.ratio
                            padding: 4 * root.ratio

                            background: DialogSurface {
                                colors: root.colors
                                ratio: root.ratio
                            }

                            contentItem: Column {
                                spacing: 2 * root.ratio

                                Repeater {
                                    model: [["stack", "Stack"], ["files", "Open files"], ["logs", "Logs"], ["debug", "Debugger…"]]

                                    delegate: DetailButton {
                                        required property var modelData

                                        width: 14 * root.cell
                                        text: modelData[1]
                                        danger: modelData[0] === "debug"
                                        onClicked: {
                                            reviewMenu.close();
                                            if (modelData[0] === "debug")
                                                root.ask("debug");
                                            else
                                                root.controller.review(modelData[0]);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    DetailButton {
                        text: "Pane"
                        visible: root.detail.pane ?? false
                        onClicked: root.controller.focusPane()
                    }

                    DetailButton {
                        text: "Copy"
                        onClicked: root.controller.copyCommand()
                    }

                    Divider {}

                    DetailButton {
                        text: (root.detail.stopped ?? false) ? "Resume" : "Pause"
                        onClicked: root.controller.signal((root.detail.stopped ?? false) ? "CONT" : "STOP")
                    }

                    Row {
                        height: root.controlHeight

                        ChromeText {
                            width: implicitWidth + 6 * root.ratio
                            height: parent.height
                            text: "nice"
                            pixelSize: root.typography.small
                            color: root.colors.subtext0
                        }

                        DetailButton {
                            text: "−"
                            onClicked: root.controller.renice((root.detail.nice ?? 0) - 1)
                            Accessible.name: "Raise the process's priority"
                        }

                        CellText {
                            width: 3 * root.cell
                            height: parent.height
                            text: String(root.detail.nice ?? 0)
                            grid: root.grid
                            color: root.colors.text
                        }

                        DetailButton {
                            text: "+"
                            onClicked: root.controller.renice((root.detail.nice ?? 0) + 1)
                            Accessible.name: "Lower the process's priority"
                        }
                    }

                    Divider {}

                    DetailButton {
                        text: "TERM"
                        danger: true
                        onClicked: root.ask("TERM")
                    }

                    DetailButton {
                        text: "KILL"
                        danger: true
                        onClicked: root.ask("KILL")
                    }
                }
            }
        }

        // What an action that asks first is about to do.
        Rectangle {
            id: confirmBar

            y: footerBar.y - root.gap - height
            width: body.width
            height: root.controlHeight + 2 * 6 * root.ratio
            radius: root.radius
            color: Qt.alpha(root.colors.red, 0.12)
            border.width: root.hairline
            border.color: Qt.alpha(root.colors.red, 0.6)
            visible: root.confirming !== ""

            ChromeText {
                x: root.gap
                width: confirmActions.x - 2 * root.gap
                height: parent.height
                pixelSize: root.typography.small
                color: root.colors.text
                text: {
                    const target = (root.detail.program ?? "") + " (" + (root.detail.pid ?? "") + ")";
                    if (root.confirming === "debug")
                        return "Attaching a debugger stops " + target + " until you detach it.";
                    return "Send " + root.confirming + " to " + target + "? telar checks it is still the same process first.";
                }
            }

            Row {
                id: confirmActions

                x: confirmBar.width - width - root.gap
                y: (confirmBar.height - height) / 2
                spacing: 6 * root.ratio

                DetailButton {
                    text: root.confirming === "debug" ? "Attach debugger" : "Send " + root.confirming
                    danger: true
                    onClicked: root.run(root.confirming)
                }

                DetailButton {
                    text: "Cancel"
                    onClicked: root.confirming = ""
                }
            }
        }

        KeyHintBar {
            id: footerBar

            y: body.height - height
            width: body.width
            height: root.controlHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            hints: {
                const hints = [
                    {
                        keys: ["↑", "↓"],
                        word: "move"
                    },
                    {
                        keys: ["/"],
                        word: "filter"
                    },
                    {
                        keys: ["e"],
                        word: "tree"
                    },
                    {
                        keys: ["s"],
                        word: "sort"
                    },
                    {
                        keys: ["r"],
                        word: "reverse"
                    }
                ];
                if (root.view.layout === "tree")
                    hints.push({
                        keys: ["←", "→"],
                        word: "fold"
                    });
                if (root.detail.pane ?? false)
                    hints.push({
                        keys: ["g"],
                        word: "pane"
                    });
                hints.push({
                    keys: ["t"],
                    word: "TERM"
                }, {
                    keys: ["k"],
                    word: "KILL"
                }, {
                    keys: ["Esc"],
                    word: root.hasDetail ? "deselect" : "close"
                });
                return hints;
            }
            trailing: ({
                    keys: [],
                    word: root.controller.error.length > 0 ? root.controller.error : (root.footer.count ?? "")
                })
        }
    }

    // A group of buttons of which one is chosen, with an optional count after each label.
    component Segmented: Rectangle {
        id: segmented

        property var options: []
        property string current
        signal chosen(string key)

        width: segments.width + 2 * root.hairline
        height: root.controlHeight
        radius: ChromeStyle.controlRadius * root.ratio
        color: "transparent"
        border.width: root.hairline
        border.color: root.colors.surface1

        Row {
            id: segments

            x: root.hairline

            Repeater {
                model: segmented.options

                delegate: ChromeButton {
                    id: segment

                    required property var modelData

                    height: segmented.height
                    leftPadding: 10 * root.ratio
                    rightPadding: 10 * root.ratio
                    colors: root.colors
                    pixelSize: root.typography.small
                    checked: modelData.key === segmented.current
                    text: modelData.label
                    onClicked: segmented.chosen(modelData.key)
                    Accessible.name: modelData.label

                    contentItem: Row {
                        spacing: 5 * root.ratio

                        ChromeText {
                            height: segment.height
                            text: segment.modelData.label
                            pixelSize: root.typography.small
                            emphasized: segment.checked
                            color: segment.checked ? root.colors.text : root.colors.subtext0
                        }

                        ChromeText {
                            height: segment.height
                            text: segment.modelData.count === undefined ? "" : String(segment.modelData.count)
                            pixelSize: root.typography.small
                            color: root.colors.overlay1
                            visible: text.length > 0
                        }
                    }
                }
            }
        }
    }

    // A box of the monitor: a title, a value at its right, and what it holds below.
    component Panel: Rectangle {
        id: panel

        property string title
        property string value
        default property alias content: contents.data
        readonly property real padding: 10 * root.ratio
        readonly property real contentWidth: width - 2 * padding

        implicitHeight: contents.y + contents.implicitHeight + padding
        radius: root.radius
        color: root.colors.surface0

        ChromeText {
            x: panel.padding
            y: panel.padding / 2
            width: panel.contentWidth - valueText.width
            height: root.controlHeight
            text: panel.title
            pixelSize: root.typography.small
            emphasized: true
            color: root.colors.accent
        }

        CellText {
            id: valueText

            x: panel.width - panel.padding - width
            y: panel.padding / 2
            width: implicitWidth
            height: root.controlHeight
            text: panel.value
            grid: root.grid
            color: root.colors.text
        }

        Column {
            id: contents

            x: panel.padding
            y: panel.padding / 2 + root.controlHeight
            width: panel.contentWidth
            spacing: 2 * root.ratio
        }
    }

    // The measures of a panel, one per row; the labels and values take the cells their longest needs,
    // and the bars the rest.
    component Meters: Column {
        id: meters

        required property Item panel
        property var model: []
        readonly property int labelCells: Math.max(1, ...model.map(entry => entry.label.length))
        readonly property int valueCells: Math.max(1, ...model.map(entry => entry.value.length))

        width: panel.contentWidth
        spacing: 2 * root.ratio

        Repeater {
            model: meters.model

            delegate: MeterRow {
                required property var modelData

                width: meters.width
                height: root.line
                colors: root.colors
                grid: root.grid
                ratio: root.ratio
                labelWidth: meters.labelCells * root.cell
                valueWidth: meters.valueCells * root.cell
                label: modelData.label
                value: modelData.value
                fraction: modelData.fraction
                tone: modelData.tone
            }
        }
    }

    // Name and value pairs of a detail.
    component Facts: Column {
        id: facts

        property var rows: []

        width: parent ? parent.width : 0

        Repeater {
            model: facts.rows

            delegate: Item {
                id: fact

                required property var modelData

                width: facts.width
                height: root.line

                ChromeText {
                    width: 10 * root.cell
                    height: parent.height
                    text: fact.modelData[0]
                    pixelSize: root.typography.small
                    color: root.colors.subtext0
                }

                CellText {
                    x: 10 * root.cell
                    width: parent.width - x
                    height: parent.height
                    text: fact.modelData[1]
                    grid: root.grid
                    color: root.colors.text
                    clip: true
                }
            }
        }
    }

    // A button of the detail; a dangerous one reads in red.
    component DetailButton: ChromeButton {
        id: action

        property bool danger: false

        height: root.controlHeight
        leftPadding: 9 * root.ratio
        rightPadding: 9 * root.ratio
        colors: root.colors
        pixelSize: root.typography.small

        contentItem: ChromeText {
            text: action.text
            pixelSize: action.pixelSize
            color: action.danger ? root.colors.red : root.colors.text
            horizontalAlignment: Text.AlignHCenter
            wholePixelCentering: true
        }

        Rectangle {
            anchors.fill: parent
            radius: ChromeStyle.controlRadius * root.ratio
            color: "transparent"
            border.width: root.hairline
            border.color: action.danger ? Qt.alpha(root.colors.red, 0.5) : root.colors.surface1
        }
    }

    component Divider: Rectangle {
        width: root.hairline
        height: root.controlHeight * 0.7
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        color: root.colors.surface1
    }

    // A row of the table: a process, a group's title in an owner listing, or a row still on its way.
    component TableRow: Item {
        id: row

        required property var record
        required property int index
        readonly property bool process: record.kind === "process"
        readonly property bool group: record.kind === "group"
        readonly property var columns: root.controller.columns

        y: index * root.line
        width: table.width - table.scrollbarWidth - root.gap
        height: root.line
        // Until the controller hears the table shrank, a row past its end stays hidden, never half shown.
        visible: y + height <= table.height + 0.5

        Rectangle {
            anchors.fill: parent
            radius: 3 * root.ratio
            color: row.record.selected ? Qt.alpha(root.colors.accent, 0.2) : row.group ? root.colors.surface0 : pointer.containsMouse && row.process ? Qt.alpha(root.colors.text, ChromeStyle.hoverAlpha) : "transparent"
        }

        Rectangle {
            width: 2 * root.ratio
            height: parent.height
            color: root.colors.accent
            visible: row.record.selected ?? false
        }

        Repeater {
            model: row.process ? row.columns : []

            delegate: CellText {
                id: cellText

                required property var modelData
                required property int index

                x: modelData.x
                width: modelData.width
                height: row.height
                clip: true
                grid: root.grid
                text: (row.record.cells ?? [])[index] ?? ""
                color: {
                    if (index === 2 || index === 4)
                        return root.colors.subtext0;
                    if (index === 6)
                        return root.toneColor(row.record.cpuTone);
                    if (index === 7)
                        return row.record.owner === "none" ? root.colors.overlay1 : row.record.owner === "inherited" ? Qt.alpha(root.colors.yellow, 0.75) : root.colors.yellow;
                    return root.colors.text;
                }
            }
        }

        CellText {
            x: root.cell
            width: row.columns.length > 6 ? row.columns[5].x - x : 0
            height: row.height
            visible: row.group
            clip: true
            grid: root.grid
            bold: true
            text: row.group ? row.record.title + "  ·  " + row.record.count : ""
            color: row.record.title === "no owner in telar" ? root.colors.subtext0 : root.colors.yellow
        }

        CellText {
            x: row.columns.length > 6 ? row.columns[5].x : 0
            width: row.columns.length > 6 ? row.columns[5].width : 0
            height: row.height
            visible: row.group
            grid: root.grid
            text: row.group ? row.record.memory : ""
            color: root.colors.subtext0
        }

        CellText {
            x: row.columns.length > 6 ? row.columns[6].x : 0
            width: row.columns.length > 6 ? row.columns[6].width : 0
            height: row.height
            visible: row.group
            grid: root.grid
            text: row.group ? row.record.cpu : ""
            color: root.colors.subtext0
        }

        MouseArea {
            id: pointer

            anchors.fill: parent
            hoverEnabled: true
            enabled: row.process
            cursorShape: row.process ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
                root.controller.selectRow(row.index);
                table.forceActiveFocus();
            }
            onDoubleClicked: {
                if (row.record.foldable)
                    root.controller.toggleFold(row.record.pid);
            }
        }
    }
}
