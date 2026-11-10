import Telar.Gui
import QtQuick
import QtQuick.Controls

Popup {
    id: root

    property real ratio: 1
    readonly property bool historyMode: telar.dialog === "history"
    readonly property bool pathMode: telar.dialog === "paths"
    readonly property bool machineMode: telar.dialog === "machine"
    readonly property bool peekMode: telar.dialog === "peek"
    readonly property bool customMode: historyMode || paletteMode || pathMode || machineMode || peekMode
    readonly property var activeSearch: peekMode ? (peekBrowser.item?.queryField ?? standardField) : machineMode ? (machineBrowser.item?.queryField ?? standardField) : pathMode ? (pathBrowser.item?.queryField ?? standardField) : historyMode ? historyQuery : paletteMode ? (paletteBrowser.item?.queryField ?? standardField) : standardField
    readonly property bool paletteMode: telar.dialog === "palette"
    // The focused pane's prompt line hosts the history and path searches; the history's
    // inspector still opens here, over it.
    readonly property bool islandHosted: telar.islandSearch.length > 0 && !(historyMode && telar.historyState.inspecting)
    readonly property bool listing: historyMode || paletteMode
    readonly property bool promptMode: telar.dialog.length > 0 && !customMode
    readonly property bool workspaceMode: telar.dialog === "new-workspace"
    readonly property var standardField: workspaceMode ? workspaceForm.field.input : prompt.field.input
    readonly property real dimmingAlpha: 0.25
    readonly property real historyEntranceOffset: Math.min(12 * root.ratio, Math.max(0, root.parent.height - historyBounds.y - historyBounds.height))
    readonly property real promptEntranceOffset: 10 * root.ratio
    readonly property real promptEntranceScale: 0.97
    readonly property real reveal: historyMode ? historyMotion.reveal : promptMode ? promptMotion.reveal : 1
    property int promptGeneration: 0

    ModalRevealLayout {
        id: historyMotion
        objectName: "historyModalMotion"
        active: root.historyMode
        generation: telar.historyState.generation ?? ""
    }

    // Each prompt rises into place as it opens, on the history modal's curve.
    ModalRevealLayout {
        id: promptMotion
        objectName: "promptModalMotion"
        active: root.promptMode
        generation: String(root.promptGeneration)
    }

    function activateResult(alternate) {
        if (historyMode) {
            if (!telar.historyLoading) {
                telar.useHistoryRow(telar.historyState.selection, alternate);
            }
        } else if (paletteMode) {
            paletteBrowser.item?.submit(alternate);
        }
    }

    function acceptKey(event) {
        if (!listing) {
            event.accepted = false;
            return;
        }

        if (historyMode && (event.modifiers & Qt.AltModifier) !== 0) {
            telar.executeHistory(GuiController.HistoryAction.visit);
        } else {
            activateResult((event.modifiers & Qt.ShiftModifier) !== 0);
        }
    }

    function moveSelection(delta) {
        if (historyMode) {
            historyBrowser.moveSelection(-delta);
        } else if (paletteMode) {
            telar.movePalette(delta);
        }
    }

    readonly property rect historyBounds: telar.historyGeometry.bounds
    readonly property rect paletteBounds: paletteMode ? telar.paletteGeometry.bounds : Qt.rect(0, 0, 0, 0)
    readonly property rect pathBounds: pathMode && telar.islandSearch.length === 0 ? telar.pathPickerGeometry.bounds : Qt.rect(0, 0, 0, 0)
    readonly property rect machineBounds: machineMode ? telar.machinePromptGeometry.bounds : Qt.rect(0, 0, 0, 0)
    readonly property rect peekBounds: peekMode ? telar.peekGeometry.bounds : Qt.rect(0, 0, 0, 0)
    x: peekMode ? peekBounds.x : machineMode ? machineBounds.x : pathMode ? pathBounds.x : historyMode ? historyBounds.x : paletteMode ? paletteBounds.x : (parent.width - width) / 2
    y: peekMode ? peekBounds.y : machineMode ? machineBounds.y : pathMode ? pathBounds.y : historyMode ? historyBounds.y + historyEntranceOffset * (1 - historyMotion.reveal) : paletteMode ? paletteBounds.y : (parent.height - height) / 2 + promptEntranceOffset * (1 - promptMotion.reveal)
    opacity: reveal
    scale: promptMode ? promptEntranceScale + (1 - promptEntranceScale) * promptMotion.reveal : 1
    width: peekMode ? peekBounds.width : machineMode ? machineBounds.width : pathMode ? pathBounds.width : historyMode ? historyBounds.width : paletteMode ? paletteBounds.width : Math.min(parent.width - 32, (workspaceMode ? 520 : 480) * ratio)
    height: peekMode ? peekBounds.height : machineMode ? machineBounds.height : pathMode ? pathBounds.height : historyMode ? historyBounds.height : paletteMode ? paletteBounds.height : contentItem.implicitHeight + topPadding + bottomPadding
    modal: true
    focus: true
    padding: customMode ? 0 : 22 * ratio
    closePolicy: customMode ? Popup.CloseOnPressOutside : Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onClosed: {
        if (telar.dialog.length > 0 && !root.islandHosted)
            telar.execute(GuiController.Action.cancel);
    }

    // The inspector opens and closes over the prompt line's search.
    onIslandHostedChanged: {
        if (telar.dialog.length === 0) {
            return;
        }

        if (root.islandHosted) {
            root.close();
        } else if (!root.opened) {
            root.open();
            root.activeSearch.forceActiveFocus();
        }
    }

    Overlay.modal: Rectangle {
        color: "black"
        opacity: root.pathMode || root.machineMode || root.peekMode ? 0 : root.dimmingAlpha * root.reveal
    }

    background: DialogSurface {
        colors: telar.colors
        ratio: root.ratio
    }

    Connections {
        target: telar
        function onDialogChanged() {
            if (telar.dialog.length > 0) {
                if (!root.paletteMode && !root.pathMode && !root.machineMode && !root.peekMode) {
                    root.activeSearch.text = "";
                }
                if (root.promptMode) {
                    root.promptGeneration += 1;
                }

                if (root.islandHosted) {
                    root.close();
                    return;
                }

                root.open();
                root.activeSearch.forceActiveFocus();
            } else {
                root.close();
            }
        }
        function onHistoryChanged() {
            if (!root.historyMode) {
                return;
            }

            const state = telar.historyState;
            if (historyQuery.text !== state.editorText) {
                historyQuery.text = state.editorText;
            }
            if (!state.inspecting && !telar.historyLoading && !root.islandHosted) {
                historyQuery.forceActiveFocus();
            }
        }
    }

    contentItem: Item {
        implicitHeight: root.workspaceMode ? workspaceForm.implicitHeight : prompt.implicitHeight

        Loader {
            id: peekBrowser
            anchors.fill: parent
            active: root.peekMode
            sourceComponent: PeekPanel {
                controller: telar
                ratio: root.ratio
            }
        }

        Loader {
            id: machineBrowser
            anchors.fill: parent
            active: root.machineMode
            sourceComponent: MachinePromptPanel {
                controller: telar
                ratio: root.ratio
            }
        }

        Loader {
            id: pathBrowser
            anchors.fill: parent
            active: root.pathMode && telar.islandSearch.length === 0
            sourceComponent: PathPickerPanel {
                controller: telar
                ratio: root.ratio
            }
        }

        Loader {
            id: paletteBrowser
            anchors.fill: parent
            active: root.paletteMode
            sourceComponent: PalettePanel {
                controller: telar
                ratio: root.ratio
            }
        }

        HistoryPanel {
            id: historyBrowser
            queryField: historyQuery
            anchors.fill: parent
            visible: root.historyMode
            controller: telar
            ratio: root.ratio
        }

        FormTextField {
            id: historyQuery
            objectName: root.historyMode ? "commandSearch" : "historyQueryInactive"
            parent: historyBrowser.searchHost
            anchors.fill: parent
            visible: root.historyMode
            colors: telar.colors
            typography: telar.windowGeometry.typography
            ratio: root.ratio
            maximumBytes: telar.historyState.maximumQueryBytes
            placeholderText: "Search commands"
            onTextEdited: telar.searchHistory(text)
            onLimitReached: requestedBytes => telar.reportHistoryQueryLimit(requestedBytes)
            Keys.onDownPressed: root.moveSelection(1)
            Keys.onUpPressed: root.moveSelection(-1)
            Keys.onReturnPressed: event => root.acceptKey(event)
            Keys.onEnterPressed: event => root.acceptKey(event)
            Keys.onEscapePressed: {
                if (!historyQuery.cancelComposition()) {
                    historyBrowser.cancelHistory();
                }
            }
            Keys.onPressed: event => {
                event.accepted = historyBrowser.handleKey(event);
            }
            Keys.onTabPressed: event => historyBrowser.cycleFilter(event)
            Keys.onBacktabPressed: event => historyBrowser.cycleFilter(event)
        }

        PromptPanel {
            id: prompt
            anchors.fill: parent
            visible: !root.customMode && !root.workspaceMode
            controller: telar
            ratio: root.ratio
        }

        WorkspaceFormPanel {
            id: workspaceForm
            anchors.fill: parent
            visible: root.workspaceMode
            controller: telar
            ratio: root.ratio
        }
    }
}
