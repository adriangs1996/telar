pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// New workspace, as the Zig form: an optional name, a working directory with
// folder suggestions, and a confirmation before creating a missing folder.
// Tab moves from the name to the directory and there takes the selected
// folder; Shift+Tab goes back; the arrows move through the folders.
Item {
    id: root
    objectName: "workspaceForm"

    required property var controller
    property real ratio: 1
    readonly property var colors: controller.colors
    readonly property var typography: controller.windowGeometry.typography
    readonly property var state: controller.workspaceFormState
    readonly property var entries: state.entries ?? []
    readonly property int selection: state.selection ?? 0
    readonly property bool confirmCreate: state.confirmCreate ?? false
    readonly property bool submittable: name.text.trim().length > 0 || directory.text.trim().length > 0
    property alias field: name
    property alias directoryField: directory

    readonly property real sectionGap: 16 * ratio
    readonly property real labelGap: 6 * ratio
    readonly property real titleLeading: 1.35
    readonly property real smallLeading: 1.4
    readonly property real labelSpacing: 6 * ratio
    readonly property int maximumRows: 5
    readonly property int visibleRows: Math.min(entries.length, maximumRows)
    readonly property int firstRow: Math.max(0, selection + 1 - maximumRows)
    readonly property real rowHeight: (typography.bodyRow ?? 0) + 2 * 6 * ratio
    readonly property real rowRadius: 6 * ratio
    readonly property real rowInset: 10 * ratio
    readonly property real iconGap: 8 * ratio
    readonly property real noticePadding: 10 * ratio
    readonly property real noticeRadius: 7 * ratio
    readonly property real scrollbarWidth: 3 * ratio
    readonly property real smallRow: Math.ceil((typography.small ?? 0) * smallLeading)

    implicitHeight: column.implicitHeight

    function submit() {
        if (root.submittable) {
            root.controller.submitDialog({text: name.text, path: directory.text});
        }
    }

    function cancel() {
        root.controller.execute(GuiController.Action.cancel);
    }

    function useDirectory(path) {
        if (path.length === 0) {
            return;
        }

        directory.text = path;
        directory.input.cursorPosition = path.length;
        directory.input.forceActiveFocus();
        root.controller.editWorkspaceDirectory(path);
    }

    Connections {
        target: root.controller
        function onDialogChanged() {
            if (root.controller.dialog === "new-workspace") {
                name.text = "";
                directory.text = "";
                root.controller.editWorkspaceDirectory("");
            }
        }
    }

    component Label: ChromeText {
        width: parent?.width ?? 0
        height: Math.ceil((root.typography.body ?? 0) * root.smallLeading)
        color: root.colors.text
        pixelSize: root.typography.body ?? 1
        emphasized: true
    }

    component Caption: ChromeText {
        width: parent?.width ?? 0
        height: root.smallRow
        color: root.colors.subtext0
        pixelSize: root.typography.small ?? 1
    }

    Column {
        id: column
        width: parent.width
        spacing: root.sectionGap

        Column {
            width: parent.width

            ChromeText {
                width: parent.width
                height: Math.ceil((root.typography.title ?? 0) * root.titleLeading)
                text: "New workspace"
                color: root.colors.text
                pixelSize: root.typography.title ?? 1
                emphasized: true
            }

            Caption {
                text: "A workspace for your project."
            }
        }

        Column {
            width: parent.width
            spacing: root.labelGap

            Row {
                spacing: root.labelSpacing

                Label {
                    width: implicitWidth
                    text: "Name"
                }

                Caption {
                    width: implicitWidth
                    height: parent.height
                    text: "Optional"
                }
            }

            PromptField {
                id: name
                width: parent.width
                inputName: root.visible ? "commandSearch" : "workspaceNameInactive"
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                placeholderText: "e.g. payments-api"
                onSubmitted: root.submit()
                onCancelled: root.cancel()
                onTabbed: directory.input.forceActiveFocus()
            }

            Caption {
                text: "Defaults to the folder name."
            }
        }

        Column {
            width: parent.width
            spacing: root.labelGap

            Label {
                text: "Working directory"
            }

            PromptField {
                id: directory
                width: parent.width
                inputName: "workspaceDirectory"
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                placeholderText: "~/projects/my-app"
                onEdited: root.controller.editWorkspaceDirectory(text)
                onSubmitted: root.submit()
                onCancelled: root.cancel()
                onMoved: delta => root.controller.moveWorkspaceDirectory(delta)
                onTabbed: backward => {
                    if (backward) {
                        name.input.forceActiveFocus();
                    } else {
                        root.useDirectory(root.controller.acceptWorkspaceDirectory());
                    }
                }
            }

            Item {
                objectName: "workspaceFolderNotice"
                width: parent.width
                height: notice.implicitHeight + 2 * root.noticePadding
                visible: root.confirmCreate

                NativeRoundedRectangle {
                    anchors.fill: parent
                    color: root.colors.surface0
                    radius: root.noticeRadius
                }

                Column {
                    id: notice
                    x: root.noticePadding
                    y: root.noticePadding
                    width: parent.width - 2 * root.noticePadding

                    Caption {
                        text: "Folder does not exist"
                        color: root.colors.yellow
                        emphasized: true
                    }

                    Caption {
                        text: "Create it with this workspace."
                    }
                }
            }
        }

        Column {
            objectName: "workspaceFolders"
            width: parent.width
            spacing: root.labelGap
            visible: root.visibleRows > 0

            Caption {
                text: "Folders"
            }

            Item {
                width: parent.width
                height: root.visibleRows * root.rowHeight

                Repeater {
                    model: root.visibleRows
                    delegate: Item {
                        id: row

                        required property int index
                        readonly property int entry: root.firstRow + index
                        readonly property bool selected: entry === root.selection
                        objectName: "workspaceFolder"
                        y: index * root.rowHeight
                        width: parent.width - root.scrollbarWidth * 2
                        height: root.rowHeight

                        NativeRoundedRectangle {
                            anchors.fill: parent
                            color: row.selected ? root.colors.surface1 : root.colors.surface0
                            radius: root.rowRadius
                            visible: row.selected || pointer.containsMouse
                        }

                        ChromeIcon {
                            id: icon
                            x: root.rowInset
                            width: root.typography.body ?? 1
                            height: parent.height
                            glyph: ""
                            primaryFamily: root.typography.primaryFamily ?? ""
                            primaryStyle: root.typography.primaryStyle ?? ""
                            color: row.selected ? root.colors.accent : root.colors.subtext0
                            pixelSize: root.typography.body ?? 1
                        }

                        ChromeText {
                            x: icon.x + icon.width + root.iconGap
                            width: parent.width - x - root.rowInset
                            height: parent.height
                            text: root.entries[row.entry] ?? ""
                            color: row.selected ? root.colors.text : root.colors.subtext0
                            pixelSize: root.typography.body ?? 1
                        }

                        ActionPointer {
                            id: pointer
                            anchors.fill: parent
                            identity: "workspaceFolder:" + (root.entries[row.entry] ?? "")
                            onActivated: root.useDirectory(root.controller.chooseWorkspaceDirectory(row.entry))
                        }
                    }
                }

                NativeRoundedRectangle {
                    readonly property real unit: parent.height / Math.max(1, root.entries.length)
                    x: parent.width - root.scrollbarWidth
                    y: root.firstRow * unit
                    width: root.scrollbarWidth
                    height: root.visibleRows * unit
                    radius: root.scrollbarWidth / 2
                    color: root.colors.overlay0
                    visible: root.entries.length > root.maximumRows
                }
            }
        }

        PromptActions {
            width: parent.width
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            hint: "Tab completes  ·  Enter creates"
            submitText: root.confirmCreate ? "Create folder & workspace" : "Create workspace"
            submittable: root.submittable
            onSubmitted: root.submit()
            onCancelled: root.cancel()
        }
    }
}
