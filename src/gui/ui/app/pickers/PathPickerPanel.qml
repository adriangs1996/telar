pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The terminal's path search as a dialog. It is the window's one picker panel, the one the
// editor's picker is too: this gives it the paths the session listed under the pane's
// directory and says what its keys do here, which is to walk directories and to insert the
// path chosen into the prompt.
Item {
    id: root
    objectName: "pathPickerPanel"

    required property PathPickerController controller
    required property var colors
    required property var typography
    // The platform's Control modifier, as an event modifier mask.
    required property int controlModifier
    property real ratio: 1
    readonly property var state: controller.state
    readonly property var regions: controller.geometry
    // Escape on an empty composition, or Control+H: the window closes the search.
    signal cancelled()
    property alias queryField: panel.queryField

    clip: true

    function synchronizeEditor() {
        if (panel.queryField.text !== state.editorText) {
            panel.queryField.text = state.editorText;
            panel.queryField.cursorPosition = panel.queryField.text.length;
        }
    }

    PathKeys {
        id: keys
        controller: root.controller
        controlModifier: root.controlModifier
        onCancelled: root.cancelled()
    }

    Component.onCompleted: {
        synchronizeEditor();
        panel.queryField.forceActiveFocus();
    }

    Connections {
        target: root.controller
        function onChanged() {
            root.synchronizeEditor();
        }
    }

    PickerPanel {
        id: panel

        // As many cells as a name has room for: a longer path is cut where its label says.
        readonly property int columns: Math.max(8, Math.floor((listWidth - 56 * root.ratio) / Math.max(1, root.typography.grid?.cellWidth ?? 8)))
        // The paths listed, read again whenever the session or the selection changes: both are
        // read in the expression itself, where a compiled binding cannot drop them as unused.
        readonly property var listed: root.state && root.regions ? root.controller.rows(columns, 0, 64) : []

        anchors.fill: parent
        compact: true
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        fieldName: "commandSearch"
        searchName: "Search paths"
        maximumQueryBytes: root.state.maximumQueryBytes
        label: root.state.rootLabel
        countText: root.state.countText
        emptyText: root.state.count === 0 ? root.state.emptyText : ""
        status: root.state.status
        failed: root.state.failed
        rows: listed.map(row => ({runs: row.runs, icon: row.icon, iconTone: row.iconTone, identity: root.state.revision + ":" + row.path}))
        current: Math.max(0, listed.findIndex(row => row.selected))
        hints: (root.regions.hints ?? []).map(hint => ({keys: [hint.key], word: hint.word}))
        onSearched: text => root.controller.search(text)
        onLimitReached: requested => root.controller.reportQueryLimit(requested)
        onRowActivated: index => root.controller.activate({path: listed[index].path, revision: root.state.revision, absolute: false})
        onKeyPressed: event => {
            if (event.key === Qt.Key_Down) {
                root.controller.move(1);
            } else if (event.key === Qt.Key_Up) {
                root.controller.move(-1);
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                keys.submit(event);
            } else if (event.key === Qt.Key_Tab) {
                root.controller.descend();
            } else if (event.key === Qt.Key_Backtab) {
                root.controller.ascend();
            } else if (event.key === Qt.Key_Escape) {
                if (!queryField.cancelComposition()) {
                    root.cancelled();
                }
            } else {
                event.accepted = keys.handle(event);
                return;
            }

            event.accepted = true;
        }
    }
}
