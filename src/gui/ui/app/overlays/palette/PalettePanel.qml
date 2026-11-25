pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "palettePanel"

    required property PaletteController controller
    required property var colors
    required property var typography
    // The platform's Control modifier, as an event modifier mask.
    required property int controlModifier
    property real ratio: 1
    readonly property var state: controller.state
    readonly property var regions: controller.geometry
    readonly property int allMode: 0
    readonly property int navigateMode: "@".charCodeAt(0)
    readonly property int actionsMode: ">".charCodeAt(0)
    readonly property int machinesMode: ":".charCodeAt(0)
    readonly property int suggestMode: "?".charCodeAt(0)
    readonly property bool suggesting: state.mode === suggestMode
    readonly property string selectedKind: state.selectedKind ?? ""
    property string restoredEditorRevision: ""
    readonly property real detailAlpha: 0.65
    // Content starts 16 px in: the list band is inset 8 px and its rows another 8.
    readonly property real groupInset: 8 * ratio
    readonly property real emptyInset: 16 * ratio
    readonly property real headingAlpha: 0.75
    readonly property var footerHints: {
        const hints = [{keys: ["↑", "↓"], word: "Navigate", action: ""}];
        if (root.state.count === 0) {
            return hints;
        }

        if (root.selectedKind === "machine") {
            return hints.concat([{keys: ["↵"], word: "Show", action: "submit"}, {keys: ["⇧", "↵"], word: "Enable/disable", action: "alternate"}, {keys: ["^R"], word: "Rename", action: ""}, {keys: ["^D"], word: "Remove", action: ""}]);
        }

        const word = root.selectedKind === "action" ? "Run" : root.selectedKind === "suggestion" ? "Suggest" : "Open";
        return hints.concat([{keys: ["↵"], word: word, action: "submit"}]);
    }
    property alias queryField: query
    // Escape on an empty composition, or back from a suggestion: the window closes the palette.
    signal cancelled()
    // Control+R or Control+D on a machine: the window renames or removes it.
    signal machineEdited(var choice, int action)

    clip: true

    function submit(alternate = false) {
        if (root.suggesting) {
            root.controller.submitSuggestion(root.controller.suggestion.revision);
        } else {
            choose(root.state.selectedKey ?? "", root.state.revision, alternate);
        }
    }

    function choose(key, revision, alternate = false) {
        const anchor = query.selectionStart === query.cursorPosition ? query.selectionEnd : query.selectionStart;
        root.controller.activate({key: key, revision: revision, anchor: anchor, cursor: query.cursorPosition, alternate: alternate});
    }

    function synchronizeEditor() {
        if (query.text !== root.state.editorText) {
            query.text = root.state.editorText;
            query.cursorPosition = query.text.length;
        }

        const revision = root.state.editorRestoreRevision ?? "";
        if (revision !== restoredEditorRevision) {
            restoredEditorRevision = revision;
            if (revision.length > 0) {
                query.select(root.state.editorAnchor, root.state.editorCursor);
            }
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

    Loader {
        anchors.fill: parent
        active: root.suggesting
        sourceComponent: SuggestionPanel {
            state: root.controller.suggestion
            regions: root.controller.suggestionGeometry
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            onSubmitted: revision => root.controller.submitSuggestion(revision)
            onBackRequested: root.cancelled()
        }
    }

    Item {
        id: searchBand
        x: root.regions.search.x
        y: root.regions.search.y
        width: root.regions.search.width
        height: root.regions.search.height

        readonly property real inset: Math.min(16 * root.ratio, width / 8)
        readonly property real iconWidth: Math.min(18 * root.ratio, width / 8)
        readonly property real iconGap: 8 * root.ratio
        readonly property real closeWidth: Math.min(closeKeycap.implicitWidth, width / 4)
        readonly property real closeGap: 8 * root.ratio

        ChromeIcon {
            x: searchBand.inset
            width: searchBand.iconWidth
            height: searchBand.height
            glyph: "\uf002"
            pixelSize: root.typography.body
            color: Qt.alpha(root.colors.text, root.detailAlpha)
        }

        FormTextField {
            id: query
            objectName: "commandSearch"
            x: searchBand.inset + searchBand.iconWidth + searchBand.iconGap
            width: Math.max(0, closeButton.x - searchBand.closeGap - x)
            height: searchBand.height
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            maximumBytes: root.state.maximumQueryBytes
            placeholderPrefix: root.state.editorText.length > 0 && ["@", ">", ":", "?"].includes(root.state.editorText[0]) ? root.state.editorText[0] : ""
            placeholderText: root.state.mode === root.allMode ? "Search contexts, tabs, agents and actions…" : root.state.mode === root.navigateMode ? "Search contexts, tabs and agents…" : root.state.mode === root.actionsMode ? "Search actions…" : root.state.mode === root.machinesMode ? "Search machines…" : "What would you like to do?"
            onTextEdited: root.controller.search(text)
            onLimitReached: requested => root.controller.reportQueryLimit(requested)
            Keys.onDownPressed: root.controller.move(1)
            Keys.onUpPressed: root.controller.move(-1)
            Keys.onReturnPressed: event => root.submit((event.modifiers & Qt.ShiftModifier) !== 0)
            Keys.onEnterPressed: event => root.submit((event.modifiers & Qt.ShiftModifier) !== 0)
            Keys.onPressed: event => {
                if (root.selectedKind !== "machine" || (event.modifiers & root.controlModifier) === 0) {
                    event.accepted = false;
                    return;
                }
                const choice = {key: root.state.selectedKey ?? "", revision: root.state.revision};
                if (event.key === Qt.Key_R) {
                    root.machineEdited(choice, WindowActions.MachineEditAction.rename);
                    event.accepted = true;
                } else if (event.key === Qt.Key_D) {
                    root.machineEdited(choice, WindowActions.MachineEditAction.remove);
                    event.accepted = true;
                } else {
                    event.accepted = false;
                }
            }
            Keys.onEscapePressed: {
                if (!query.cancelComposition()) {
                    root.cancelled();
                }
            }
        }

        PaletteButton {
            id: closeButton
            x: searchBand.width - searchBand.inset - searchBand.closeWidth
            width: searchBand.closeWidth
            height: searchBand.height
            text: ""
            accessibleLabel: "Close palette"
            colors: root.colors
            pixelSize: root.typography.body
            ratio: root.ratio
            onActivated: root.cancelled()
        }

        PaletteKeycap {
            id: closeKeycap
            anchors.fill: closeButton
            colors: root.colors
            typography: root.typography
            text: "esc"
            ratio: root.ratio
        }

        Rectangle {
            y: parent.height - height
            width: parent.width
            height: Math.min(1, parent.height)
            color: root.colors.surface1
        }
    }

    Item {
        x: root.regions.results.x
        y: root.regions.results.y
        width: root.regions.results.width
        height: root.regions.results.height
        clip: true
        visible: !root.suggesting

        ChromeText {
            x: root.emptyInset
            y: root.emptyInset
            width: Math.max(0, parent.width - root.emptyInset * 2)
            height: Math.max(0, parent.height - root.emptyInset * 2)
            text: "No results. Try another search."
            pixelSize: root.typography.body
            color: Qt.alpha(root.colors.text, root.headingAlpha)
            visible: root.state.count === 0
        }
    }

    Repeater {
        model: root.regions.rows
        delegate: Item {
            id: result
            required property var modelData
            width: root.width
            height: root.height

            ChromeText {
                x: result.modelData.groupBounds.x + root.groupInset
                y: result.modelData.groupBounds.y
                width: Math.max(0, result.modelData.groupBounds.width - root.groupInset * 2)
                height: result.modelData.groupBounds.height
                text: result.modelData.groupLabel
                pixelSize: root.typography.small
                emphasized: true
                color: Qt.alpha(root.colors.text, root.detailAlpha)
                visible: height > 0
            }

            PaletteRow {
                x: result.modelData.bounds.x
                y: result.modelData.bounds.y
                width: result.modelData.bounds.width
                height: result.modelData.bounds.height
                record: result.modelData
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                revision: root.state.revision
                selected: result.modelData.selected
                onActivated: (key, revision) => root.choose(key, revision)
            }
        }
    }

    KeyHintBar {
        id: footerBand
        visible: !root.suggesting
        x: root.regions.footer.x
        y: root.regions.footer.y
        width: root.regions.footer.width
        height: root.regions.footer.height
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        hints: root.footerHints
        trailing: root.state.mode === root.allMode ? {keys: [">", "@", ":"], word: "Filter"} : null
        onActivated: action => root.submit(action === "alternate")
    }
}
