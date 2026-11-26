pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The picker every search of the window shares: what is typed, what it is searched in, the
// rows found with the one chosen, and the keys that apply, with room beside the list for a
// preview when its host has one. The terminal's path search and the editor's picker are both
// this panel; each gives it its rows and decides what its keys do.
//
// A row is {runs, suffix, detail, detailRuns, icon, badge, badgeTone, marked}:
// `runs` are the parts of its name, each {text, colorRole, bold}, as a path's label gives them;
// `suffix` follows the name, quiet, and is never cut; `detail` is a second line under it, a
// line of a file, and `detailRuns` the same line in parts, {text, bold}, with what the query
// matched bold; `icon` is the glyph of what it is, a file's type or a folder, quiet beside the
// name; `badge` is a letter at its end, what git says of it, drawn in `badgeTone`, a role of
// the window's colors.
//
// A focus scope: the keys given to the panel are its query's. A host that sets `focus` on the
// panel names the panel in its own scope, never an item that would hold the keys in the
// query's place.
FocusScope {
    id: root

    required property var colors
    required property var typography
    property real ratio: 1
    // The name tests and accessibility find the query's field by, and what it says it is.
    property string fieldName: "pickerSearch"
    property string searchName: "Search"
    // What the empty query says it searches.
    property string placeholder: ""
    // The icon before the query: what is searched.
    property string glyph: ""
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
    // One hint or a list of them, at the right edge: what Enter does goes last.
    property var trailing: null
    // The share of the panel left beside the list for a preview; none without one.
    property real previewShare: 0
    property string previewTitle: ""
    property string previewDetail: ""
    // A panel that opens under a terminal's cursor is measured in that terminal's cells: each
    // of its parts is then a row of them, and what the search says goes on the footer's row.
    property bool compact: false
    // The family rows write their names in, as an editor's picker writes its paths in the
    // editor's own; the window's without one.
    property string rowFamily: ""
    // The room a row's name has beside its icon and its letter of git, for a host that cuts
    // its names to it.
    readonly property real nameRoom: Math.max(0, listWidth - 2 * inset - 20 * ratio - iconSlot - iconGap - 24 * ratio)
    readonly property real cell: Math.max(typography.grid?.cellHeight ?? 0, 16 * ratio)
    readonly property real bodyRow: Math.max(typography.bodyRow ?? 0, typography.body ?? 0)
    readonly property real smallRow: Math.max(typography.smallRow ?? 0, typography.small ?? 0)
    readonly property bool detailed: rows.some(row => (row.detail ?? "").length > 0)
    readonly property real inset: 8 * ratio
    // Whether the renderer can fade what a row cuts; without shaders it is only cut.
    readonly property bool fades: GraphicsInfo.api !== GraphicsInfo.Software && GraphicsInfo.api !== GraphicsInfo.Unknown
    readonly property real headerHeight: compact ? Math.round(cell * 1.25) : 44 * ratio
    readonly property real scopeHeight: (scopes.length > 0 || label.length > 0 || countText.length > 0) ? (compact ? cell : 30 * ratio) : 0
    readonly property real statusHeight: status.length > 0 && !compact ? 22 * ratio : 0
    readonly property real footerHeight: (hints.length > 0 || trailing !== null || (compact && status.length > 0)) ? (compact ? Math.round(cell * 1.25) : 30 * ratio) : 0
    // A row of two lines holds both whole, with room above and below them.
    readonly property real rowPadding: 5 * ratio
    readonly property real rowHeight: detailed ? Math.ceil(bodyRow + smallRow + 2 * rowPadding) : compact ? cell : Math.max(30 * ratio, Math.ceil(bodyRow + 8 * ratio))
    // The slot of a row's icon, its glyph centred, and the gap to the name.
    readonly property real iconSlot: compact ? 2 * (typography.grid?.cellWidth ?? 8) : 20 * ratio
    readonly property real iconGap: compact ? 0 : 8 * ratio
    readonly property real listWidth: previewShare > 0 ? Math.round(width * (1 - previewShare)) : width
    readonly property real listHeight: Math.max(0, height - headerHeight - scopeHeight - statusHeight - footerHeight)
    readonly property int visibleRows: Math.max(1, Math.floor(listHeight / rowHeight))
    readonly property int firstRow: Math.max(0, Math.min(rows.length - visibleRows, current - Math.floor(visibleRows / 2)))
    // The room under the header beside the list, in the panel's own coordinates: the preview
    // starts right under the header's line.
    readonly property rect previewArea: previewShare > 0 ? Qt.rect(listWidth + inset, headerHeight, width - listWidth - 2 * inset, height - headerHeight - footerHeight) : Qt.rect(0, 0, 0, 0)
    property alias queryField: field
    signal searched(string text)
    signal limitReached(var requested)
    // A key the field was given: the host sets `event.accepted` for the ones it takes.
    signal keyPressed(var event)
    signal rowActivated(int index)
    signal rowPointed(int index)
    signal scopeChosen(string name)

    // A layer that fades what passes its right edge, where the renderer has shaders.
    component Fade: ShaderEffect {
        property variant source
        property real fadeStart: 0.8
        fragmentShader: "qrc:/telar/shaders/tab_caption.frag.qsb"
    }

    ChromeIcon {
        id: mark
        x: 16 * root.ratio
        y: Math.round((root.headerHeight - height) / 2)
        width: Math.round(root.typography.body * 1.15)
        height: width
        glyph: root.glyph
        pixelSize: width
        color: root.colors.accent
    }

    // In a terminal the query is a row of its cells; elsewhere it is a field of the window, in
    // the size of the rows, whose text starts its own padding (12, FormFieldGeometry's) after
    // the icon: 8 past it.
    FormTextField {
        id: field
        objectName: root.fieldName
        x: mark.x + mark.width + (root.compact ? 6 : 8 - 12) * root.ratio
        y: root.compact ? Math.round((root.headerHeight - height) / 2) : 0
        width: root.listWidth - x - 12 * root.ratio
        height: root.compact ? Math.max(root.typography.grid?.cellHeight ?? 0, 20 * root.ratio) : root.headerHeight
        focus: true
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        formControl: !root.compact
        placeholderText: root.placeholder
        maximumBytes: root.maximumQueryBytes
        Accessible.name: root.searchName
        onTextEdited: root.searched(text)
        onLimitReached: requested => root.limitReached(requested)
        Keys.onPressed: event => root.keyPressed(event)
    }

    Rectangle {
        y: root.headerHeight - height
        width: root.width
        height: Math.max(1, root.ratio) / Screen.devicePixelRatio
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    // What is searched in: the scopes to choose from, or where the search is rooted. In a
    // narrow list they stop before the count, never over the preview beside them.
    Row {
        x: 12 * root.ratio
        y: root.headerHeight
        width: Math.max(0, root.listWidth - x - 12 * root.ratio - count.implicitWidth - spacing)
        height: root.scopeHeight
        spacing: 4 * root.ratio
        visible: root.scopes.length > 0
        clip: true

        Repeater {
            model: root.scopes

            delegate: Item {
                id: entry

                required property var modelData
                readonly property bool chosen: modelData.name === root.scope

                readonly property string glyph: modelData.icon ?? ""
                readonly property real iconSide: glyph.length > 0 ? Math.round(root.typography.small * 1.1) : 0

                // As wide as its name in bold, chosen or not: choosing one moves no other.
                width: widest.implicitWidth + iconSide + (iconSide > 0 ? 5 * root.ratio : 0) + 16 * root.ratio
                height: root.scopeHeight
                // A chip is whole or not shown: the keys still reach the scopes left out.
                visible: x + width <= parent.width

                NativeRoundedRectangle {
                    height: Math.min(parent.height - 4 * root.ratio, Math.max(22 * root.ratio, root.smallRow + 4 * root.ratio))
                    y: Math.round((parent.height - height) / 2)
                    width: parent.width
                    radius: ChromeStyle.smallRadius * root.ratio
                    color: Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
                    visible: entry.chosen
                }

                ChromeIcon {
                    x: 8 * root.ratio
                    y: Math.round((parent.height - height) / 2)
                    width: entry.iconSide
                    height: entry.iconSide
                    glyph: entry.glyph
                    pixelSize: entry.iconSide
                    color: entry.chosen ? root.colors.accent : root.colors.subtext0
                    visible: entry.iconSide > 0
                }

                ChromeText {
                    id: widest
                    opacity: 0
                    width: implicitWidth
                    height: parent.height
                    text: entry.modelData.label
                    pixelSize: root.typography.small
                    emphasized: true
                }

                ChromeText {
                    x: 8 * root.ratio + entry.iconSide + (entry.iconSide > 0 ? 5 * root.ratio : 0)
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
        id: list
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
                readonly property bool twoLines: (row.detail ?? "").length > 0
                readonly property real badged: (row.badge ?? "").length > 0 ? badge.implicitWidth + 12 * root.ratio : 0
                // The band of the first line: the name's, whole in height.
                readonly property real firstTop: twoLines ? root.rowPadding : 0
                readonly property real firstHeight: twoLines ? root.bodyRow : height

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

                // What git says of it, at the row's end.
                ChromeText {
                    id: badge
                    x: parent.width - width - 12 * root.ratio
                    y: line.firstTop
                    width: implicitWidth
                    height: line.firstHeight
                    visible: line.badged > 0
                    text: line.row.badge ?? ""
                    pixelSize: root.typography.small
                    emphasized: true
                    color: root.colors[line.row.badgeTone ?? "subtext0"] ?? root.colors.subtext0
                }

                Item {
                    id: icon
                    x: 10 * root.ratio
                    y: line.firstTop
                    width: line.iconed ? root.iconSlot : 0
                    height: line.firstHeight
                    visible: line.iconed

                    // In one quiet tone, a little smaller than the name: the name is what is read.
                    ChromeIcon {
                        x: root.compact ? 0 : Math.round((parent.width - width) / 2)
                        anchors.verticalCenter: parent.verticalCenter
                        width: height
                        height: Math.round(root.typography.body * (root.compact ? 1.15 : 0.95))
                        glyph: line.row.icon ?? ""
                        pixelSize: height
                        color: Qt.alpha(root.colors.subtext0, 0.8)
                    }
                }

                // The name: its directory quiet, its own part plain, what the query matched
                // marked. What follows it is never cut: the name gives way, faded where it
                // stops.
                Item {
                    id: label
                    x: 10 * root.ratio + icon.width + (line.iconed ? root.iconGap : 0)
                    y: line.firstTop
                    width: Math.max(0, parent.width - x - 10 * root.ratio - line.badged)
                    height: line.firstHeight
                    readonly property real nameRoom: Math.max(0, width - (suffix.visible ? suffix.implicitWidth : 0))

                    Item {
                        id: nameBox
                        readonly property real nameWidth: coded.visible ? coded.implicitWidth : nameRow.implicitWidth
                        width: Math.min(nameWidth, label.nameRoom)
                        height: parent.height
                        clip: true
                        layer.enabled: nameWidth > label.nameRoom && root.fades
                        layer.effect: Fade {
                            fadeStart: Math.max(0, 1 - 24 * root.ratio / Math.max(1, nameBox.width))
                        }

                        // In the host's family: the runs as one line of styled text.
                        Text {
                            id: coded
                            visible: root.rowFamily.length > 0
                            height: parent.height
                            verticalAlignment: Text.AlignVCenter
                            renderType: Text.NativeRendering
                            font.family: root.rowFamily
                            font.pixelSize: root.typography.body
                            textFormat: Text.StyledText
                            text: visible ? root.pathText(line.row.runs ?? []) + root.quiet(line.row.suffix ?? "") : ""
                            color: root.colors.text
                            Accessible.ignored: true
                        }

                        Row {
                            id: nameRow
                            visible: !coded.visible
                            height: parent.height

                            Repeater {
                                model: line.row.runs ?? []

                                delegate: ChromeText {
                                    required property var modelData
                                    width: implicitWidth
                                    height: nameRow.height
                                    text: modelData.text
                                    pixelSize: root.typography.body
                                    elide: Text.ElideNone
                                    emphasized: modelData.bold
                                    color: modelData.bold ? root.colors.accent : modelData.colorRole === "text" ? root.colors.text : Qt.alpha(root.colors.text, 0.5)
                                }
                            }
                        }
                    }

                    ChromeText {
                        id: suffix
                        x: nameBox.width
                        width: implicitWidth
                        height: parent.height
                        visible: text.length > 0 && !coded.visible
                        text: line.row.suffix ?? ""
                        pixelSize: root.typography.body
                        elide: Text.ElideNone
                        color: Qt.alpha(root.colors.text, 0.5)
                    }
                }

                // What a row says under its name, as the line of text that matched: in the
                // editor's own family, under the name, with what the query matched marked.
                Text {
                    visible: line.twoLines
                    x: label.x
                    y: line.firstTop + line.firstHeight
                    width: parent.width - x - 10 * root.ratio
                    height: root.smallRow
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    renderType: Text.NativeRendering
                    // The configured family, or the one the terminal falls back to without one.
                    font.family: root.typography.primaryFamily || "Telar Forma"
                    font.pixelSize: root.typography.small
                    color: Qt.alpha(root.colors.text, 0.6)
                    textFormat: (line.row.detailRuns ?? []).length > 0 ? Text.StyledText : Text.PlainText
                    text: (line.row.detailRuns ?? []).length > 0 ? root.styled(line.row.detailRuns) : (line.row.detail ?? "")
                    Accessible.ignored: true
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

        // Where the rows shown are among all of them, when they are not all shown.
        NativeRoundedRectangle {
            readonly property real share: root.rows.length > 0 ? Math.min(1, root.visibleRows / root.rows.length) : 1
            visible: share < 1
            x: parent.width - width
            y: Math.round(parent.height * root.firstRow / Math.max(1, root.rows.length))
            width: 3 * root.ratio
            height: Math.max(12 * root.ratio, Math.round(parent.height * share))
            radius: width / 2
            color: Qt.alpha(root.colors.text, 0.28)
        }
    }

    // Between the list and the room of the preview.
    Rectangle {
        visible: root.previewShare > 0
        x: root.listWidth
        width: Math.max(1, root.ratio) / Screen.devicePixelRatio
        height: root.height - root.footerHeight
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    // What the preview shows: its name, then where it is, on the header's line.
    Row {
        x: root.listWidth + 2 * root.inset
        width: root.width - x - 2 * root.inset
        height: root.headerHeight
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

    function escaped(text) {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // Parts of a line as styled text: the matched ones bold, in the accent.
    function styled(runs) {
        const accent = String(root.colors.accent);

        return runs.map(run => run.bold ? "<b><font color=\"" + accent + "\">" + escaped(run.text) + "</font></b>" : escaped(run.text)).join("");
    }

    // Text quiet beside a name, as styled text.
    function quiet(text) {
        return text.length > 0 ? "<font color=\"" + String(Qt.alpha(root.colors.text, 0.5)) + "\">" + escaped(text) + "</font>" : "";
    }

    // A name's runs as styled text, for the host's family: what the query matched bold in the
    // accent, the name plain, the rest quiet.
    function pathText(runs) {
        const accent = String(root.colors.accent);

        return runs.map(run => run.bold ? "<b><font color=\"" + accent + "\">" + escaped(run.text) + "</font></b>" : run.colorRole === "text" ? escaped(run.text) : quiet(run.text)).join("");
    }
}
