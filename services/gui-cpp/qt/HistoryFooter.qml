pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

HistoryFooterLayout {
    id: root
    objectName: "historyFooter"

    required property var state
    required property var colors
    required property real pixelSize
    property real ratio: 1
    property var actionController: null
    property bool interactive: state.phase === "ready" && state.count > 0
    readonly property var regions: layout
    signal actionTriggered(string action, string revision)

    clip: true
    input: ({state: root.state, ratio: root.ratio, smallPixels: root.pixelSize})

    function measure() {
        const hints = [];
        for (let index = 0; index < controls.count; ++index) {
            const item = controls.itemAt(index);
            hints.push({key: item ? item.keyAdvance : 0, word: item ? item.wordAdvance : 0});
        }

        root.measurements = {hints: hints, range: rangeLabel.implicitWidth};
    }

    function scheduleMeasurement() {
        Qt.callLater(root.measure);
    }

    Rectangle {
        x: root.regions.separator.x
        y: root.regions.separator.y
        width: root.regions.separator.width
        height: root.regions.separator.height
        color: root.colors.surface1
    }

    Repeater {
        id: controls
        model: root.hints.length
        delegate: HistoryHint {
            required property int index
            label: root.hints[index] ?? {key: "", word: "", action: "none"}
            geometry: root.regions.hints[index]
            usePresentedHover: root.actionController !== null
            presentedHover: root.actionController ? root.actionController.historyHoveredFooterAction === label.action && ((label.action !== "submit" && label.action !== "alternate") || (root.actionController.historyHoveredFooterIndex === root.state.selection && root.actionController.historyHoveredFooterRevision === root.state.revision)) : false
            style: root.regions
            x: geometry.bounds.x
            y: geometry.bounds.y
            width: geometry.bounds.width
            height: geometry.bounds.height
            colors: root.colors
            pixelSize: root.pixelSize
            visible: index < root.regions.hintCount
            enabled: root.interactive && visible
            actionable: label.action !== "none"
            activationIdentity: label.action === "submit" || label.action === "alternate" ? (root.state.revision ?? "") + ":" + root.state.selection + ":" + root.state.enterRuns + ":" + label.action : label.action
            onMeasurementsChanged: root.scheduleMeasurement()
            onActivated: root.actionTriggered(label.action, root.state.revision ?? "")
        }
        onItemAdded: root.scheduleMeasurement()
        onItemRemoved: root.scheduleMeasurement()
    }

    ChromeText {
        id: rangeLabel
        objectName: "historyRange"
        x: root.regions.range.x
        y: root.regions.range.y
        width: root.regions.range.width
        height: root.regions.range.height
        text: root.range
        color: root.colors.subtext0
        pixelSize: root.pixelSize
        elide: Text.ElideNone
        visible: root.regions.showRange
        onImplicitWidthChanged: root.scheduleMeasurement()
    }

    ChromeText {
        objectName: "historyFooterError"
        x: root.regions.error.x
        y: root.regions.error.y
        width: root.regions.error.width
        height: root.regions.error.height
        text: root.state.error ?? ""
        color: root.colors.red
        pixelSize: root.pixelSize
        elide: Text.ElideNone
        visible: root.regions.showError
    }

    Component.onCompleted: {
        root.scheduleMeasurement();
        if (root.actionController) {
            root.actionController.registerHistoryFooter(root);
        }
    }
}
