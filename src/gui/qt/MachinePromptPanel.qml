pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "machinePromptPanel"

    required property var controller
    property real ratio: 1
    readonly property var colors: controller.colors
    readonly property var typography: controller.windowGeometry.typography
    readonly property var state: controller.machinePromptState
    readonly property var regions: controller.machinePromptGeometry
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
        query.forceActiveFocus();
    }

    Connections {
        target: root.controller
        function onMachinePromptChanged() {
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

    FormTextField {
        id: query
        objectName: "commandSearch"
        x: root.regions.field.x
        y: root.regions.field.y
        width: root.regions.field.width
        height: root.regions.field.height
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        formControl: false
        maximumBytes: root.state.maximumBytes
        Accessible.name: root.state.title
        Rectangle {
            anchors.fill: parent
            color: root.colors.surface0
            z: -1
        }
        onTextEdited: root.controller.searchMachinePrompt(text)
        onLimitReached: requested => root.controller.reportMachinePromptLimit(requested)
        Keys.onReturnPressed: root.controller.submitMachinePrompt(root.state.revision)
        Keys.onEnterPressed: root.controller.submitMachinePrompt(root.state.revision)
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
        text: "Enter confirm  Esc cancel"
        grid: root.typography.grid
        color: root.colors.subtext0
    }
}
