pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

HistoryMetaLayout {
    id: root
    objectName: "historyRowDetails"

    required property var record
    required property var colors
    required property real pixelSize
    property real ratio: 1
    property bool selected: true
    property bool paneOpen: false
    property bool interactive: true
    property bool commandLoaded: true
    property bool showDirectory: true
    property bool macStyle: false
    property int more: 0
    readonly property var regions: layout
    readonly property string text: {
        const labels = [];
        const count = Math.min(root.regions.factCount, root.facts.length);
        for (let index = 0; index < count; ++index) {
            labels.push(root.facts[index].text);
        }

        return labels.join(" ");
    }
    signal actionTriggered(string action)

    input: ({
        record: root.record,
        ratio: root.ratio,
        smallPixels: root.pixelSize,
        selected: root.selected,
        paneOpen: root.paneOpen,
        loaded: root.commandLoaded,
        showDirectory: root.showDirectory,
        macStyle: root.macStyle,
        more: root.more
    })

    function measure() {
        const facts = [];
        const actions = [];
        for (let index = 0; index < factLabels.count; ++index) {
            const item = factLabels.itemAt(index);
            facts.push(item ? item.implicitWidth : 0);
        }

        for (let index = 0; index < actionHints.count; ++index) {
            const item = actionHints.itemAt(index);
            actions.push({key: item ? item.keyAdvance : 0, word: item ? item.wordAdvance : 0});
        }

        root.measurements = {facts: facts, actions: actions};
    }

    function scheduleMeasurement() {
        Qt.callLater(root.measure);
    }

    Repeater {
        id: factLabels
        model: root.facts.length
        delegate: ChromeText {
            objectName: "historyMetaLabel"
            required property int index
            readonly property var label: root.facts[index] ?? {text: "", color: "subtext0"}
            readonly property var bounds: root.regions.facts[index]
            x: bounds.x
            y: bounds.y
            width: bounds.width
            height: bounds.height
            text: label.text
            color: root.colors[label.color]
            pixelSize: root.pixelSize
            elide: Text.ElideNone
            visible: index < root.regions.factCount
            onImplicitWidthChanged: root.scheduleMeasurement()
        }
        onItemAdded: root.scheduleMeasurement()
        onItemRemoved: root.scheduleMeasurement()
    }

    Repeater {
        id: actionHints
        model: root.actions.length
        delegate: HistoryHint {
            required property int index
            geometry: root.regions.actions[index]
            label: root.actions[index]
            style: root.regions
            x: geometry.bounds.x
            y: geometry.bounds.y
            width: geometry.bounds.width
            height: geometry.bounds.height
            colors: root.colors
            pixelSize: root.pixelSize
            visible: index < root.regions.actionCount
            enabled: root.interactive && visible
            onMeasurementsChanged: root.scheduleMeasurement()
            onActivated: root.actionTriggered(label.action)
        }
        onItemAdded: root.scheduleMeasurement()
        onItemRemoved: root.scheduleMeasurement()
    }

    Component.onCompleted: root.scheduleMeasurement()
}
