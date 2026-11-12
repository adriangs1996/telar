pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The bar's row while a mode holds the keyboard: the mode's badge, then the keys it answers,
// drawn as the history footer draws its hints.
NativeModeLayout {
    id: root

    required property var colors
    required property var typography

    pixelSize: typography.small
    clip: true

    function measure() {
        const hints = [];
        for (let index = 0; index < keys.count; ++index) {
            const item = keys.itemAt(index);
            hints.push({key: item ? item.keyAdvance : 0, word: item ? item.wordAdvance : 0});
        }

        root.measurements = {title: badge.implicitWidth, hints: hints};
    }

    function scheduleMeasurement() {
        Qt.callLater(root.measure);
    }

    BarBadge {
        id: badge
        objectName: "modeBadge"

        x: root.layout.title?.x ?? 0
        y: root.layout.title?.y ?? 0
        width: root.layout.title?.width ?? 0
        height: root.layout.title?.height ?? 0
        text: root.title
        ink: root.colors.accent
        pixelSize: root.typography.small
        ratio: root.ratio
        visible: root.title.length > 0 && width > 0
        onImplicitWidthChanged: root.scheduleMeasurement()
    }

    Repeater {
        id: keys
        model: root.hints.length
        delegate: HistoryHint {
            required property int index
            readonly property var placed: root.layout.hints?.[index] ?? null

            label: root.hints[index] ?? {key: "", word: ""}
            geometry: placed ?? {bounds: Qt.rect(0, 0, 0, 0), keycap: Qt.rect(0, 0, 0, 0), keyText: Qt.rect(0, 0, 0, 0), word: Qt.rect(0, 0, 0, 0)}
            style: root.layout
            x: geometry.bounds.x
            y: geometry.bounds.y
            width: geometry.bounds.width
            height: geometry.bounds.height
            colors: root.colors
            pixelSize: root.typography.small
            actionable: false
            visible: placed !== null
            onMeasurementsChanged: root.scheduleMeasurement()
        }
        onItemAdded: root.scheduleMeasurement()
        onItemRemoved: root.scheduleMeasurement()
    }

    Component.onCompleted: root.scheduleMeasurement()
}
