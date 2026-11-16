pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The dialogs that ask for one line of text: renaming a tab or a workspace,
// and searching the scrollback.
Item {
    id: root
    objectName: "promptPanel"

    required property var colors
    required property var typography
    // The dialog open: Store.Dialog.rename_tab, rename_workspace or copy_search.
    required property int dialog
    // The command whose output a scrollback search reads, empty for the whole scrollback, and
    // whether Tab may switch between the two.
    property string searchScope: ""
    property bool searchScopes: false
    property real ratio: 1
    readonly property bool searchMode: dialog === Store.Dialog.copy_search
    readonly property bool submittable: name.text.trim().length > 0
    property alias field: name
    // Enter with a name: the window renames or searches with `input`.
    signal submitted(var input)
    signal cancelled()
    // Tab during a scrollback search: the window switches what it reads.
    signal searchScopeToggled()

    readonly property real sectionGap: 18 * ratio
    readonly property real titleLeading: 1.35

    implicitHeight: column.implicitHeight

    function submit() {
        if (root.submittable) {
            root.submitted({text: name.text, path: ""});
        }
    }

    Column {
        id: column
        width: parent.width
        spacing: root.sectionGap

        ChromeText {
            width: parent.width
            height: Math.ceil((root.typography.title ?? 0) * root.titleLeading)
            text: root.searchMode ? (root.searchScope.length > 0 ? "Search output of " + root.searchScope : "Search scrollback") : root.dialog === Store.Dialog.rename_tab ? "Rename tab" : "Rename workspace"
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
            onCancelled: root.cancelled()
            // A search begun from a command reads its output or the whole scrollback.
            onTabbed: {
                if (root.searchMode && root.searchScopes) {
                    root.searchScopeToggled();
                }
            }
        }

        PromptActions {
            width: parent.width
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            hint: root.searchMode && root.searchScopes ? (root.searchScope.length > 0 ? "Tab whole scrollback" : "Tab this command") + "  ·  Enter to confirm  ·  Esc to cancel" : "Enter to confirm  ·  Esc to cancel"
            submitText: root.searchMode ? "Search" : "Rename"
            submittable: root.submittable
            onSubmitted: root.submit()
            onCancelled: root.cancelled()
        }
    }
}
