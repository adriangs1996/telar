pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "agentPeekPanel"

    required property var controller
    property real ratio: 1
    readonly property var colors: controller.colors
    readonly property var typography: controller.windowGeometry.typography
    readonly property var state: controller.peekState
    readonly property var regions: controller.peekGeometry
    property alias queryField: query

    clip: true

    function synchronizeEditor() {
        if (query.text !== state.editorText) {
            query.text = state.editorText;
            query.cursorPosition = query.text.length;
        }
    }

    Component.onCompleted: {
        synchronizeEditor();
        if (query.enabled) {
            query.forceActiveFocus();
        } else {
            root.forceActiveFocus();
        }
    }

    Keys.onEscapePressed: root.controller.execute(GuiController.Action.cancel)

    Connections {
        target: root.controller
        function onPeekChanged() {
            root.synchronizeEditor();
        }
    }

    CellText {
        x: root.regions.title.x
        y: root.regions.title.y
        width: root.regions.title.width
        height: root.regions.title.height
        text: root.state.title
        grid: root.typography.grid
        color: root.colors.accent
        bold: true
    }

    CellText {
        x: root.regions.facts.x
        y: root.regions.facts.y
        width: root.regions.facts.width
        height: root.regions.facts.height
        text: root.state.facts
        grid: root.typography.grid
        color: root.colors.subtext0
        clip: true
    }

    Item {
        x: root.regions.screen.x
        y: root.regions.screen.y
        width: root.regions.screen.width
        height: root.regions.screen.height
        clip: true

        Repeater {
            model: root.state.lines
            delegate: CellText {
                required property string modelData
                required property int index
                y: index * height
                width: parent.width
                height: root.typography.grid.cellHeight
                text: modelData
                grid: root.typography.grid
                color: root.colors.text
                clip: true
            }
        }
    }

    FormTextField {
        id: query
        objectName: "commandSearch"
        x: root.regions.field.x
        y: root.regions.field.y
        width: root.regions.field.width
        height: root.regions.field.height
        enabled: width > 0 && height > 0
        visible: enabled
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        formControl: false
        maximumBytes: root.state.maximumBytes
        Accessible.name: "Message agent"
        onEnabledChanged: {
            if (root.visible) {
                if (enabled) {
                    query.forceActiveFocus();
                } else {
                    root.forceActiveFocus();
                }
            }
        }
        Rectangle {
            anchors.fill: parent
            color: root.colors.surface0
            z: -1
        }
        onTextEdited: root.controller.searchPeek(text)
        onLimitReached: requested => root.controller.reportPeekLimit(requested)
        Keys.onReturnPressed: root.controller.submitPeek(root.state.revision)
        Keys.onEnterPressed: root.controller.submitPeek(root.state.revision)
        Keys.onEscapePressed: {
            if (!query.cancelComposition()) {
                root.controller.execute(GuiController.Action.cancel);
            }
        }
    }

    CellText {
        x: root.regions.footer.x
        y: root.regions.footer.y
        width: root.regions.footer.width
        height: root.regions.footer.height
        text: "Enter send  empty opens  /stop  /diff  Esc close"
        grid: root.typography.grid
        color: root.colors.subtext0
        clip: true
    }
}
