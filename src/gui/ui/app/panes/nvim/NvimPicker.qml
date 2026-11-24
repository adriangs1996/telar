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
    // {runs, trail, name, directory, line, text, textRuns}.
    required property var picker
    required property var colors
    required property var typography
    property real ratio: 1
    // The cells of the editor the panel lies over: its preview is a float of them.
    property real cellWidth: 0
    property real cellHeight: 0
    readonly property bool shown: picker.open ?? false
    readonly property var rows: picker.rows ?? []
    readonly property string source: picker.source ?? "files"
    readonly property var sources: [{name: "files", label: "Files", icon: "\uea7b", unit: "file", placeholder: "Search files by name"}, {name: "text", label: "Text", icon: "\uea6d", unit: "match", placeholder: "Search the text of the files"}, {name: "buffers", label: "Buffers", icon: "\ueaf0", unit: "buffer", placeholder: "Search open buffers"}]
    readonly property var currentSource: sources.find(entry => entry.name === source) ?? sources[0]
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

    // The panel takes a share of the pane, never less than it took when its size was fixed,
    // and stands on the editor's cells: its preview starts on a column, right under the
    // header, and holds whole cells. The list keeps to what a name needs and the preview to
    // what a line of code needs; a pane too narrow for a preview gives the list all of it.
    readonly property real margin: 16 * ratio
    readonly property real roomWidth: Math.min(parent.width - 2 * margin, Math.max(1040 * ratio, parent.width * 0.8))
    readonly property real roomHeight: Math.min(parent.height - 2 * margin, Math.max(560 * ratio, parent.height * 0.75))
    readonly property int listWidth: Math.round(Math.min(560 * ratio, Math.max(320 * ratio, roomWidth * 0.4)))
    readonly property int previewColumns: cellWidth > 0 ? Math.min(140, Math.floor((roomWidth - listWidth - 2 * panel.inset) / cellWidth)) : 0
    readonly property bool previewing: previewColumns >= 45 && cellHeight > 0
    readonly property int previewRows: previewing ? Math.floor((roomHeight - panel.headerHeight - panel.footerHeight) / cellHeight) : 0
    // The first column and row of the preview, nearest to the panel centred in the pane.
    readonly property int previewColumn: previewing ? Math.max(Math.ceil((listWidth + panel.inset) / cellWidth), Math.min(Math.floor((parent.width - width + listWidth + panel.inset) / cellWidth), Math.round(((parent.width - width) / 2 + listWidth + panel.inset) / cellWidth))) : 0
    readonly property int previewRow: previewing ? Math.max(Math.ceil(panel.headerHeight / cellHeight), Math.min(Math.floor((parent.height - height + panel.headerHeight) / cellHeight), Math.round(((parent.height - height) / 2 + panel.headerHeight) / cellHeight))) : 0

    // A pixel past the cells, as the panel's own edges are whole pixels below theirs.
    width: previewing ? Math.ceil(listWidth + 2 * panel.inset + previewColumns * cellWidth) + 1 : Math.round(roomWidth)
    height: previewing ? Math.ceil(panel.headerHeight + previewRows * cellHeight + panel.footerHeight) + 1 : Math.round(roomHeight)
    x: previewing ? Math.floor(previewColumn * cellWidth - listWidth - panel.inset) : Math.round((parent.width - width) / 2)
    y: (previewing ? Math.floor(previewRow * cellHeight - panel.headerHeight) : Math.round((parent.height - height) / 2)) - (1 - reveal) * 8 * ratio
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
        placeholder: root.currentSource.placeholder
        glyph: root.currentSource.icon
        scopes: root.sources
        scope: root.source
        rows: root.rows.map((row, index) => ({
            runs: row.runs ?? [],
            trail: row.trail ?? [],
            icon: row.icon ?? "",
            iconTone: row.iconTone ?? "",
            badge: row.badge ?? "",
            badgeTone: row.badgeTone ?? "",
            suffix: (row.line ?? 0) > 0 ? ":" + row.line : "",
            detail: (row.line ?? 0) > 0 ? (row.text ?? "") : "",
            detailRuns: (row.line ?? 0) > 0 ? (row.textRuns ?? []) : [],
            marked: root.marked.indexOf(index) >= 0
        }))
        current: root.current
        // Where the chosen row is among those found, and what they are.
        countText: {
            if (root.picker.loading ?? false) {
                return "searching";
            }

            const total = root.rows.length + ((root.picker.truncated ?? false) ? "+" : "");
            const unit = root.currentSource.unit + (root.rows.length === 1 && !(root.picker.truncated ?? false) ? "" : (root.currentSource.unit === "match" ? "es" : "s"));

            return (root.rows.length > 0 ? (root.current + 1) + " / " : "") + total + " " + unit;
        }
        emptyText: (root.picker.loading ?? false) ? "" : root.source === "text" && queryField.text.length < 2 ? "Type to search the text of the files" : "Nothing found"
        hints: [{keys: ["↑", "↓"], word: "Navigate"}, {keys: ["⇥"], word: "Mark"}, {keys: ["⌃↵"], word: "Split"}, {keys: ["⇧⇥"], word: "Source"}]
        // What Enter does, where the eye ends.
        trailing: [{keys: ["esc"], word: "Close"}, {keys: ["↵"], word: root.marked.length > 0 ? "Quickfix" : "Open", primary: true}]
        previewShare: root.previewing ? 1 - root.listWidth / root.width : 0
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
