pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The editor's picker: files by name, lines of files by their text, or the editor's buffers.
// It is the window's one picker panel, the one the terminal's path search is too, spacious over
// the editor pane: this gives it the editor's rows and says what its keys do here. The runtime
// searches where the files are and sends only what it found. A row reads as its file's name,
// then the folder it is in, and with nothing typed the files the editor has open come first.
// What is chosen is shown beside the list in a float of Neovim itself, which the pane draws
// where the panel's preview column leaves room, to the pixel.
FocusScope {
    id: root
    objectName: "editorPicker"

    // The editor's picker: open, source, query, root, loading, truncated and rows of
    // {runs, name, directory, line, text, textRuns, icon, badge, badgeTone, section}.
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
    readonly property var changes: ({M: "Modified", A: "Added", D: "Deleted", R: "Renamed", U: "Untracked", "!": "Conflicted"})
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

    // The panel stands apart from the editor, with the editor showing around it: as wide as a
    // list and a page of code need and no wider, in the upper part of the pane. The list keeps
    // to what a name and its folder need; a pane too narrow for a preview of 45 columns gives
    // the list all of it.
    readonly property real margin: 24 * ratio
    readonly property int splitWidth: Math.round(Math.min(480 * ratio, Math.max(340 * ratio, width * 0.42)))
    readonly property bool previewing: cellWidth > 0 && cellHeight > 0 && (width - splitWidth - 24 * ratio) / cellWidth >= 45
    readonly property int listWidth: previewing ? splitWidth : width

    width: Math.round(Math.min(parent.width - 2 * margin, 1120 * ratio))
    height: Math.round(Math.min(parent.height - 2 * margin, Math.max(440 * ratio, parent.height * 0.8)))
    x: Math.round((parent.width - width) / 2)
    y: Math.round(Math.max(margin, (parent.height - height) * 0.35)) - (1 - reveal) * 8 * ratio
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

    // A path's runs as a row's two lines: its name, and the folder before it with what the
    // query matched in it marked.
    function pathRow(row) {
        const runs = row.runs ?? [];
        const slash = runs.map(run => run.text).join("").lastIndexOf("/");
        const name = [];
        const folder = [];
        let at = 0;

        for (const run of runs) {
            const cut = Math.max(0, Math.min(run.text.length, slash + 1 - at));

            if (cut > 0)
                folder.push({text: run.text.slice(0, cut), bold: run.bold});
            if (cut < run.text.length)
                name.push({text: run.text.slice(cut), bold: run.bold, colorRole: "text"});
            at += run.text.length;
        }

        if (folder.length > 0)
            folder[folder.length - 1].text = folder[folder.length - 1].text.replace(/\/$/, "");
        return {name: name, folder: folder.filter(run => run.text.length > 0)};
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
        spacious: true
        fieldName: "editorPickerSearch"
        searchName: "Search the editor's files"
        placeholder: root.currentSource.placeholder
        glyph: root.currentSource.icon
        scopes: root.sources
        scope: root.source
        rows: root.rows.map((row, index) => {
            const lined = (row.line ?? 0) > 0;
            const path = root.pathRow(row);

            return {
                runs: path.name,
                icon: row.icon ?? "",
                badge: row.badge ?? "",
                badgeTone: row.badgeTone ?? "",
                suffix: lined ? ":" + row.line : "",
                // A line of text under the name it is in; a file's folder under its name.
                detail: lined ? (row.text ?? "") : (row.directory ?? ""),
                detailRuns: lined ? (row.textRuns ?? []) : path.folder,
                detailFromEnd: !lined,
                detailCode: lined,
                section: row.section ?? "",
                marked: root.marked.indexOf(index) >= 0
            };
        })
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
        previewTitle: root.currentRow?.name ?? ""
        previewDetail: root.currentRow?.directory ?? ""
        previewMeta: root.currentRow === null ? "" : (root.currentRow.line ?? 0) > 0 ? "Line " + root.currentRow.line : root.changes[root.currentRow.badge ?? ""] ?? ""
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
