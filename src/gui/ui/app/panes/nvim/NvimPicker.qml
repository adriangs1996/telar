pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The editor's picker: files by name, lines of files by their text, or the editor's buffers.
// The query, the list and the keys are the window's own; the runtime searches where the files
// are and sends only what it found. What is chosen is shown beside the list in a float of
// Neovim itself, which the pane draws over the room this surface leaves for it.
FocusScope {
    id: root

    // The editor's picker: open, source, query, root, loading, truncated and rows of
    // {name, directory, line, text}.
    required property var picker
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property bool shown: picker.open ?? false
    readonly property var rows: picker.rows ?? []
    readonly property string source: picker.source ?? "files"
    readonly property var sources: [{name: "files", label: "Files"}, {name: "text", label: "Text"}, {name: "buffers", label: "Buffers"}]
    readonly property real rowHeight: (source === "text" ? 42 : 30) * ratio
    readonly property real inset: 8 * ratio
    readonly property real headerHeight: 44 * ratio
    readonly property real scopeHeight: 30 * ratio
    readonly property real footerHeight: 30 * ratio
    readonly property real listWidth: Math.round(width * 0.42)
    readonly property real listHeight: height - headerHeight - scopeHeight - footerHeight
    readonly property int visibleRows: Math.max(1, Math.floor(listHeight / rowHeight))
    readonly property int firstRow: Math.max(0, Math.min(rows.length - visibleRows, current - Math.floor(visibleRows / 2)))
    // The room left for the preview, in the parent's own coordinates.
    readonly property rect previewArea: Qt.rect(x + listWidth + inset, y + inset, width - listWidth - 2 * inset, height - 2 * inset)
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

    onShownChanged: {
        current = 0;
        marked = [];
        if (shown) {
            field.text = picker.query ?? "";
            forceActiveFocus();
        }
    }

    // The query is the picker's: what was typed here, or what another view of the pane typed.
    onPickerChanged: {
        const query = picker.query ?? "";
        if (shown && field.text !== query) {
            field.text = query;
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

    Keys.onPressed: event => {
        if (!root.shown) {
            return;
        }

        const control = (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0;
        if (event.key === Qt.Key_Escape) {
            root.closed();
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

    NvimSurface {
        anchors.fill: parent
        colors: root.colors
        ratio: root.ratio
    }

    // What is searched for, and what in.
    ChromeText {
        id: mark
        x: 16 * root.ratio
        width: 16 * root.ratio
        height: root.headerHeight
        text: root.source === "text" ? "/" : "›"
        pixelSize: root.typography.body
        emphasized: true
        color: root.colors.accent
    }

    TextInput {
        id: field
        x: mark.x + mark.width + 6 * root.ratio
        width: root.listWidth - x - 48 * root.ratio
        height: root.headerHeight
        focus: true
        color: root.colors.text
        selectionColor: Qt.alpha(root.colors.accent, 0.35)
        selectedTextColor: root.colors.text
        font.pixelSize: root.typography.body
        verticalAlignment: TextInput.AlignVCenter
        clip: true
        onTextEdited: root.searched(text)
    }

    ChromeText {
        x: root.listWidth - width - 12 * root.ratio
        width: 36 * root.ratio
        height: root.headerHeight
        horizontalAlignment: Text.AlignRight
        text: "esc"
        pixelSize: root.typography.small
        color: Qt.alpha(root.colors.text, 0.45)
    }

    Rectangle {
        y: root.headerHeight - height
        width: root.listWidth
        height: Math.max(1, root.ratio) / Screen.devicePixelRatio
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    Row {
        x: 12 * root.ratio
        y: root.headerHeight
        height: root.scopeHeight
        spacing: 4 * root.ratio

        Repeater {
            model: root.sources

            delegate: Item {
                id: scope

                required property var modelData
                readonly property bool chosen: modelData.name === root.source

                width: label.implicitWidth + 16 * root.ratio
                height: root.scopeHeight

                NativeRoundedRectangle {
                    y: 5 * root.ratio
                    width: parent.width
                    height: parent.height - 10 * root.ratio
                    radius: ChromeStyle.smallRadius * root.ratio
                    color: Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
                    visible: scope.chosen
                }

                ChromeText {
                    id: label
                    anchors.centerIn: parent
                    width: implicitWidth
                    height: parent.height
                    text: scope.modelData.label
                    pixelSize: root.typography.small
                    emphasized: scope.chosen
                    color: scope.chosen ? root.colors.text : root.colors.subtext0
                }

                ActionPointer {
                    anchors.fill: parent
                    identity: scope.modelData.name
                    onActivated: root.sourceChosen(scope.modelData.name)
                }
            }
        }
    }

    ChromeText {
        x: 12 * root.ratio
        y: root.headerHeight
        width: root.listWidth - 24 * root.ratio
        height: root.scopeHeight
        horizontalAlignment: Text.AlignRight
        text: (root.picker.loading ?? false) ? "searching" : root.rows.length + ((root.picker.truncated ?? false) ? "+" : "")
        pixelSize: root.typography.small
        color: Qt.alpha(root.colors.text, 0.45)
    }

    Item {
        x: root.inset
        y: root.headerHeight + root.scopeHeight
        width: root.listWidth - 2 * root.inset
        height: root.listHeight
        clip: true

        Repeater {
            model: Math.min(root.visibleRows, root.rows.length)

            delegate: Item {
                id: entry

                required property int index
                readonly property int rowIndex: root.firstRow + index
                readonly property var row: root.rows[rowIndex] ?? ({})
                readonly property bool chosen: rowIndex === root.current
                readonly property bool isMarked: root.marked.indexOf(rowIndex) >= 0
                readonly property bool textual: (row.line ?? 0) > 0

                y: index * root.rowHeight
                width: parent.width
                height: root.rowHeight

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: ChromeStyle.controlRadius * root.ratio
                    color: Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
                    visible: entry.chosen
                }

                Rectangle {
                    visible: entry.isMarked
                    x: 2 * root.ratio
                    y: 6 * root.ratio
                    width: 2 * root.ratio
                    height: parent.height - 12 * root.ratio
                    radius: width / 2
                    color: root.colors.accent
                }

                ChromeText {
                    id: name
                    x: 10 * root.ratio
                    width: Math.min(implicitWidth, parent.width - 20 * root.ratio)
                    height: entry.textual ? parent.height / 2 : parent.height
                    text: (entry.row.name ?? "") + (entry.textual ? ":" + entry.row.line : "")
                    pixelSize: root.typography.body
                    emphasized: entry.chosen
                    color: entry.chosen ? root.colors.text : root.colors.subtext0
                }

                ChromeText {
                    x: name.x + name.width + 10 * root.ratio
                    width: Math.max(0, parent.width - x - 8 * root.ratio)
                    height: name.height
                    text: entry.row.directory ?? ""
                    pixelSize: root.typography.small
                    color: Qt.alpha(root.colors.text, 0.45)
                    elide: Text.ElideLeft
                }

                // The line that matched, under the file that holds it.
                ChromeText {
                    visible: entry.textual
                    x: 10 * root.ratio
                    y: parent.height / 2 - 2 * root.ratio
                    width: parent.width - 18 * root.ratio
                    height: parent.height / 2
                    text: entry.row.text ?? ""
                    pixelSize: root.typography.small
                    color: Qt.alpha(root.colors.text, 0.6)
                }

                ActionPointer {
                    anchors.fill: parent
                    identity: String(entry.rowIndex)
                    onContainsMouseChanged: {
                        if (containsMouse) {
                            root.current = entry.rowIndex;
                        }
                    }
                    onActivated: root.accepted(entry.rowIndex, "")
                }
            }
        }

        ChromeText {
            visible: root.rows.length === 0 && !(root.picker.loading ?? false)
            anchors.centerIn: parent
            width: implicitWidth
            height: 24 * root.ratio
            text: root.source === "text" && field.text.length < 2 ? "Type to search the text of the files" : "Nothing found"
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, 0.45)
        }
    }

    // Between the list and the room of the preview.
    Rectangle {
        x: root.listWidth
        y: root.inset
        width: Math.max(1, root.ratio) / Screen.devicePixelRatio
        height: root.height - 2 * root.inset
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    KeyHintBar {
        y: root.height - root.footerHeight
        width: root.listWidth
        height: root.footerHeight
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        hints: [{keys: ["↑", "↓"], word: "Navigate"}, {keys: ["⇥"], word: "Mark"}, {keys: ["↵"], word: root.marked.length > 0 ? "Quickfix" : "Open"}, {keys: ["⌃↵"], word: "Split"}]
    }
}
