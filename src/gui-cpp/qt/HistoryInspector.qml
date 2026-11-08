pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

HistoryInspectionLayout {
    id: root
    objectName: "historyInspector"

    required property var details
    required property var browserState
    required property var colors
    required property var typography
    required property string command
    required property string output
    property var actionController: null
    property real ratio: 1
    property real density: 1
    property bool interactive: root.browserState.phase === "ready" && root.browserState.count > 0
    property bool split: false
    property real reveal: 1
    readonly property int pageLines: 10
    readonly property var regions: layout
    readonly property var actions: {
        const result = [
            {text: root.browserState.enterRuns ? "Run" : "Paste", action: "submit", primary: true},
            {text: root.browserState.enterRuns ? "Paste" : "Run", action: "alternate", primary: false},
            {text: "Copy", action: "copy", primary: false},
            {text: "Delete", action: "erase", primary: false}
        ];
        if (root.browserState.paneOpen && root.browserState.phase === "ready") {
            result.push({text: "Go to pane", action: "visit", primary: false});
        }

        return result;
    }
    signal actionTriggered(string action, string revision)

    clip: true
    input: ({
        identity: root.details.identity ?? "",
        selection: root.browserState.selection,
        revision: root.browserState.revision,
        paneOpen: root.browserState.paneOpen ?? false,
        ready: root.browserState.phase === "ready",
        facts: root.details.facts ?? [],
        heading: root.details.heading ?? "",
        command: root.command,
        output: root.output,
        ratio: root.ratio,
        interactive: root.interactive,
        cellWidth: root.typography.grid.cellWidth,
        cellHeight: root.typography.grid.cellHeight,
        bodyPixels: root.typography.body,
        smallPixels: root.typography.small
    })

    function page(older) {
        root.scroll += root.pageLines * (older ? -1 : 1);
    }

    function measureActions() {
        const widths = [];
        for (let index = 0; index < buttons.count; ++index) {
            const button = buttons.itemAt(index) as FormButton;
            widths.push(button?.textAdvance ?? 0);
        }

        root.advances = widths;
    }

    function scheduleMeasurement() {
        Qt.callLater(root.measureActions);
    }

    Rectangle {
        width: 1 / root.density
        height: root.height
        color: root.colors.surface1
        visible: root.split
    }

    Item {
        objectName: "historyCommand"
        opacity: root.reveal
        readonly property string text: root.command
        anchors.fill: parent
        clip: true

        Repeater {
            model: root.regions.lines ?? []
            delegate: Item {
                id: line
                required property var modelData
                readonly property bool isCommand: modelData.command
                readonly property bool isFact: modelData.fact
                readonly property bool isHeading: modelData.heading
                x: modelData.bounds.x
                y: modelData.bounds.y
                width: modelData.bounds.width
                height: modelData.bounds.height
                clip: true

                Rectangle {
                    anchors.fill: parent
                    color: root.colors.surface0
                    visible: line.isCommand
                }

                ChromeText {
                    width: line.modelData.labelWidth
                    height: parent.height
                    visible: line.isFact
                    text: line.modelData.label
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                }

                CellText {
                    x: line.modelData.textBounds.x - line.modelData.bounds.x
                    width: line.modelData.textBounds.width
                    height: parent.height
                    visible: line.modelData.mono
                    text: line.modelData.text
                    color: root.colors[line.modelData.color]
                    grid: root.typography.grid
                }

                ChromeText {
                    x: line.modelData.textBounds.x - line.modelData.bounds.x
                    width: line.modelData.textBounds.width
                    height: parent.height
                    visible: !line.modelData.mono
                    text: line.modelData.text
                    color: root.colors[line.modelData.color]
                    pixelSize: line.isHeading ? root.typography.small : root.typography.body
                    emphasized: line.isHeading
                    elide: Text.ElideNone
                }
            }
        }
    }

    Item {
        objectName: "historyOutput"
        readonly property string text: root.output
    }

    Repeater {
        id: buttons
        model: root.actions.length
        delegate: FormButton {
            required property int index
            readonly property var action: root.actions[index] ?? null
            readonly property rect bounds: root.regions.buttons?.[index] ?? Qt.rect(0, 0, 0, 0)
            objectName: "historyInspectionAction"
            opacity: root.reveal
            x: bounds.x
            y: bounds.y
            width: bounds.width
            height: bounds.height
            visible: action !== null && width > 0 && height > 0
            text: action?.text ?? ""
            primary: action?.primary ?? false
            colors: root.colors
            pixelSize: root.typography.body
            radius: root.regions.buttonRadius ?? 0
            disabledAlpha: root.regions.disabledAlpha ?? 1
            pressedAlpha: root.regions.pressedAlpha ?? 1
            labelColor: action?.action === "erase" ? root.colors.red : root.colors.text
            interactive: root.interactive && action !== null
            usePresentedHover: root.actionController !== null
            presentedHover: root.actionController ? root.actionController.historyHoveredInspectionAction === (action?.action ?? "") && ((action?.action !== "submit" && action?.action !== "alternate") || (root.actionController.historyHoveredInspectionIndex === root.browserState.selection && root.actionController.historyHoveredInspectionRevision === root.browserState.revision)) : false
            identity: action?.action === "submit" || action?.action === "alternate" ? root.browserState.revision + ":" + root.browserState.selection + ":" + action.action : (action?.action ?? "")
            onTextAdvanceChanged: root.scheduleMeasurement()
            onActivated: {
                if (action !== null) {
                    root.actionTriggered(action.action, root.browserState.revision);
                }
            }
        }
        onItemAdded: root.scheduleMeasurement()
        onItemRemoved: root.scheduleMeasurement()
    }

    Component.onCompleted: {
        root.scheduleMeasurement();
        if (root.actionController) {
            root.actionController.registerHistoryInspector(root);
        }
    }
}
