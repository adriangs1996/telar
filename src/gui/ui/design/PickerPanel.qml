pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The picker every search of the window shares: what is typed, what it is searched in, the
// rows found with the one chosen, and the keys that apply, with room beside the list for a
// preview when its host has one. The terminal's path search and the editor's picker are both
// this panel; each gives it its rows and decides what its keys do.
//
// A row is {runs, suffix, detail, detailRuns, detailFromEnd, detailCode, icon, badge,
// badgeTone, section, marked}:
// `runs` are the parts of its name, each {text, colorRole, bold}, as a path's label gives them;
// `suffix` follows the name, quiet, and is never cut; `detail` is a second line under it, a
// line of a file, and `detailRuns` the same line in parts, {text, bold}, with what the query
// matched bold; `icon` is the glyph of what it is, a file's type or a folder, quiet beside the
// name; `badge` is a letter at its end, what git says of it, drawn in `badgeTone`, a role of
// the window's colors. `detailFromEnd` cuts the detail from its start, as a folder keeps the
// part nearest its file, and `detailCode` writes it in the editor's family, as a line of code.
// `section` names the group a row is in: a spacious panel titles each group above its first row.
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
    // A panel that stands on its own over an editor: the query across its whole width with the
    // scopes and the count beside it, rows with room around them in groups, and a preview
    // column of its own, headed by where the file is.
    property bool spacious: false
    property string previewMeta: ""
    readonly property real cell: Math.max(typography.grid?.cellHeight ?? 0, 16 * ratio)
    readonly property real bodyRow: Math.max(typography.bodyRow ?? 0, typography.body ?? 0)
    readonly property real smallRow: Math.max(typography.smallRow ?? 0, typography.small ?? 0)
    readonly property bool detailed: rows.some(row => (row.detail ?? "").length > 0)
    readonly property real inset: 8 * ratio
    // Whether the renderer can fade what a row cuts; without shaders it is only cut.
    readonly property bool fades: GraphicsInfo.api !== GraphicsInfo.Software && GraphicsInfo.api !== GraphicsInfo.Unknown
    readonly property real headerHeight: compact ? Math.round(cell * 1.25) : spacious ? 58 * ratio : 44 * ratio
    readonly property real scopeHeight: !spacious && (scopes.length > 0 || label.length > 0 || countText.length > 0) ? (compact ? cell : 30 * ratio) : 0
    readonly property real previewHeaderHeight: spacious && previewShare > 0 ? 40 * ratio : 0
    readonly property real sectionHeight: 28 * ratio
    readonly property real statusHeight: status.length > 0 && !compact ? 22 * ratio : 0
    readonly property real footerHeight: (hints.length > 0 || trailing !== null || (compact && status.length > 0)) ? (compact ? Math.round(cell * 1.25) : 30 * ratio) : 0
    // A row of two lines holds both whole, with room above and below them.
    readonly property real rowPadding: 5 * ratio
    readonly property real rowHeight: spacious ? (detailed ? Math.ceil(bodyRow + smallRow + 14 * ratio) : Math.max(34 * ratio, Math.ceil(bodyRow + 14 * ratio))) : detailed ? Math.ceil(bodyRow + smallRow + 2 * rowPadding) : compact ? cell : Math.max(30 * ratio, Math.ceil(bodyRow + 8 * ratio))
    // The slot of a row's icon, its glyph centred, and the gap to the name.
    readonly property real iconSlot: compact ? 2 * (typography.grid?.cellWidth ?? 8) : spacious ? 22 * ratio : 20 * ratio
    readonly property real iconGap: compact ? 0 : spacious ? 10 * ratio : 8 * ratio
    readonly property real listWidth: previewShare > 0 ? Math.round(width * (1 - previewShare)) : width
    readonly property real listHeight: Math.max(0, height - headerHeight - scopeHeight - statusHeight - footerHeight)
    readonly property int visibleRows: Math.max(1, Math.floor(listHeight / rowHeight))
    readonly property int firstRow: Math.max(0, Math.min(rows.length - visibleRows, current - Math.floor(visibleRows / 2)))
    // Where each row starts in a spacious list, under the title of the group it opens, and the
    // height of them all; the list scrolls by pixels to keep the chosen row in its middle.
    readonly property var rowTops: {
        const tops = [];
        let top = 0;

        for (let index = 0; index < rows.length; ++index) {
            if (opensSection(index))
                top += sectionHeight;
            tops.push(top);
            top += rowHeight;
        }

        tops.push(top);
        return tops;
    }
    readonly property real scrollTop: spacious ? Math.max(0, Math.min((rowTops[current] ?? 0) + rowHeight / 2 - listHeight / 2, rowTops[rows.length] - listHeight)) : 0
    // The rows drawn: the first one any of shows, and how many from it.
    readonly property int windowFirst: {
        if (!spacious)
            return firstRow;
        let index = 0;
        while (index < rows.length && rowTops[index] + rowHeight <= scrollTop)
            ++index;
        return index;
    }
    readonly property int windowCount: {
        if (!spacious)
            return Math.min(visibleRows, rows.length);
        let index = windowFirst;
        while (index < rows.length && rowTops[index] - (opensSection(index) ? sectionHeight : 0) < scrollTop + listHeight)
            ++index;
        return index - windowFirst;
    }
    // The room under the header beside the list, in the panel's own coordinates: the preview
    // starts right under the header's line, or a spacious panel's preview header, with room
    // around it.
    readonly property rect previewArea: previewShare <= 0 ? Qt.rect(0, 0, 0, 0) : spacious ? Qt.rect(listWidth + 12 * ratio, headerHeight + previewHeaderHeight + 8 * ratio, width - listWidth - 24 * ratio, height - headerHeight - previewHeaderHeight - footerHeight - 8 * ratio) : Qt.rect(listWidth + inset, headerHeight, width - listWidth - 2 * inset, height - headerHeight - footerHeight)
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

    // Whether the row at `index` starts a group with a title.
    function opensSection(index) {
        const section = rows[index]?.section ?? "";

        return spacious && section.length > 0 && (index === 0 || (rows[index - 1]?.section ?? "") !== section);
    }

    ChromeIcon {
        id: mark
        x: (root.spacious ? 20 : 16) * root.ratio
        y: Math.round((root.headerHeight - height) / 2)
        width: Math.round(root.typography.body * (root.spacious ? 1.35 : 1.15))
        height: width
        glyph: root.glyph
        pixelSize: width
        color: root.spacious ? Qt.alpha(root.colors.subtext0, 0.9) : root.colors.accent
    }

    // In a terminal the query is a row of its cells; elsewhere it is a field of the window, in
    // the size of the rows, whose text starts its own padding (12, FormFieldGeometry's) after
    // the icon: 8 past it.
    FormTextField {
        id: field
        objectName: root.fieldName
        x: mark.x + mark.width + (root.compact ? 6 : root.spacious ? 12 - 12 : 8 - 12) * root.ratio
        y: root.compact ? Math.round((root.headerHeight - height) / 2) : 0
        width: (root.spacious ? controls.x : root.listWidth) - x - 12 * root.ratio
        height: root.compact ? Math.max(root.typography.grid?.cellHeight ?? 0, 20 * root.ratio) : root.headerHeight
        focus: true
        colors: root.colors
        // A spacious panel's query is what the eye starts on: larger than its rows.
        typography: root.spacious ? Object.assign({}, root.typography, {body: Math.round((root.typography.body ?? 13) * 1.25)}) : root.typography
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

    // In a spacious panel, at the header's end: how many were found, then the scopes as one
    // segmented control.
    Row {
        id: controls
        x: root.width - width - 14 * root.ratio
        height: root.headerHeight
        spacing: 14 * root.ratio
        visible: root.spacious

        ChromeText {
            width: implicitWidth
            height: parent.height
            text: root.countText
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, 0.45)
        }

        Item {
            id: segments
            readonly property real side: 30 * root.ratio
            width: segmentRow.width + 4 * root.ratio
            height: side
            y: Math.round((parent.height - height) / 2)
            visible: root.scopes.length > 0

            NativeRoundedRectangle {
                anchors.fill: parent
                radius: 8 * root.ratio
                color: Qt.alpha(root.colors.text, 0.05)
                borderWidth: Math.max(1, root.ratio) / Screen.devicePixelRatio
                borderColor: root.colors.text
                borderAlpha: ChromeStyle.outlineAlpha
            }

            Row {
                id: segmentRow
                x: 2 * root.ratio
                y: 2 * root.ratio
                height: segments.height - 4 * root.ratio
                spacing: 2 * root.ratio

                Repeater {
                    model: root.scopes

                    delegate: Item {
                        id: segment

                        required property var modelData
                        readonly property bool chosen: modelData.name === root.scope

                        width: segmentLabel.implicitWidth + 22 * root.ratio
                        height: segmentRow.height

                        NativeRoundedRectangle {
                            anchors.fill: parent
                            radius: 6 * root.ratio
                            color: Qt.alpha(root.colors.text, 0.1)
                            visible: segment.chosen
                        }

                        ChromeText {
                            id: segmentLabel
                            x: 11 * root.ratio
                            width: implicitWidth
                            height: parent.height
                            text: segment.modelData.label
                            pixelSize: root.typography.small
                            emphasized: segment.chosen
                            color: segment.chosen ? root.colors.text : root.colors.subtext0
                        }

                        ActionPointer {
                            anchors.fill: parent
                            identity: segment.modelData.name
                            onActivated: root.scopeChosen(segment.modelData.name)
                        }
                    }
                }
            }
        }
    }

    // What is searched in: the scopes to choose from, or where the search is rooted. In a
    // narrow list they stop before the count, never over the preview beside them.
    Row {
        x: 12 * root.ratio
        y: root.headerHeight
        width: Math.max(0, root.listWidth - x - 12 * root.ratio - count.implicitWidth - spacing)
        height: root.scopeHeight
        spacing: 4 * root.ratio
        visible: root.scopes.length > 0 && !root.spacious
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
        visible: root.scopes.length === 0 && root.label.length > 0 && !root.spacious
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
        visible: !root.spacious
        text: root.countText
        pixelSize: root.typography.small
        color: Qt.alpha(root.colors.text, 0.45)
    }

    // The column of a spacious panel's preview: the editor's own ground, under where the file is.
    Rectangle {
        visible: root.spacious && root.previewShare > 0
        x: root.listWidth
        y: root.headerHeight + root.previewHeaderHeight
        width: root.width - root.listWidth
        height: root.height - y - root.footerHeight
        color: Qt.rgba(root.colors.terminalBackground.r, root.colors.terminalBackground.g, root.colors.terminalBackground.b, 1)
    }

    Item {
        id: list
        x: root.spacious ? 8 * root.ratio : root.inset
        y: root.headerHeight + root.scopeHeight + (root.spacious ? 6 * root.ratio : 0)
        width: root.listWidth - 2 * x
        height: root.listHeight - (root.spacious ? 6 * root.ratio : 0)
        clip: true

        Repeater {
            model: root.windowCount

            delegate: Item {
                id: line

                required property int index
                readonly property int rowIndex: root.windowFirst + index
                readonly property var row: root.rows[rowIndex] ?? ({})
                readonly property bool chosen: rowIndex === root.current
                readonly property bool iconed: (row.icon ?? "").length > 0
                readonly property bool twoLines: (row.detail ?? "").length > 0
                readonly property real badged: (row.badge ?? "").length > 0 ? badge.implicitWidth + 12 * root.ratio : 0
                // The band of the first line: the name's, whole in height.
                readonly property real firstTop: twoLines ? (root.spacious ? 7 * root.ratio : root.rowPadding) : 0
                readonly property real firstHeight: twoLines ? root.bodyRow : height

                y: root.spacious ? root.rowTops[rowIndex] - root.scrollTop : index * root.rowHeight
                width: parent.width
                height: root.rowHeight

                // The title of the group this row opens, above it.
                ChromeText {
                    visible: root.opensSection(line.rowIndex)
                    x: 12 * root.ratio
                    y: -root.sectionHeight
                    width: parent.width - 2 * x
                    height: root.sectionHeight
                    text: (line.row.section ?? "").toUpperCase()
                    pixelSize: Math.round(root.typography.small * 0.88)
                    emphasized: true
                    color: Qt.alpha(root.colors.text, 0.4)
                }

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: (root.spacious ? 8 : ChromeStyle.controlRadius) * root.ratio
                    color: root.spacious ? Qt.alpha(root.colors.accent, 0.16) : Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
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
                    x: (root.spacious ? 12 : 10) * root.ratio
                    y: line.firstTop
                    width: line.iconed ? root.iconSlot : 0
                    height: line.firstHeight
                    visible: line.iconed

                    // In one quiet tone, a little smaller than the name: the name is what is read.
                    ChromeIcon {
                        x: root.compact ? 0 : Math.round((parent.width - width) / 2)
                        anchors.verticalCenter: parent.verticalCenter
                        width: height
                        height: Math.round(root.typography.body * (root.compact ? 1.15 : root.spacious ? 1.1 : 0.95))
                        glyph: line.row.icon ?? ""
                        pixelSize: height
                        color: root.spacious && line.chosen ? root.colors.accent : Qt.alpha(root.colors.subtext0, 0.8)
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
                        readonly property real nameWidth: nameRow.implicitWidth
                        width: Math.min(nameWidth, label.nameRoom)
                        height: parent.height
                        clip: true
                        layer.enabled: nameWidth > label.nameRoom && root.fades
                        layer.effect: Fade {
                            fadeStart: Math.max(0, 1 - 24 * root.ratio / Math.max(1, nameBox.width))
                        }

                        Row {
                            id: nameRow
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
                                    emphasized: modelData.bold || (root.spacious && line.chosen && modelData.colorRole === "text")
                                    color: modelData.bold ? root.colors.accent : modelData.colorRole === "text" ? (root.spacious && !line.chosen ? Qt.alpha(root.colors.text, 0.86) : root.colors.text) : Qt.alpha(root.colors.text, 0.5)
                                }
                            }
                        }
                    }

                    ChromeText {
                        id: suffix
                        x: nameBox.width
                        width: implicitWidth
                        height: parent.height
                        visible: text.length > 0
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
                    y: line.firstTop + line.firstHeight + (root.spacious ? 1 : 0) * root.ratio
                    width: parent.width - x - 10 * root.ratio
                    height: root.smallRow
                    verticalAlignment: Text.AlignVCenter
                    elide: (line.row.detailFromEnd ?? false) ? Text.ElideLeft : Text.ElideRight
                    renderType: Text.NativeRendering
                    // A line of code in the configured family, or the one the terminal falls back
                    // to without one; anything else in the window's.
                    font.family: (line.row.detailCode ?? true) ? (root.typography.primaryFamily || "Telar Forma") : "IBM Plex Sans"
                    font.pixelSize: root.typography.small
                    color: Qt.alpha(root.colors.text, root.spacious && !line.chosen ? 0.42 : 0.6)
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
            readonly property real total: root.rowTops[root.rows.length] ?? 0
            readonly property real share: root.spacious ? (total > 0 ? Math.min(1, parent.height / total) : 1) : root.rows.length > 0 ? Math.min(1, root.visibleRows / root.rows.length) : 1
            visible: share < 1
            x: parent.width - width
            y: Math.round(root.spacious ? parent.height * root.scrollTop / Math.max(1, total) : parent.height * root.firstRow / Math.max(1, root.rows.length))
            width: 3 * root.ratio
            height: Math.max(12 * root.ratio, Math.round(parent.height * share))
            radius: width / 2
            color: Qt.alpha(root.colors.text, 0.28)
        }
    }

    // Between the list and the room of the preview: under a spacious panel's header only.
    Rectangle {
        visible: root.previewShare > 0
        x: root.listWidth
        y: root.spacious ? root.headerHeight : 0
        width: Math.max(1, root.ratio) / Screen.devicePixelRatio
        height: root.height - y - root.footerHeight
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    // In a spacious panel, what the preview shows heads its column: the folders it is in, then
    // its name, and what the host says of it at the other end.
    Item {
        x: root.listWidth
        y: root.headerHeight
        width: root.width - root.listWidth
        height: root.previewHeaderHeight
        visible: root.spacious && root.previewShare > 0 && root.previewTitle.length > 0
        clip: true

        Row {
            x: 18 * root.ratio
            width: Math.max(0, meta.x - x - 12 * root.ratio)
            height: parent.height
            spacing: 6 * root.ratio
            clip: true

            Repeater {
                model: root.previewDetail.length > 0 ? root.previewDetail.split("/").filter(part => part.length > 0) : []

                delegate: Row {
                    required property string modelData
                    height: parent.height
                    spacing: 6 * root.ratio

                    ChromeText {
                        width: implicitWidth
                        height: parent.height
                        text: parent.modelData
                        pixelSize: root.typography.small
                        color: Qt.alpha(root.colors.text, 0.45)
                    }

                    ChromeText {
                        width: implicitWidth
                        height: parent.height
                        text: "\u203a"
                        pixelSize: root.typography.small
                        color: Qt.alpha(root.colors.text, 0.28)
                    }
                }
            }

            ChromeText {
                width: implicitWidth
                height: parent.height
                text: root.previewTitle
                pixelSize: root.typography.small
                emphasized: true
                color: root.colors.text
            }
        }

        ChromeText {
            id: meta
            x: parent.width - width - 18 * root.ratio
            width: implicitWidth
            height: parent.height
            text: root.previewMeta
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, 0.4)
        }

        Rectangle {
            y: parent.height - height
            width: parent.width
            height: Math.max(1, root.ratio) / Screen.devicePixelRatio
            color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
        }
    }

    // What the preview shows: its name, then where it is, on the header's line.
    Row {
        x: root.listWidth + 2 * root.inset
        width: root.width - x - 2 * root.inset
        height: root.headerHeight
        spacing: 8 * root.ratio
        visible: root.previewShare > 0 && root.previewTitle.length > 0 && !root.spacious
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
}
