pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

// A configured pick, drawn as the palette draws a nested list: a heading, the search band, whole
// rows and the shortcut bar, in the bands the palette geometry measures for it.
Popup {
    id: root

    required property ComponentsController controller
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var state: controller.pick
    readonly property var rows: state.rows ?? []
    readonly property var regions: state.geometry ?? ({})
    readonly property rect bounds: regions.bounds ?? Qt.rect(0, 0, 0, 0)
    readonly property rect heading: regions.heading ?? Qt.rect(0, 0, 0, 0)
    readonly property rect search: regions.search ?? Qt.rect(0, 0, 0, 0)
    readonly property rect results: regions.results ?? Qt.rect(0, 0, 0, 0)
    readonly property rect footer: regions.footer ?? Qt.rect(0, 0, 0, 0)
    readonly property real inset: 16 * ratio
    readonly property real iconWidth: 18 * ratio
    readonly property real iconGap: 8 * ratio
    readonly property real closeGap: 8 * ratio
    readonly property string status: state.error?.length > 0 ? state.error : state.loading ? "Loading…" : rows.length === 0 ? "No matching choices" : state.selecting ? "The previous choice is running…" : ""
    property int selection: 0
    visible: state.open ?? false
    focus: true
    modal: true
    padding: 0
    x: bounds.x
    y: bounds.y
    width: bounds.width
    height: bounds.height
    objectName: "configuredPick"
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: DialogSurface { colors: root.colors; ratio: root.ratio }
    Overlay.modal: Rectangle { color: "black"; opacity: 0.25 }
    onClosed: if (state.open) controller.closePick()
    onRowsChanged: selection = state.preferredRow ?? 0
    onVisibleChanged: {
        if (visible) {
            query.text = "";
            selection = state.preferredRow ?? 0;
            Qt.callLater(function () { query.forceActiveFocus(); });
        }
    }
    onSelectionChanged: list.positionViewAtIndex(selection, ListView.Contain)

    function move(delta) {
        if (rows.length > 0) selection = Math.max(0, Math.min(rows.length - 1, selection + delta));
    }

    function choose() {
        controller.choosePick(selection, state.identity);
    }

    contentItem: Item {
        OverlayHeader {
            x: root.heading.x + root.inset
            y: root.heading.y
            width: Math.max(0, root.heading.width - 2 * root.inset)
            height: root.heading.height
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            title: root.state.title ?? ""
        }

        Item {
            id: searchBand
            x: root.search.x
            y: root.search.y
            width: root.search.width
            height: root.search.height

            ChromeIcon {
                x: root.inset
                width: root.iconWidth
                height: searchBand.height
                glyph: "\uf002"
                pixelSize: root.typography.body
                color: root.colors.subtext0
            }

            FormTextField {
                id: query
                objectName: "configuredPickQuery"
                x: root.inset + root.iconWidth + root.iconGap
                width: Math.max(0, closeButton.x - root.closeGap - x)
                height: searchBand.height
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                maximumBytes: 512
                placeholderText: root.state.placeholder ?? "Filter choices…"
                onTextEdited: root.controller.filterPick(text)
                onAccepted: root.choose()
                Keys.priority: Keys.BeforeItem
                Keys.onUpPressed: root.move(-1)
                Keys.onDownPressed: root.move(1)
                Keys.onEscapePressed: {
                    if (!query.cancelComposition()) root.controller.closePick();
                }
            }

            PaletteButton {
                id: closeButton
                x: searchBand.width - root.inset - width
                width: closeKeycap.implicitWidth
                height: searchBand.height
                text: ""
                accessibleLabel: "Close pick"
                colors: root.colors
                pixelSize: root.typography.body
                ratio: root.ratio
                onActivated: root.controller.closePick()
            }

            PaletteKeycap {
                id: closeKeycap
                anchors.fill: closeButton
                colors: root.colors
                typography: root.typography
                text: "esc"
                ratio: root.ratio
            }

            Rectangle {
                y: parent.height - height
                width: parent.width
                height: Math.min(root.ratio, parent.height)
                color: root.colors.surface1
            }
        }

        ListView {
            id: list
            objectName: "configuredPickRows"
            x: root.results.x
            y: root.results.y
            width: root.results.width
            height: root.results.height
            clip: true
            model: root.rows
            currentIndex: root.selection
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            delegate: PaletteRow {
                required property int index
                required property var modelData
                width: list.width
                height: root.regions.rowHeight ?? 0
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                revision: root.state.identity ?? ""
                selected: index === root.selection
                record: ({
                    key: String(index),
                    icon: "",
                    primary: modelData.label,
                    secondary: modelData.detail,
                    hint: "",
                    shortcut: false,
                    detailBelow: false,
                    swatch: modelData.swatch,
                    checked: modelData.selected,
                })
                onActivated: {
                    root.selection = index;
                    root.choose();
                }
            }
        }

        ChromeText {
            x: root.results.x + root.inset / 2
            y: root.results.y
            width: Math.max(0, root.results.width - root.inset)
            height: root.typography.bodyRow + root.inset
            text: root.status
            color: root.state.error?.length > 0 ? root.colors.red : root.colors.subtext0
            pixelSize: root.typography.body
            visible: root.status.length > 0 && (root.rows.length === 0 || root.state.loading)
        }

        KeyHintBar {
            x: root.footer.x
            y: root.footer.y
            width: root.footer.width
            height: root.footer.height
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            hints: root.rows.length > 0 ? [{keys: ["↑", "↓"], word: "Navigate", action: ""}, {keys: ["↵"], word: "Choose", action: "submit"}] : []
            visible: !(root.status.length > 0 && root.rows.length > 0)
            onActivated: root.choose()
        }

        ChromeText {
            x: root.footer.x + root.inset
            y: root.footer.y
            width: Math.max(0, root.footer.width - 2 * root.inset)
            height: root.footer.height
            text: root.status
            color: root.state.error?.length > 0 ? root.colors.red : root.colors.subtext0
            pixelSize: root.typography.small
            visible: root.status.length > 0 && root.rows.length > 0
        }
    }
}
