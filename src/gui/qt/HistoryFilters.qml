pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

HistoryFiltersLayout {
    id: root
    objectName: "historyFilters"

    required property var state
    required property var colors
    required property real pixelSize
    required property var grid
    property var actionController: null
    property real ratio: 1
    property real density: 1
    readonly property var regions: layout
    signal scopeSelected(string scope)
    signal authorSelected(string author)
    signal failedToggled()

    clip: true
    input: ({scope: state.effectiveScope, scopeValue: state.scopeValue ?? "", author: state.author,
             failedOnly: state.failedOnly, macStyle: state.macStyle ?? false, ratio: root.ratio})

    function measure() {
        const scopeWidths = [];
        for (let index = 0; index < scopes.count; ++index) {
            const item = scopes.itemAt(index);
            scopeWidths.push({label: item ? item.labelAdvance : 0, value: item ? item.valueAdvance : 0});
        }

        const authorWidths = [];
        for (let index = 0; index < authors.count; ++index) {
            authorWidths.push(authors.itemAt(index)?.labelAdvance ?? 0);
        }

        const keyWidths = [];
        for (let index = 0; index < keys.count; ++index) {
            keyWidths.push(keys.itemAt(index)?.implicitWidth ?? 0);
        }

        root.measurements = {scopes: scopeWidths, authors: authorWidths, keys: keyWidths, failed: failed.labelAdvance};
    }

    function scheduleMeasurement() {
        Qt.callLater(root.measure);
    }

    NativeRoundedRectangle {
        objectName: "historyScope"
        x: root.regions.scopeGroup.x
        y: root.regions.scopeGroup.y
        width: root.regions.scopeGroup.width
        height: root.regions.scopeGroup.height
        radius: root.regions.groupRadius
        color: root.colors.surface0
        visible: root.regions.visible
    }

    Repeater {
        id: scopes
        model: root.scopeChoices.length
        delegate: HistoryFilterChip {
            objectName: "historyFilterChip"
            required property int index
            readonly property var modelData: root.scopeChoices[index]
            geometry: root.regions.scopes[index]
            style: root.regions
            x: geometry.bounds.x
            y: geometry.bounds.y
            width: geometry.bounds.width
            height: geometry.bounds.height
            text: modelData.text
            valueText: modelData.detail
            selected: modelData.selected
            activationIdentity: modelData.value
            usePresentedHover: root.actionController !== null
            presentedHover: root.actionController ? root.actionController.historyHoveredFilterAction === modelData.value : false
            colors: root.colors
            pixelSize: root.pixelSize
            visible: root.regions.visible
            onMeasurementsChanged: root.scheduleMeasurement()
            onActivated: root.scopeSelected(modelData.value)
        }
        onItemAdded: root.scheduleMeasurement()
        onItemRemoved: root.scheduleMeasurement()
    }

    NativeRoundedRectangle {
        objectName: "historyAuthor"
        x: root.regions.authorGroup.x
        y: root.regions.authorGroup.y
        width: root.regions.authorGroup.width
        height: root.regions.authorGroup.height
        radius: root.regions.groupRadius
        color: root.colors.surface0
        visible: root.regions.showRight
    }

    Repeater {
        id: authors
        model: root.authorChoices.length
        delegate: HistoryFilterChip {
            objectName: "historyFilterChip"
            required property int index
            readonly property var modelData: root.authorChoices[index]
            geometry: root.regions.authors[index]
            style: root.regions
            x: geometry.bounds.x
            y: geometry.bounds.y
            width: geometry.bounds.width
            height: geometry.bounds.height
            text: modelData.text
            selected: modelData.selected
            activationIdentity: modelData.value
            usePresentedHover: root.actionController !== null
            presentedHover: root.actionController ? root.actionController.historyHoveredFilterAction === modelData.value : false
            colors: root.colors
            pixelSize: root.pixelSize
            visible: root.regions.showRight
            onMeasurementsChanged: root.scheduleMeasurement()
            onActivated: root.authorSelected(modelData.value)
        }
        onItemAdded: root.scheduleMeasurement()
        onItemRemoved: root.scheduleMeasurement()
    }

    HistoryFilterChip {
        id: failed
        objectName: "historyFailedOnly"
        text: "Failed"
        geometry: root.regions.failed
        style: root.regions
        x: geometry.bounds.x
        y: geometry.bounds.y
        width: geometry.bounds.width
        height: geometry.bounds.height
        colors: root.colors
        pixelSize: root.pixelSize
        selected: root.state.failedOnly
        danger: true
        usePresentedHover: root.actionController !== null
        presentedHover: root.actionController ? root.actionController.historyHoveredFilterAction === "failed" : false
        visible: root.regions.showRight
        onMeasurementsChanged: root.scheduleMeasurement()
        onActivated: root.failedToggled()
    }

    Repeater {
        id: keys
        model: root.keyLabels.length
        delegate: CellText {
            objectName: "historyFilterKey"
            required property int index
            readonly property rect bounds: root.regions.keys[index]
            x: bounds.x
            y: bounds.y
            width: bounds.width
            height: bounds.height
            text: root.keyLabels[index]
            grid: root.grid
            color: root.colors.overlay1
            visible: root.regions.showKeys
            onImplicitWidthChanged: root.scheduleMeasurement()
        }
        onItemAdded: root.scheduleMeasurement()
        onItemRemoved: root.scheduleMeasurement()
    }

    Rectangle {
        x: root.regions.separator.x
        y: root.regions.separator.y
        width: root.regions.separator.width
        height: root.regions.separator.height
        color: root.colors.surface1
        visible: root.regions.visible
    }

    Component.onCompleted: {
        root.scheduleMeasurement();
        if (root.actionController) {
            root.actionController.registerHistoryFilters(root);
        }
    }
}
