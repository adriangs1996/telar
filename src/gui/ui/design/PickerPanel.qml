pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The picker every search of the window shares: what is typed, what it is searched in, the
// rows found with the one chosen, and the keys that apply, with room beside the list for a
// preview when its host has one. The terminal's path search and the editor's picker are both
// this panel; each gives it its rows and decides what its keys do.
//
// A row is {runs, suffix, detail, icon, marked}: `runs` are the parts of its name, each
// {text, colorRole, bold}, as a path's label gives them; `suffix` follows the name; `detail`
// is a second line under it; `icon` is "directory", "file" or nothing.
Item {
    id: root

    required property var colors
    required property var typography
    property real ratio: 1
    // The name tests and accessibility find the query's field by, and what it says it is.
    property string fieldName: "pickerSearch"
    property string searchName: "Search"
    property string glyph: "›"
    property int maximumQueryBytes: 256
    // Where the search is rooted, shown when it has no scopes to choose from.
    property string label: ""
    property var scopes: []
    property string scope: ""
    property var rows: []
    property int current: 0
    property string countText: ""
    property string emptyText: ""
    property string status: ""
    property bool failed: false
    property var hints: []
    property var trailing: null
    // The share of the panel left beside the list for a preview; none without one.
    property real previewShare: 0
    property string previewTitle: ""
    property string previewDetail: ""
    // A panel that opens under a terminal's cursor is measured in that terminal's cells: each
    // of its parts is then a row of them, and what the search says goes on the footer's row.
    property bool compact: false
    readonly property real cell: Math.max(typography.grid?.cellHeight ?? 0, 16 * ratio)
    readonly property bool detailed: rows.some(row => (row.detail ?? "").length > 0)
    readonly property real inset: 8 * ratio
    readonly property real headerHeight: compact ? Math.round(cell * 1.25) : 44 * ratio
    readonly property real scopeHeight: (scopes.length > 0 || label.length > 0 || countText.length > 0) ? (compact ? cell : 30 * ratio) : 0
    readonly property real statusHeight: status.length > 0 && !compact ? 22 * ratio : 0
    readonly property real footerHeight: (hints.length > 0 || trailing !== null || (compact && status.length > 0)) ? (compact ? Math.round(cell * 1.25) : 30 * ratio) : 0
    readonly property real rowHeight: detailed ? 42 * ratio : compact ? cell : 30 * ratio
    readonly property real listWidth: previewShare > 0 ? Math.round(width * (1 - previewShare)) : width
    readonly property real listHeight: Math.max(0, height - headerHeight - scopeHeight - statusHeight - footerHeight)
    readonly property int visibleRows: Math.max(1, Math.floor(listHeight / rowHeight))
    readonly property int firstRow: Math.max(0, Math.min(rows.length - visibleRows, current - Math.floor(visibleRows / 2)))
    // The strip over the preview that names what it shows, and the room under it, in the
    // panel's own coordinates.
    readonly property real previewHeader: 34 * ratio
    readonly property rect previewArea: previewShare > 0 ? Qt.rect(listWidth + inset, previewHeader + inset / 2, width - listWidth - 2 * inset, height - previewHeader - footerHeight - inset) : Qt.rect(0, 0, 0, 0)
    property alias queryField: field
    signal searched(string text)
    signal limitReached(var requested)
    // A key the field was given: the host sets `event.accepted` for the ones it takes.
    signal keyPressed(var event)
    signal rowActivated(int index)
    signal rowPointed(int index)
    signal scopeChosen(string name)

    ChromeText {
        id: mark
        x: 16 * root.ratio
        width: 16 * root.ratio
        height: root.headerHeight
        text: root.glyph
        pixelSize: root.typography.body
        emphasized: true
        color: root.colors.accent
    }

    FormTextField {
        id: field
        objectName: root.fieldName
        x: mark.x + mark.width + 6 * root.ratio
        y: Math.round((root.headerHeight - height) / 2)
        width: root.listWidth - x - 48 * root.ratio
        height: Math.max(root.typography.grid?.cellHeight ?? 0, 20 * root.ratio)
        focus: true
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        formControl: false
        maximumBytes: root.maximumQueryBytes
        Accessible.name: root.searchName
        onTextEdited: root.searched(text)
        onLimitReached: requested => root.limitReached(requested)
        Keys.onPressed: event => root.keyPressed(event)
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

    // What is searched in: the scopes to choose from, or where the search is rooted.
    Row {
        x: 12 * root.ratio
        y: root.headerHeight
        height: root.scopeHeight
        spacing: 4 * root.ratio
        visible: root.scopes.length > 0

        Repeater {
            model: root.scopes

            delegate: Item {
                id: entry

                required property var modelData
                readonly property bool chosen: modelData.name === root.scope

                width: name.implicitWidth + 16 * root.ratio
                height: root.scopeHeight

                NativeRoundedRectangle {
                    y: 5 * root.ratio
                    width: parent.width
                    height: parent.height - 10 * root.ratio
                    radius: ChromeStyle.smallRadius * root.ratio
                    color: Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
                    visible: entry.chosen
                }

                ChromeText {
                    id: name
                    anchors.centerIn: parent
                    width: implicitWidth
                    height: parent.height
                    text: entry.modelData.label
                    pixelSize: root.typography.small
                    emphasized: entry.chosen
                    color: entry.chosen ? root.colors.text : root.colors.subtext0
                }

                ActionPointer {
                    anchors.fill: parent
                    identity: entry.modelData.name
                    onActivated: root.scopeChosen(entry.modelData.name)
                }
            }
        }
    }

    ChromeText {
        x: 16 * root.ratio
        y: root.headerHeight
        width: root.listWidth - 32 * root.ratio - count.implicitWidth
        height: root.scopeHeight
        visible: root.scopes.length === 0 && root.label.length > 0
        text: root.label
        pixelSize: root.typography.small
        color: root.colors.subtext0
        elide: Text.ElideLeft
    }

    ChromeText {
        id: count
        x: 12 * root.ratio
        y: root.headerHeight
        width: root.listWidth - 24 * root.ratio
        height: root.scopeHeight
        horizontalAlignment: Text.AlignRight
        text: root.countText
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
                id: line

                required property int index
                readonly property int rowIndex: root.firstRow + index
                readonly property var row: root.rows[rowIndex] ?? ({})
                readonly property bool chosen: rowIndex === root.current
                readonly property bool iconed: (row.icon ?? "").length > 0

                y: index * root.rowHeight
                width: parent.width
                height: root.rowHeight

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: ChromeStyle.controlRadius * root.ratio
                    color: Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
                    visible: line.chosen
                }

                Rectangle {
                    visible: line.row.marked ?? false
                    x: 2 * root.ratio
                    y: 6 * root.ratio
                    width: 2 * root.ratio
                    height: parent.height - 12 * root.ratio
                    radius: width / 2
                    color: root.colors.accent
                }

                CellText {
                    id: icon
                    x: 10 * root.ratio
                    width: line.iconed ? 2 * (root.typography.grid?.cellWidth ?? 8) : 0
                    height: root.detailed ? parent.height / 2 : parent.height
                    visible: line.iconed
                    text: line.row.icon === "directory" ? "" : ""
                    grid: root.typography.grid
                    color: line.row.icon === "directory" ? root.colors.blue : root.colors.subtext0
                }

                // The name: its directory quiet, its own part plain, what the query matched
                // marked. Then what follows it, as the line of a match of text.
                Row {
                    id: label
                    x: 10 * root.ratio + icon.width
                    width: Math.min(implicitWidth, parent.width - x - 10 * root.ratio)
                    height: (line.row.detail ?? "").length > 0 ? parent.height / 2 : parent.height
                    clip: true

                    Repeater {
                        model: line.row.runs ?? []

                        delegate: ChromeText {
                            required property var modelData
                            height: label.height
                            text: modelData.text
                            pixelSize: root.typography.body
                            emphasized: modelData.bold
                            color: modelData.bold ? root.colors.accent : modelData.colorRole === "text" ? root.colors.text : Qt.alpha(root.colors.text, 0.5)
                        }
                    }

                    ChromeText {
                        height: label.height
                        visible: (line.row.suffix ?? "").length > 0
                        text: line.row.suffix ?? ""
                        pixelSize: root.typography.body
                        color: Qt.alpha(root.colors.text, 0.5)
                    }
                }

                // What a row says under its name, as the line of text that matched.
                ChromeText {
                    visible: (line.row.detail ?? "").length > 0
                    x: 10 * root.ratio
                    y: parent.height / 2 - 2 * root.ratio
                    width: parent.width - 18 * root.ratio
                    height: parent.height / 2
                    text: line.row.detail ?? ""
                    pixelSize: root.typography.small
                    color: Qt.alpha(root.colors.text, 0.6)
                }

                ActionPointer {
                    anchors.fill: parent
                    identity: String(line.rowIndex) + ":" + (line.row.identity ?? "")
                    onContainsMouseChanged: {
                        if (containsMouse) {
                            root.rowPointed(line.rowIndex);
                        }
                    }
                    onActivated: root.rowActivated(line.rowIndex)
                }
            }
        }

        ChromeText {
            visible: root.rows.length === 0 && root.emptyText.length > 0
            anchors.centerIn: parent
            width: implicitWidth
            height: 24 * root.ratio
            text: root.emptyText
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, 0.45)
        }
    }

    // Between the list and the room of the preview.
    Rectangle {
        visible: root.previewShare > 0
        x: root.listWidth
        y: root.inset
        width: Math.max(1, root.ratio) / Screen.devicePixelRatio
        height: root.height - root.inset - root.footerHeight
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    // What the preview shows: its name, then where it is.
    Row {
        x: root.listWidth + root.inset
        width: root.width - x - root.inset
        height: root.previewHeader
        spacing: 8 * root.ratio
        visible: root.previewShare > 0 && root.previewTitle.length > 0
        clip: true

        ChromeText {
            height: parent.height
            text: root.previewTitle
            pixelSize: root.typography.small
            emphasized: true
            color: root.colors.text
        }

        ChromeText {
            height: parent.height
            text: root.previewDetail
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, 0.45)
        }
    }

    // What the search says of itself: that it is still reading, or why it could not. A compact
    // panel says it at the end of its footer's row.
    ChromeText {
        x: 16 * root.ratio
        y: root.compact ? root.height - root.footerHeight : root.height - root.footerHeight - root.statusHeight
        z: 1
        width: root.listWidth - 32 * root.ratio
        height: root.compact ? root.footerHeight : root.statusHeight
        horizontalAlignment: root.compact ? Text.AlignRight : Text.AlignLeft
        visible: root.status.length > 0
        text: root.status
        pixelSize: root.typography.small
        color: root.failed ? root.colors.red : root.colors.subtext0
    }

    KeyHintBar {
        y: root.height - root.footerHeight
        width: root.width
        height: root.footerHeight
        visible: root.footerHeight > 0
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        hints: root.hints
        trailing: root.trailing
    }
}
