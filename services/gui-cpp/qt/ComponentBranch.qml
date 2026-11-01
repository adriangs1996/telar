pragma ComponentBehavior: Bound

import QtQuick

Loader {
    id: root
    required property var controller
    required property var surface
    required property var colors
    required property var typography
    property real ratio: 1
    property real rowHeight: 28 * ratio
    property int parentIndex: -1
    property bool tooltip: false
    property bool horizontal: true
    property bool fit: horizontal && parentIndex < 0
    property var roots: []
    property var fittedLevels: null
    property bool initialized: false

    function loadBranch() {
        if (!active || !initialized) return;
        setSource(Qt.resolvedUrl("ComponentTree.qml"), {
            controller: Qt.binding(() => root.controller),
            surface: Qt.binding(() => root.surface),
            colors: Qt.binding(() => root.colors),
            typography: Qt.binding(() => root.typography),
            ratio: Qt.binding(() => root.ratio),
            rowHeight: Qt.binding(() => root.rowHeight),
            parentIndex: Qt.binding(() => root.parentIndex),
            tooltip: Qt.binding(() => root.tooltip),
            horizontal: Qt.binding(() => root.horizontal),
            fit: Qt.binding(() => root.fit),
            roots: Qt.binding(() => root.roots),
            fittedLevels: Qt.binding(() => root.fittedLevels),
        });
    }

    Component.onCompleted: {
        initialized = true;
        loadBranch();
    }
    onActiveChanged: {
        if (active) loadBranch();
        else source = "";
    }
}
