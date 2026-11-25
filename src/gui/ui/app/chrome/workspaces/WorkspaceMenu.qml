pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

// The menu under the workspace track: every workspace of the machine in the track's order, each
// with what the track has no room for, its path or what its agents do and its branch. Typing
// filters the rows by name; Enter chooses the selected one. The last row creates a workspace.
Popup {
    id: root

    required property var model
    required property var colors
    required property var typography
    property real ratio: 1
    // The tallest the menu grows; past it the rows scroll.
    property real maximumHeight: 480 * ratio
    readonly property real inset: Math.round(6 * ratio)
    readonly property real rowHeight: Math.round(44 * ratio)
    readonly property real fieldHeight: Math.round(32 * ratio)
    readonly property real footerHeight: Math.round(32 * ratio)
    readonly property real markSide: Math.round(24 * ratio)
    readonly property real hairline: 1 / Screen.devicePixelRatio
    readonly property real fixedHeight: inset + fieldHeight + inset + hairline + inset + inset + hairline + inset + footerHeight + inset
    property string filter: ""
    property int selection: 0
    // The rows the filter keeps, each a record of the model.
    property var rows: []
    signal selected(string key)
    signal createRequested()

    objectName: "workspaceMenu"
    padding: 0
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.round(320 * ratio)
    height: fixedHeight + Math.min(Math.max(1, rows.length) * rowHeight, Math.max(rowHeight, maximumHeight - fixedHeight))
    background: DialogSurface {
        colors: root.colors
        ratio: root.ratio
    }
    // The menu dims nothing: the panes stay readable while a workspace is chosen.
    Overlay.modal: Item {}

    function refresh() {
        const needle = filter.trim().toLowerCase();
        const kept = [];
        let current = 0;

        for (let index = 0; index < source.count; ++index) {
            const record = source.objectAt(index)?.record;
            if (!record || (needle.length > 0 && !(record.name ?? "").toLowerCase().includes(needle))) continue;
            if (record.selected) current = kept.length;
            kept.push(record);
        }

        rows = kept;
        selection = needle.length > 0 ? 0 : current;
    }

    function move(delta) {
        if (rows.length > 0) selection = Math.max(0, Math.min(rows.length - 1, selection + delta));
    }

    function choose(index) {
        if (index < 0 || index >= rows.length) return;
        const key = rows[index].key;

        close();
        selected(key);
    }

    onAboutToShow: {
        query.text = "";
        filter = "";
        refresh();
    }
    onOpened: query.forceActiveFocus()
    onFilterChanged: refresh()
    onSelectionChanged: list.positionViewAtIndex(selection, ListView.Contain)

    // The model's records, read through one delegate each: a list model gives QML no other
    // way to its rows.
    Instantiator {
        id: source
        model: root.model
        delegate: QtObject {
            required property var record
            onRecordChanged: if (root.visible) root.refresh()
        }
        onObjectAdded: if (root.visible) root.refresh()
        onObjectRemoved: if (root.visible) root.refresh()
    }

    contentItem: Item {
        FormTextField {
            id: query
            objectName: "workspaceMenuQuery"
            x: root.inset + Math.round(8 * root.ratio)
            y: root.inset
            width: Math.max(0, parent.width - 2 * x)
            height: root.fieldHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            maximumBytes: 256
            placeholderText: "Find a workspace…"
            onTextEdited: root.filter = text
            onAccepted: root.choose(root.selection)
            Keys.priority: Keys.BeforeItem
            Keys.onUpPressed: root.move(-1)
            Keys.onDownPressed: root.move(1)
            Keys.onEscapePressed: {
                if (!query.cancelComposition()) root.close();
            }
        }

        Rectangle {
            x: root.inset
            y: query.y + query.height + root.inset
            width: Math.max(0, parent.width - 2 * root.inset)
            height: root.hairline
            color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
        }

        ListView {
            id: list
            objectName: "workspaceMenuList"
            x: root.inset
            y: query.y + query.height + 2 * root.inset + root.hairline
            width: Math.max(0, parent.width - 2 * root.inset)
            height: Math.max(0, footerRule.y - root.inset - y)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.rows

            delegate: AbstractButton {
                id: row
                objectName: "workspaceMenuRow"
                required property var modelData
                required property int index
                readonly property bool current: modelData.selected ?? false
                readonly property color hue: root.colors[modelData.markHue ?? "mauve"]
                readonly property bool alerting: (modelData.attention ?? "").length > 0
                readonly property real textX: Math.round(8 * root.ratio) + root.markSide + Math.round(10 * root.ratio)
                readonly property real endRoom: (current ? checkMark.width + Math.round(8 * root.ratio) : 0) + (alerting ? attentionLabel.width + Math.round(8 * root.ratio) : 0) + Math.round(8 * root.ratio)

                width: list.width
                height: root.rowHeight
                hoverEnabled: true
                focusPolicy: Qt.NoFocus
                padding: 0
                contentItem: null
                onClicked: root.choose(index)
                background: NativeRoundedRectangle {
                    radius: ChromeStyle.surfaceRadius * root.ratio
                    color: Qt.alpha(root.colors.text, row.index === root.selection ? ChromeStyle.selectionAlpha : row.hovered ? ChromeStyle.hoverAlpha : 0)
                }

                HoverHandler { cursorShape: Qt.PointingHandCursor }

                NativeRoundedRectangle {
                    objectName: "workspaceMenuMark"
                    x: Math.round(8 * root.ratio)
                    y: (row.height - height) / 2
                    width: root.markSide
                    height: root.markSide
                    radius: Math.round(7 * root.ratio)
                    color: Qt.alpha(row.hue, 0.16)
                    borderColor: row.hue
                    borderAlpha: 0.4
                    borderWidth: root.hairline

                    ChromeText {
                        anchors.fill: parent
                        text: row.modelData.initial || "?"
                        color: row.hue
                        pixelSize: root.typography.body
                        emphasized: true
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideNone
                        Accessible.ignored: true
                    }
                }

                ChromeText {
                    objectName: "workspaceMenuName"
                    x: row.textX
                    y: Math.round(5 * root.ratio)
                    width: Math.max(0, row.width - x - row.endRoom)
                    height: Math.round(18 * root.ratio)
                    text: row.modelData.name ?? ""
                    color: root.colors.chromeText
                    pixelSize: root.typography.body
                    emphasized: true
                    Accessible.ignored: true
                }

                // What its agents do when it has worktrees, else its path; then its branch.
                ChromeText {
                    objectName: "workspaceMenuDetail"
                    x: row.textX
                    y: Math.round(23 * root.ratio)
                    width: Math.max(0, row.width - x - row.endRoom)
                    height: Math.round(16 * root.ratio)
                    text: [row.modelData.detail ?? "", (row.modelData.branch ?? "").length > 0 ? "⎇ " + row.modelData.branch + (row.modelData.dirty ? " ●" : "") : ""].filter(part => part.length > 0).join("  ·  ")
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    Accessible.ignored: true
                }

                ChromeText {
                    id: attentionLabel
                    objectName: "workspaceMenuAttention"
                    x: row.width - width - Math.round(8 * root.ratio) - (row.current ? checkMark.width + Math.round(8 * root.ratio) : 0)
                    width: Math.ceil(implicitWidth)
                    height: row.height
                    text: row.modelData.attention ?? ""
                    color: root.colors[row.modelData.attentionColor ?? "yellow"]
                    pixelSize: root.typography.small
                    emphasized: true
                    elide: Text.ElideNone
                    visible: row.alerting
                    Accessible.ignored: true
                }

                ChromeIcon {
                    id: checkMark
                    objectName: "workspaceMenuCurrent"
                    x: row.width - width - Math.round(8 * root.ratio)
                    y: (row.height - height) / 2
                    width: Math.round(14 * root.ratio)
                    height: width
                    glyph: "✓"
                    color: root.colors.subtext0
                    pixelSize: width
                    primaryFamily: root.typography.primaryFamily ?? ""
                    primaryStyle: root.typography.primaryStyle ?? ""
                    visible: row.current
                }

                Accessible.role: Accessible.Button
                Accessible.name: (modelData.name ?? "") + " " + (modelData.path ?? "") + (current ? ", current workspace" : "") + (alerting ? ", needs attention" : "")
            }

            ChromeText {
                x: Math.round(8 * root.ratio)
                width: Math.max(0, parent.width - 2 * x)
                height: root.rowHeight
                text: "No workspace matches"
                color: root.colors.subtext0
                pixelSize: root.typography.body
                visible: root.rows.length === 0
            }
        }

        Rectangle {
            id: footerRule
            x: root.inset
            y: create.y - root.inset - height
            width: Math.max(0, parent.width - 2 * root.inset)
            height: root.hairline
            color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
        }

        ChromeButton {
            id: create
            objectName: "workspaceMenuCreate"
            x: root.inset
            y: parent.height - root.inset - height
            width: Math.max(0, parent.width - 2 * root.inset)
            height: root.footerHeight
            colors: root.colors
            pixelSize: root.typography.body
            cornerRadius: ChromeStyle.surfaceRadius * root.ratio
            focusPolicy: Qt.NoFocus
            Accessible.name: "New workspace"
            onClicked: {
                root.close();
                root.createRequested();
            }
            contentItem: Item {
                ChromeText {
                    x: Math.round(8 * root.ratio)
                    width: Math.max(0, parent.width - 2 * x)
                    height: parent.height
                    text: "New workspace…"
                    color: root.colors.subtext0
                    pixelSize: root.typography.body
                }
            }
        }
    }
}
