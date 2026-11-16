pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "pathPickerPanel"

    required property PathPickerController controller
    required property var colors
    required property var typography
    // The platform's Control modifier, as an event modifier mask.
    required property int controlModifier
    property real ratio: 1
    readonly property var grid: typography.grid
    readonly property var state: controller.state
    readonly property var regions: controller.geometry
    // Escape on an empty composition, or Control+H: the window closes the search.
    signal cancelled()
    property alias queryField: query

    clip: true

    function synchronizeEditor() {
        if (query.text !== state.editorText) {
            query.text = state.editorText;
            query.cursorPosition = query.text.length;
        }
    }

    PathKeys {
        id: keys
        controller: root.controller
        controlModifier: root.controlModifier
        onCancelled: root.cancelled()
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
        x: root.regions.root.x
        y: root.regions.root.y
        width: root.regions.root.width
        height: root.regions.root.height
        text: root.state.rootLabel
        grid: root.grid
        color: root.colors.subtext0
        clip: true
    }

    FormTextField {
        id: query
        objectName: "commandSearch"
        x: root.regions.query.x
        y: root.regions.query.y
        width: root.regions.query.width
        height: root.regions.query.height
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        formControl: false
        maximumBytes: root.state.maximumQueryBytes
        Accessible.name: "Search paths"
        onTextEdited: root.controller.search(text)
        onLimitReached: requested => root.controller.reportQueryLimit(requested)
        Keys.onDownPressed: root.controller.move(1)
        Keys.onUpPressed: root.controller.move(-1)
        Keys.onReturnPressed: event => keys.submit(event)
        Keys.onEnterPressed: event => keys.submit(event)
        Keys.onTabPressed: root.controller.descend()
        Keys.onBacktabPressed: root.controller.ascend()
        Keys.onEscapePressed: {
            if (!query.cancelComposition()) {
                root.cancelled();
            }
        }
        Keys.onPressed: event => event.accepted = keys.handle(event)
    }

    CellText {
        x: root.regions.count.x
        y: root.regions.count.y
        width: root.regions.count.width
        height: root.regions.count.height
        text: root.state.countText
        grid: root.grid
        color: root.colors.subtext0
        clip: true
    }

    Repeater {
        model: root.regions.rows
        delegate: Item {
            id: row
            required property var modelData
            width: root.width
            height: root.height

            Rectangle {
                x: row.modelData.bounds.x
                y: row.modelData.bounds.y
                width: row.modelData.bounds.width
                height: row.modelData.bounds.height
                color: root.colors.surface1
                visible: row.modelData.selected
            }

            CellText {
                x: row.modelData.iconBounds.x
                y: row.modelData.iconBounds.y
                width: row.modelData.iconBounds.width
                height: row.modelData.iconBounds.height
                text: row.modelData.directory ? "\uf07b" : "\uf15b"
                grid: root.grid
                color: row.modelData.directory ? root.colors.blue : root.colors.subtext0
            }

            Repeater {
                model: row.modelData.runs
                delegate: CellText {
                    required property var modelData
                    x: modelData.bounds.x
                    y: modelData.bounds.y
                    width: modelData.bounds.width
                    height: modelData.bounds.height
                    text: modelData.text
                    grid: root.grid
                    color: root.colors[modelData.colorRole]
                    bold: modelData.bold
                    clip: true
                }
            }

            ActionPointer {
                x: row.modelData.bounds.x
                y: row.modelData.bounds.y
                width: row.modelData.bounds.width
                height: row.modelData.bounds.height
                identity: root.state.revision + ":" + row.modelData.path
                onActivated: root.controller.activate({path: row.modelData.path, revision: root.state.revision, absolute: false})
            }
        }
    }

    ChromeText {
        x: root.regions.empty.x
        y: root.regions.empty.y
        width: root.regions.empty.width
        height: root.regions.empty.height
        text: root.state.emptyText
        pixelSize: root.typography.body
        color: root.colors.subtext0
        elide: Text.ElideNone
        visible: root.state.count === 0
    }

    ChromeText {
        x: root.regions.footer.x
        y: root.regions.footer.y
        width: root.regions.footer.width
        height: root.regions.footer.height
        text: root.state.status
        pixelSize: root.typography.body
        color: root.state.failed ? root.colors.red : root.colors.subtext0
        elide: Text.ElideNone
    }

    Repeater {
        model: root.regions.hints
        delegate: Item {
            id: hint
            required property var modelData
            width: root.width
            height: root.height

            CellText {
                x: hint.modelData.keyBounds.x
                y: hint.modelData.keyBounds.y
                width: hint.modelData.keyBounds.width
                height: hint.modelData.keyBounds.height
                text: hint.modelData.key
                grid: root.grid
                color: root.colors.text
            }

            ChromeText {
                x: hint.modelData.wordBounds.x
                y: hint.modelData.wordBounds.y
                width: hint.modelData.wordBounds.width
                height: hint.modelData.wordBounds.height
                text: hint.modelData.word
                pixelSize: root.typography.body
                color: root.colors.subtext0
                elide: Text.ElideNone
            }
        }
    }
}
