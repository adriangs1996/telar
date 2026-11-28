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
    // A filter word to search with, chosen from the suggestions.
    signal filterChosen(string word)
    // The filters worth trying from here, as the words that type them: each changes the search.
    readonly property var suggestions: {
        // Nothing recorded yet: no filter finds anything, the import does.
        if (root.state.phase !== "ready" || root.action === "import") {
            return [];
        }
        const words = [];
        if (!root.state.failedOnly) {
            words.push("exit:fail");
        }
        words.push(root.state.author === "agent" ? "by:you" : "by:agents");
        if (root.state.effectiveScope !== "cwd") {
            words.push("cwd:.");
        }
        return words;
    }

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

    // The filters the empty search can try, as chips that type them.
    Row {
        objectName: "historyEmptyFilters"
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.regions.action.y + root.regions.action.height + 14 * root.ratio
        spacing: 6 * root.ratio
        visible: root.suggestions.length > 0

        Repeater {
            model: root.suggestions
            delegate: Item {
                id: suggestion
                objectName: "historyEmptyFilter"
                required property string modelData
                width: word.implicitWidth + 16 * root.ratio
                height: 24 * root.ratio

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: 4 * root.ratio
                    color: area.containsMouse ? root.colors.surface1 : root.colors.surface0
                }

                CellText {
                    id: word
                    anchors.centerIn: parent
                    text: suggestion.modelData
                    color: root.colors.text
                    grid: root.typography.grid
                }

                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.filterChosen(suggestion.modelData)
                }

                Accessible.role: Accessible.Button
                Accessible.name: "Search with " + suggestion.modelData
            }
        }
    }

    Component.onCompleted: root.scheduleMeasurement()
}
