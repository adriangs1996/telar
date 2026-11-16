pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "palettePanel"

    required property var controller
    property real ratio: 1
    readonly property var colors: controller.colors
    readonly property var typography: controller.windowGeometry.typography
    readonly property var state: controller.paletteState
    readonly property var regions: controller.paletteGeometry
    readonly property int navigateMode: "@".charCodeAt(0)
    readonly property int actionsMode: ">".charCodeAt(0)
    readonly property int machinesMode: ":".charCodeAt(0)
    readonly property int suggestMode: "?".charCodeAt(0)
    readonly property bool suggesting: state.mode === suggestMode
    property string restoredEditorRevision: ""
    readonly property real detailAlpha: 0.65
    readonly property real groupInset: 10 * ratio
    readonly property real emptyInset: 20 * ratio
    readonly property real tabInset: 12 * ratio
    readonly property real tabRightInset: 8 * ratio
    readonly property real tabVerticalInset: 5 * ratio
    readonly property real tabGap: 4 * ratio
    readonly property real tabLabelPadding: 20 * ratio
    readonly property real headingAlpha: 0.75
    property alias queryField: query

    clip: true

    function submit(alternate = false) {
        if (root.suggesting) {
            root.controller.submitSuggestion(root.controller.suggestionState.revision);
        } else {
            choose(root.state.selectedKey ?? "", root.state.revision, alternate);
        }
    }

    function choose(key, revision, alternate = false) {
        const anchor = query.selectionStart === query.cursorPosition ? query.selectionEnd : query.selectionStart;
        root.controller.usePaletteResult({key: key, revision: revision, anchor: anchor, cursor: query.cursorPosition, alternate: alternate});
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
        function onPaletteChanged() {
            root.synchronizeEditor();
        }
    }

    Loader {
        anchors.fill: parent
        active: root.suggesting
        sourceComponent: SuggestionPanel {
            state: root.controller.suggestionState
            regions: root.controller.suggestionGeometry
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            onSubmitted: revision => root.controller.submitSuggestion(revision)
            onBackRequested: root.controller.execute(GuiController.Action.cancel)
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
        readonly property real closeWidth: Math.min(30 * root.ratio, width / 6)
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
            x: searchBand.inset + searchBand.iconWidth
            width: Math.max(0, closeButton.x - searchBand.closeGap - x)
            height: searchBand.height
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            maximumBytes: root.state.maximumQueryBytes
            placeholderPrefix: root.state.editorText.length > 0 && ["@", ">", ":", "?"].includes(root.state.editorText[0]) ? root.state.editorText[0] : ""
            placeholderText: root.state.mode === root.navigateMode ? "Search contexts, tabs and agents…" : root.state.mode === root.actionsMode ? "Search actions…" : root.state.mode === root.machinesMode ? "Search machines…" : "What would you like to do?"
            onTextEdited: root.controller.searchPalette(text)
            onLimitReached: requested => root.controller.reportPaletteQueryLimit(requested)
            Keys.onDownPressed: root.controller.movePalette(1)
            Keys.onUpPressed: root.controller.movePalette(-1)
            Keys.onReturnPressed: event => root.submit((event.modifiers & Qt.ShiftModifier) !== 0)
            Keys.onEnterPressed: event => root.submit((event.modifiers & Qt.ShiftModifier) !== 0)
            Keys.onPressed: event => {
                if (root.state.mode !== root.machinesMode || (event.modifiers & root.controller.controlModifier) === 0) {
                    event.accepted = false;
                    return;
                }
                const choice = {key: root.state.selectedKey ?? "", revision: root.state.revision};
                if (event.key === Qt.Key_R) {
                    root.controller.editMachineResult(choice, GuiController.MachineEditAction.rename);
                    event.accepted = true;
                } else if (event.key === Qt.Key_D) {
                    root.controller.editMachineResult(choice, GuiController.MachineEditAction.remove);
                    event.accepted = true;
                } else {
                    event.accepted = false;
                }
            }
            Keys.onEscapePressed: {
                if (!query.cancelComposition()) {
                    root.controller.execute(GuiController.Action.cancel);
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
            onActivated: root.controller.execute(GuiController.Action.cancel)
        }

        PaletteKeycap {
            anchors.fill: closeButton
            colors: root.colors
            typography: root.typography
            text: "esc"
            ratio: root.ratio
        }

        Rectangle {
            y: parent.height - height
            width: parent.width
            height: Math.min(root.ratio, parent.height)
            color: root.colors.surface1
        }
    }

    Loader {
        x: root.regions.tabs.x + root.tabInset
        y: root.regions.tabs.y + root.tabVerticalInset
        active: root.regions.tabs.height > 0
        sourceComponent: Row {
            spacing: root.tabGap

            Repeater {
                model: [{prefix: "@", label: "Navigate  @"}, {prefix: ">", label: "Actions  >"}, {prefix: ":", label: "Machines  :"}]
                delegate: Item {
                    id: modeTab
                    required property var modelData
                    readonly property real labelInset: 4 * root.ratio
                    width: Math.min(modeLabel.implicitWidth + root.tabLabelPadding, Math.max(0, root.regions.tabs.width - root.tabRightInset - root.tabInset - x))
                    height: Math.max(0, root.regions.tabs.height - root.tabVerticalInset * 2)

                    NativeRoundedRectangle {
                        anchors.fill: parent
                        radius: 5 * root.ratio
                        color: root.colors.surface0
                        visible: root.state.mode === modeTab.modelData.prefix.charCodeAt(0)
                    }

                    PaletteButton {
                        anchors.fill: parent
                        colors: root.colors
                        text: ""
                        accessibleLabel: modeTab.modelData.label
                        pixelSize: root.typography.small
                        ratio: root.ratio
                        onActivated: {
                            root.controller.setPaletteMode(modeTab.modelData.prefix.charCodeAt(0));
                            query.forceActiveFocus();
                        }
                    }

                    ChromeText {
                        id: modeLabel
                        x: modeTab.labelInset
                        y: modeTab.labelInset
                        width: Math.max(0, parent.width - modeTab.labelInset * 2)
                        height: Math.max(0, parent.height - modeTab.labelInset * 2)
                        text: modeTab.modelData.label
                        pixelSize: root.typography.small
                        color: root.colors.text
                    }
                }
            }
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

    Item {
        id: footerBand
        visible: !root.suggesting
        x: root.regions.footer.x
        y: root.regions.footer.y
        width: root.regions.footer.width
        height: root.regions.footer.height
        readonly property real inset: Math.min(14 * root.ratio, width / 8)
        readonly property real keyWidth: Math.min(22 * root.ratio, width / 10)
        readonly property real keyGap: 4 * root.ratio
        readonly property real labelGap: 14 * root.ratio
        readonly property real actionWidth: Math.min(112 * root.ratio, width / 2)
        readonly property real actionInset: 4 * root.ratio
        readonly property real captionMinimumWidth: 320 * root.ratio

        Rectangle {
            width: parent.width
            height: Math.min(root.ratio, parent.height)
            color: root.colors.surface1
        }

        PaletteKeycap {
            x: footerBand.inset
            width: footerBand.keyWidth
            height: footerBand.height
            colors: root.colors
            typography: root.typography
            text: "↑"
            ratio: root.ratio
        }

        PaletteKeycap {
            x: footerBand.inset + footerBand.keyWidth + footerBand.keyGap
            width: footerBand.keyWidth
            height: footerBand.height
            colors: root.colors
            typography: root.typography
            text: "↓"
            ratio: root.ratio
        }

        ChromeText {
            x: footerBand.inset + footerBand.keyWidth * 2 + footerBand.labelGap
            width: Math.max(0, footerBand.width - x - footerBand.actionWidth - footerBand.inset)
            height: footerBand.height
            text: root.state.mode === root.machinesMode ? "⇧↵ enable/disable · ^R rename · ^D remove" : "Navigate"
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, root.detailAlpha)
            visible: footerBand.width > footerBand.captionMinimumWidth
        }

        PaletteButton {
            x: footerBand.width - footerBand.actionWidth - footerBand.inset
            y: footerBand.actionInset
            width: footerBand.actionWidth
            height: Math.max(0, footerBand.height - footerBand.actionInset * 2)
            colors: root.colors
            text: root.state.mode === root.navigateMode ? "Open  ↵" : root.state.mode === root.actionsMode ? "Run  ↵" : "Show  ↵"
            pixelSize: root.typography.body
            ratio: root.ratio
            interactive: root.state.count > 0
            onActivated: root.submit()
        }
    }
}
