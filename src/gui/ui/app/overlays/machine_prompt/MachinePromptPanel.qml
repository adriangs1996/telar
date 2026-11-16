pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "machinePromptPanel"

    required property MachinePromptController controller
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var state: controller.state
    readonly property var regions: controller.geometry
    property alias queryField: query
    // Escape on an empty composition: the window closes the prompt.
    signal cancelled()

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
        function onChanged() {
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
        onTextEdited: root.controller.search(text)
        onLimitReached: requested => root.controller.reportLimit(requested)
        Keys.onReturnPressed: root.controller.submit(root.state.revision)
        Keys.onEnterPressed: root.controller.submit(root.state.revision)
        Keys.onEscapePressed: {
            if (!query.cancelComposition()) {
                root.cancelled();
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
