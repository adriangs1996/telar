pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

Popup {
    id: root

    required property var controller
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var state: controller.componentPick
    readonly property var rows: state.rows ?? []
    readonly property real margin: 16 * ratio
    readonly property real fieldHeight: 36 * ratio
    readonly property real rowHeight: 48 * ratio
    property int selection: 0
    visible: state.open ?? false
    focus: true
    modal: true
    padding: margin
    width: Math.max(0, Math.min(640 * ratio, (parent?.width ?? 640) - 2 * margin))
    height: Math.max(0, Math.min(520 * ratio, (parent?.height ?? 520) - 2 * margin))
    x: ((parent?.width ?? width) - width) / 2
    y: ((parent?.height ?? height) - height) / 2
    objectName: "configuredPick"
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: DialogSurface { colors: root.colors; ratio: root.ratio }
    Overlay.modal: Rectangle { color: "black"; opacity: 0.25 }
    onClosed: if (state.open) controller.closeComponentPick()
    onRowsChanged: selection = state.preferredRow ?? 0
    onVisibleChanged: {
        if (visible) {
            query.text = "";
            selection = state.preferredRow ?? 0;
            Qt.callLater(function () { query.forceActiveFocus(); });
        }
    }
    onSelectionChanged: results.positionViewAtIndex(selection, ListView.Contain)

    function move(delta) {
        if (rows.length > 0) selection = Math.max(0, Math.min(rows.length - 1, selection + delta));
    }

    function choose() {
        controller.chooseComponentPick(selection, state.identity);
    }

    contentItem: Item {
        ChromeText {
            width: Math.max(0, parent.width - root.fieldHeight)
            height: root.fieldHeight
            text: root.state.title ?? ""
            color: root.colors.text
            pixelSize: root.typography.body
            emphasized: true
        }
        ChromeButton {
            x: parent.width - root.fieldHeight
            width: root.fieldHeight
            height: root.fieldHeight
            colors: root.colors
            text: "×"
            pixelSize: root.typography.body
            Accessible.name: "Close pick"
            onClicked: root.controller.closeComponentPick()
        }
        FormTextField {
            id: query
            objectName: "configuredPickQuery"
            y: root.fieldHeight + root.margin / 2
            width: parent.width
            height: root.fieldHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            formControl: true
            maximumBytes: 512
            placeholderText: root.state.placeholder ?? "Filter choices…"
            onTextEdited: root.controller.filterComponentPick(text)
            onAccepted: root.choose()
            Keys.priority: Keys.BeforeItem
            Keys.onUpPressed: root.move(-1)
            Keys.onDownPressed: root.move(1)
            Keys.onEscapePressed: {
                if (!query.cancelComposition()) root.controller.closeComponentPick();
            }
        }
        ListView {
            id: results
            objectName: "configuredPickRows"
            y: query.y + query.height + root.margin / 2
            width: parent.width
            height: Math.max(0, parent.height - y - root.fieldHeight)
            clip: true
            model: root.rows
            currentIndex: root.selection
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                id: option
                required property int index
                required property var modelData
                width: results.width
                height: root.rowHeight
                radius: 5 * root.ratio
                color: index === root.selection ? root.colors.surface1 : "transparent"
                readonly property real inset: 8 * root.ratio
                readonly property real swatchWidth: modelData.swatch?.length > 0 ? 48 * root.ratio : 0
                ChromeText {
                    x: option.inset
                    y: 2 * root.ratio
                    width: Math.max(0, parent.width - 2 * option.inset - option.swatchWidth)
                    height: root.rowHeight / 2
                    text: (option.modelData.selected ? "✓ " : "") + option.modelData.label
                    color: root.colors.text
                    pixelSize: root.typography.body
                }
                ChromeText {
                    x: option.inset
                    y: root.rowHeight / 2
                    width: Math.max(0, parent.width - 2 * option.inset - option.swatchWidth)
                    height: root.rowHeight / 2 - 2 * root.ratio
                    text: option.modelData.detail
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                }
                Row {
                    x: parent.width - option.swatchWidth - option.inset
                    y: (parent.height - 12 * root.ratio) / 2
                    spacing: 2 * root.ratio
                    Repeater {
                        model: option.modelData.swatch ?? []
                        Rectangle {
                            required property var modelData
                            width: 12 * root.ratio
                            height: width
                            radius: 2 * root.ratio
                            color: modelData
                        }
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: root.selection = option.index
                    onClicked: { root.selection = option.index; root.choose(); }
                }
            }
        }
        Text {
            y: parent.height - root.fieldHeight
            width: parent.width
            height: root.fieldHeight
            text: root.state.error?.length > 0 ? root.state.error : root.state.loading ? "Loading…" : root.rows.length === 0 ? "No matching choices" : root.state.selecting ? "The previous choice is running…" : "↑ ↓ to navigate · Enter to choose · Escape to close"
            color: root.state.error?.length > 0 ? root.colors.red : root.colors.subtext0
            font.family: "IBM Plex Sans"
            font.pixelSize: root.typography.small
            textFormat: Text.PlainText
            renderType: Text.NativeRendering
            wrapMode: Text.Wrap
            maximumLineCount: 2
        }
    }
}
