pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

// The menu under the workspace track: every workspace of the machine in the track's order, each
// with what the track has no room for: beside its name the counts of its worktrees and agents
// that are not zero, under it its path and branch. Typing filters the rows by name; Enter
// chooses the selected one. The last row creates a workspace.
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
    readonly property real markSide: Math.round(24 * ratio)
    // The rows' columns, shared with the machine menu: the mark, then the name.
    readonly property real markX: Math.round(8 * ratio)
    readonly property real textX: markX + markSide + Math.round(6 * ratio)
    readonly property real checkSide: Math.round(14 * ratio)
    readonly property real hairline: 1 / Screen.devicePixelRatio
    readonly property real fixedHeight: inset + fieldHeight + inset + hairline + inset + inset + footer.height + inset
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
        ProviderMark {
            objectName: "workspaceMenuSearch"
            x: root.inset + root.markX + (root.markSide - width) / 2
            y: query.y + (query.height - height) / 2
            width: root.checkSide
            height: width
            symbol: "search"
            color: root.colors.subtext0
        }

        FormTextField {
            id: query
            objectName: "workspaceMenuQuery"
            x: root.inset + root.textX - Math.round(10 * root.ratio)
            y: root.inset
            width: Math.max(0, parent.width - 2 * x)
            height: root.fieldHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            maximumBytes: 256
            placeholderText: "Find a workspace"
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
            height: Math.max(0, footer.y - root.inset - y)
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
                // The end of the first line, from the edge in: the column of the current mark,
                // kept on every row so the rows' ends line up, what waits on the person, then
                // the counts.
                readonly property real checkRoom: root.checkSide + Math.round(8 * root.ratio)
                readonly property real attentionRoom: alerting ? attentionLabel.width + Math.round(8 * root.ratio) : 0
                readonly property real endRoom: checkRoom + attentionRoom + Math.round(8 * root.ratio)
                readonly property real nameRoom: Math.max(0, width - root.textX - endRoom)

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
                    x: root.markX
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
                    x: root.textX
                    y: Math.round(5 * root.ratio)
                    // The counts keep their own width, up to half the line; the name takes the rest.
                    width: Math.max(0, row.nameRoom - (factsLabel.visible ? factsLabel.width + Math.round(12 * root.ratio) : 0))
                    height: Math.round(18 * root.ratio)
                    text: row.modelData.name ?? ""
                    color: root.colors.chromeText
                    pixelSize: root.typography.body
                    emphasized: true
                    Accessible.ignored: true
                }

                // How many worktrees it has and how many of its agents work or finished, the
                // zero ones left out.
                ChromeText {
                    id: factsLabel
                    objectName: "workspaceMenuFacts"
                    x: root.textX + row.nameRoom - width
                    y: Math.round(5 * root.ratio)
                    width: Math.min(Math.ceil(implicitWidth), Math.round(row.nameRoom / 2))
                    height: Math.round(18 * root.ratio)
                    text: row.modelData.facts ?? ""
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    horizontalAlignment: Text.AlignRight
                    visible: text.length > 0 && width > 0
                    Accessible.ignored: true
                }

                // Its path as the prompt reads it, cut in the middle so the folder that names it
                // stays; then its branch.
                ChromeText {
                    objectName: "workspaceMenuPath"
                    x: root.textX
                    y: Math.round(23 * root.ratio)
                    width: Math.max(0, row.width - x - row.checkRoom - Math.round(8 * root.ratio) - (branchLabel.visible ? branchLabel.width + Math.round(12 * root.ratio) : 0))
                    height: Math.round(16 * root.ratio)
                    text: row.modelData.shownPath ?? ""
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    elide: Text.ElideMiddle
                    Accessible.ignored: true
                }

                // The branch as the sidebar's cards draw it: the branch icon, then its name.
                Item {
                    id: branchLabel
                    objectName: "workspaceMenuBranch"
                    readonly property real iconSide: Math.round(12 * root.ratio)
                    readonly property real iconGap: Math.round(4 * root.ratio)
                    readonly property real room: Math.round((row.width - root.textX) * 0.4)
                    x: row.width - width - row.checkRoom - Math.round(8 * root.ratio)
                    y: Math.round(23 * root.ratio)
                    width: Math.min(iconSide + iconGap + Math.ceil(branchName.implicitWidth), room)
                    height: Math.round(16 * root.ratio)
                    visible: branchName.text.length > 0

                    ProviderMark {
                        y: (parent.height - height) / 2
                        width: branchLabel.iconSide
                        height: width
                        symbol: "git-branch"
                        color: root.colors.subtext0
                    }

                    ChromeText {
                        id: branchName
                        x: branchLabel.iconSide + branchLabel.iconGap
                        width: Math.max(0, parent.width - x)
                        height: parent.height
                        text: (row.modelData.branch ?? "") + ((row.modelData.branch ?? "").length > 0 && row.modelData.dirty ? " ●" : "")
                        color: root.colors.subtext0
                        pixelSize: root.typography.small
                        Accessible.ignored: true
                    }
                }

                ChromeText {
                    id: attentionLabel
                    objectName: "workspaceMenuAttention"
                    x: row.width - width - Math.round(8 * root.ratio) - row.checkRoom
                    y: Math.round(5 * root.ratio)
                    width: Math.ceil(implicitWidth)
                    height: Math.round(18 * root.ratio)
                    text: row.modelData.attention ?? ""
                    color: root.colors[row.modelData.attentionColor ?? "yellow"]
                    pixelSize: root.typography.small
                    emphasized: true
                    elide: Text.ElideNone
                    visible: row.alerting
                    Accessible.ignored: true
                }

                ProviderMark {
                    objectName: "workspaceMenuCurrent"
                    x: row.width - width - Math.round(8 * root.ratio)
                    y: (row.height - height) / 2
                    width: root.checkSide
                    height: width
                    symbol: "check"
                    color: root.colors.chromeText
                    visible: row.current
                }

                Accessible.role: Accessible.Button
                Accessible.name: [modelData.name ?? "", modelData.facts ?? "", modelData.shownPath ?? ""].filter(part => part.length > 0).join(", ") + (current ? ", current workspace" : "") + (alerting ? ", needs attention" : "")
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

        MenuFooter {
            id: footer
            objectName: "workspaceMenuCreate"
            x: root.inset
            y: parent.height - root.inset - height
            width: Math.max(0, parent.width - 2 * root.inset)
            height: implicitHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            markCenter: root.markX + root.markSide / 2
            textX: root.textX
            text: "New workspace"
            onTriggered: {
                root.close();
                root.createRequested();
            }
        }
    }
}
