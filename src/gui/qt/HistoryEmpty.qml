pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

HistoryEmptyLayout {
    id: root
    objectName: "historyEmpty"

    required property var state
    required property var colors
    required property var typography
    required property string workspace
    property real ratio: 1
    readonly property var regions: layout
    signal searchEverywhere()

    input: ({state: root.state, workspace: root.workspace, ratio: root.ratio, bodyPixels: root.typography.body, smallPixels: root.typography.small})

    function measure() {
        root.measurements = {title: title.implicitWidth, subtitle: subtitle.implicitWidth, import: command.implicitWidth};
    }

    function scheduleMeasurement() {
        Qt.callLater(root.measure);
    }

    ChromeText {
        id: title
        objectName: "historyEmptyTitle"
        x: root.regions.title.x
        y: root.regions.title.y
        width: root.regions.title.width
        height: root.regions.title.height
        text: root.title
        emphasized: root.emphasized
        color: root.colors.text
        pixelSize: root.typography.body
        elide: Text.ElideNone
        onImplicitWidthChanged: root.scheduleMeasurement()
    }

    ChromeText {
        id: subtitle
        objectName: "historyEmptySubtitle"
        x: root.regions.subtitle.x
        y: root.regions.subtitle.y
        width: root.regions.subtitle.width
        height: root.regions.subtitle.height
        text: root.subtitle
        visible: text.length > 0
        color: root.colors.subtext0
        pixelSize: root.typography.small
        elide: Text.ElideNone
        onImplicitWidthChanged: root.scheduleMeasurement()
    }

    Item {
        x: root.regions.action.x
        y: root.regions.action.y
        width: root.regions.action.width
        height: root.regions.action.height
        visible: root.action === "import"

        NativeRoundedRectangle {
            anchors.fill: parent
            radius: root.regions.importRadius
            color: root.colors.surface0
        }

        CellText {
            id: command
            objectName: "historyImportCommand"
            x: root.regions.importInset
            width: Math.max(0, parent.width - 2 * x)
            height: parent.height
            text: "telar history import"
            color: root.colors.text
            grid: root.typography.grid
            onImplicitWidthChanged: root.scheduleMeasurement()
        }
    }

    FormButton {
        objectName: "historySearchEverywhere"
        x: root.regions.action.x
        y: root.regions.action.y
        width: root.regions.action.width
        height: root.regions.action.height
        visible: root.action === "everywhere"
        text: "Search everywhere"
        identity: root.state.effectiveScope ?? ""
        colors: root.colors
        pixelSize: root.typography.body
        radius: root.regions.buttonRadius
        disabledAlpha: root.regions.disabledAlpha
        pressedAlpha: root.regions.pressedAlpha
        onActivated: root.searchEverywhere()
    }

    Component.onCompleted: root.scheduleMeasurement()
}
