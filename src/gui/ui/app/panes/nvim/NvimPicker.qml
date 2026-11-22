pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The editor's picker: files by name, lines of files by their text, or the editor's buffers.
// It is the window's one picker panel, the one the terminal's path search is too, over the
// editor pane: this gives it the editor's rows and says what its keys do here. The runtime
// searches where the files are and sends only what it found. What is chosen is shown beside
// the list in a float of Neovim itself, which the pane draws over the room the panel leaves.
FocusScope {
    id: root
    objectName: "editorPicker"

    // The editor's picker: open, source, query, root, loading, truncated and rows of
    // {runs, name, directory, line, text}.
    required property var picker
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property bool shown: picker.open ?? false
    readonly property var rows: picker.rows ?? []
    readonly property string source: picker.source ?? "files"
    readonly property var sources: [{name: "files", label: "Files", icon: "\uea7b"}, {name: "text", label: "Text", icon: "\uea6d"}, {name: "buffers", label: "Buffers", icon: "\ueaf0"}]
    // The room left for the preview, in the parent's own coordinates.
    readonly property rect previewArea: Qt.rect(x + panel.previewArea.x, y + panel.previewArea.y, panel.previewArea.width, panel.previewArea.height)
    readonly property var currentRow: rows[current] ?? null
    property int current: 0
    // The entries marked for the quickfix list, by their place in the list.
    property var marked: []
    property real reveal: shown ? 1 : 0
    signal searched(string query)
    signal sourceChosen(string source)
    // The entry at `index` is to be opened: in place, or in a "split", a "vertical" split or a "tab".
    signal accepted(int index, string where)
    signal listed(var indices)
    // Another entry is the current one, or none is: its preview follows.
    signal previewed(int index, rect area)
    signal closed()

    width: Math.min(parent.width - 32 * ratio, 1040 * ratio)
    height: Math.min(parent.height - 32 * ratio, 560 * ratio)
    x: Math.round((parent.width - width) / 2)
    y: Math.round((parent.height - height) / 2) - (1 - reveal) * 8 * ratio
    opacity: reveal
    visible: reveal > 0

    function show() {
        if (shown) {
            root.previewed(rows.length > 0 ? current : -1, previewArea);
        }
    }

    function synchronizeQuery() {
        const query = picker.query ?? "";
        if (panel.queryField.text !== query) {
            panel.queryField.text = query;
            panel.queryField.cursorPosition = query.length;
        }
    }

    onShownChanged: {
        current = 0;
        marked = [];
        if (shown) {
            synchronizeQuery();
            forceActiveFocus();
        }
    }

    // The query is the picker's: what was typed here, or what another view of the pane typed.
    onPickerChanged: {
        if (shown) {
            synchronizeQuery();
        }
    }

    // A new list starts on its first entry; the preview waits for the keys to rest.
    onRowsChanged: {
        current = Math.min(current, Math.max(0, rows.length - 1));
        marked = [];
        rest.restart();
    }

    onCurrentChanged: rest.restart()
    onPreviewAreaChanged: rest.restart()

    Timer {
        id: rest
        interval: 60
        onTriggered: root.show()
    }

    Behavior on reveal {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    NvimSurface {
        anchors.fill: parent
        colors: root.colors
        ratio: root.ratio
    }

    PickerPanel {
        id: panel
        anchors.fill: parent
        focus: true
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        fieldName: "editorPickerSearch"
        searchName: "Search the editor's files"
        glyph: root.sources.find(source => source.name === root.source)?.icon ?? "\uea6d"
        scopes: root.sources
        scope: root.source
        rows: root.rows.map((row, index) => ({
            runs: row.runs ?? [],
            icon: row.icon ?? "",
            iconTone: row.iconTone ?? "",
            suffix: (row.line ?? 0) > 0 ? ":" + row.line : "",
            detail: (row.line ?? 0) > 0 ? (row.text ?? "") : "",
            marked: root.marked.indexOf(index) >= 0
        }))
        current: root.current
        countText: (root.picker.loading ?? false) ? "searching" : root.rows.length + ((root.picker.truncated ?? false) ? "+" : "")
        emptyText: (root.picker.loading ?? false) ? "" : root.source === "text" && queryField.text.length < 2 ? "Type to search the text of the files" : "Nothing found"
        hints: [{keys: ["↑", "↓"], word: "Navigate"}, {keys: ["⇥"], word: "Mark"}, {keys: ["⌃↵"], word: "Split"}]
        // What Enter does, where the eye ends.
        trailing: ({keys: ["↵"], word: root.marked.length > 0 ? "Quickfix" : "Open"})
        previewShare: 0.58
        previewTitle: root.currentRow === null ? "" : (root.currentRow.name ?? "") + ((root.currentRow.line ?? 0) > 0 ? ":" + root.currentRow.line : "")
        previewDetail: root.currentRow?.directory ?? ""
        onSearched: text => root.searched(text)
        onScopeChosen: name => root.sourceChosen(name)
        onRowPointed: index => root.current = index
        onRowActivated: index => root.accepted(index, "")
        onKeyPressed: event => {
            if (!root.shown) {
                return;
            }

            const control = (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0;
            if (event.key === Qt.Key_Escape) {
                if (!queryField.cancelComposition()) {
                    root.closed();
                }
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.marked.length > 0) {
                    root.listed(root.marked);
                } else if (root.rows.length > 0) {
                    root.accepted(root.current, control ? "split" : (event.modifiers & Qt.AltModifier) ? "tab" : "");
                }
            } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && control)) {
                root.current = (root.current + 1) % Math.max(1, root.rows.length);
            } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && control)) {
                root.current = (root.current + root.rows.length - 1) % Math.max(1, root.rows.length);
            } else if (event.key === Qt.Key_Tab && root.rows.length > 0) {
                const kept = root.marked.filter(index => index !== root.current);

                root.marked = kept.length === root.marked.length ? root.marked.concat([root.current]) : kept;
                root.current = (root.current + 1) % root.rows.length;
            } else if (event.key === Qt.Key_Backtab) {
                const at = root.sources.findIndex(entry => entry.name === root.source);

                root.sourceChosen(root.sources[(at + 1) % root.sources.length].name);
            } else {
                return;
            }

            event.accepted = true;
        }
    }
}
