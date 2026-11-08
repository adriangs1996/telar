pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The dialogs that ask for one line of text: renaming a tab or a workspace,
// and searching the scrollback.
Item {
    id: root
    objectName: "promptPanel"

    required property var controller
    property real ratio: 1
    readonly property var colors: controller.colors
    readonly property var typography: controller.windowGeometry.typography
    readonly property string dialog: controller.dialog
    readonly property bool searchMode: dialog === "copy-search"
    readonly property bool submittable: name.text.trim().length > 0
    property alias field: name

    readonly property real sectionGap: 18 * ratio
    readonly property real titleLeading: 1.35

    implicitHeight: column.implicitHeight

    function submit() {
        if (root.submittable) {
            root.controller.submitDialog({text: name.text, path: ""});
        }
    }

    Column {
        id: column
        width: parent.width
        spacing: root.sectionGap

        ChromeText {
            width: parent.width
            height: Math.ceil((root.typography.title ?? 0) * root.titleLeading)
            text: root.searchMode ? "Search scrollback" : root.dialog === "rename-tab" ? "Rename tab" : "Rename workspace"
            color: root.colors.text
            pixelSize: root.typography.title ?? 1
            emphasized: true
        }

        PromptField {
            id: name
            width: parent.width
            // Another panel's field answers to this name while it covers the prompt.
            inputName: root.visible ? "commandSearch" : "promptInactive"
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            placeholderText: root.searchMode ? "Search scrollback" : "Name"
            onSubmitted: root.submit()
            onCancelled: root.controller.execute(GuiController.Action.cancel)
        }

        PromptActions {
            width: parent.width
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            hint: "Enter to confirm  ·  Esc to cancel"
            submitText: root.searchMode ? "Search" : "Rename"
            submittable: root.submittable
            onSubmitted: root.submit()
            onCancelled: root.controller.execute(GuiController.Action.cancel)
        }
    }
}
