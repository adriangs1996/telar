import Telar.Gui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: root

    property real ratio: 1
    readonly property bool historyMode: telar.dialog === "history"
    readonly property bool pathMode: telar.dialog === "paths"
    readonly property bool machineMode: telar.dialog === "machine"
    readonly property bool peekMode: telar.dialog === "peek"
    readonly property bool customMode: historyMode || paletteMode || pathMode || machineMode || peekMode
    readonly property var activeSearch: peekMode ? (peekBrowser.item?.queryField ?? search) : machineMode ? (machineBrowser.item?.queryField ?? search) : pathMode ? (pathBrowser.item?.queryField ?? search) : historyMode ? historyQuery : paletteMode ? (paletteBrowser.item?.queryField ?? search) : search
    readonly property bool paletteMode: telar.dialog === "palette"
    readonly property bool workspaceMode: telar.dialog === "new-workspace"
    readonly property bool copySearchMode: telar.dialog === "copy-search"
    readonly property bool listing: historyMode || paletteMode
    readonly property real dimmingAlpha: 0.25

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
    readonly property rect pathBounds: pathMode ? telar.pathPickerGeometry.bounds : Qt.rect(0, 0, 0, 0)
    readonly property rect machineBounds: machineMode ? telar.machinePromptGeometry.bounds : Qt.rect(0, 0, 0, 0)
    readonly property rect peekBounds: peekMode ? telar.peekGeometry.bounds : Qt.rect(0, 0, 0, 0)
    x: peekMode ? peekBounds.x : machineMode ? machineBounds.x : pathMode ? pathBounds.x : historyMode ? historyBounds.x : paletteMode ? paletteBounds.x : (parent.width - width) / 2
    y: peekMode ? peekBounds.y : machineMode ? machineBounds.y : pathMode ? pathBounds.y : historyMode ? historyBounds.y : paletteMode ? paletteBounds.y : (parent.height - height) / 2
    width: peekMode ? peekBounds.width : machineMode ? machineBounds.width : pathMode ? pathBounds.width : historyMode ? historyBounds.width : paletteMode ? paletteBounds.width : Math.min(parent.width - 32, 640 * ratio)
    height: peekMode ? peekBounds.height : machineMode ? machineBounds.height : pathMode ? pathBounds.height : historyMode ? historyBounds.height : paletteMode ? paletteBounds.height : contentItem.implicitHeight + topPadding + bottomPadding
    modal: true
    focus: true
    padding: customMode ? 0 : 20 * ratio
    closePolicy: customMode ? Popup.CloseOnPressOutside : Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onClosed: {
        if (telar.dialog.length > 0)
            telar.execute(GuiController.Action.cancel);
    }

    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, root.pathMode || root.machineMode || root.peekMode ? 0 : root.dimmingAlpha)
    }

    background: Loader {
        sourceComponent: root.machineMode || root.peekMode ? machineSurface : root.pathMode ? pathSurface : root.historyMode || root.paletteMode ? historySurface : standardSurface
    }

    Component {
        id: machineSurface
        Rectangle {
            color: telar.colors.panel_bg
            border.color: telar.colors.accent
            border.width: 1 / Screen.devicePixelRatio
        }
    }

    Component {
        id: pathSurface
        Item {
            readonly property real cornerRadius: 8 * root.ratio

            NativeRoundedRectangle {
                anchors.fill: parent
                color: telar.colors.surface0
                radius: parent.cornerRadius
            }

            NativeRoundedRectangle {
                anchors.fill: parent
                color: "transparent"
                borderColor: telar.colors.surface1
                borderWidth: root.ratio
                radius: parent.cornerRadius
            }
        }
    }

    Component {
        id: historySurface
        DialogSurface {
            colors: telar.colors
            ratio: root.ratio
        }
    }

    Component {
        id: standardSurface
        Rectangle {
            color: telar.colors.surface
            border.color: telar.colors.elevated
            radius: 10 * root.ratio
        }
    }

    Connections {
        target: telar
        function onDialogChanged() {
            if (telar.dialog.length > 0) {
                if (!root.paletteMode && !root.pathMode && !root.machineMode && !root.peekMode) {
                    root.activeSearch.text = "";
                }
                directory.text = "";
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
            if (!state.inspecting && !telar.historyLoading) {
                historyQuery.forceActiveFocus();
            }
        }
    }

    contentItem: Item {
        implicitHeight: standardContent.implicitHeight

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
            active: root.pathMode
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

        ColumnLayout {
            id: standardContent
            anchors.fill: parent
            visible: !root.customMode
            spacing: 16 * root.ratio

            Label {
                textFormat: Text.PlainText
                text: root.copySearchMode ? "Search scrollback" : root.historyMode ? "Command history" : root.paletteMode ? "Commands" : root.workspaceMode ? "New workspace" : telar.dialog === "rename-tab" ? "Rename tab" : "Rename workspace"
                color: telar.colors.foreground
                font.pixelSize: 18 * root.ratio * telar.chromeTextScale
                font.weight: Font.DemiBold
            }

            TextField {
                id: search
                objectName: root.historyMode || root.paletteMode ? "standardCommandSearch" : "commandSearch"
                parent: standardContent

                Layout.fillWidth: true
                placeholderText: root.copySearchMode ? "Search scrollback" : root.historyMode ? "Search commands" : root.listing ? "Search…" : "Name"
                color: telar.colors.foreground
                selectionColor: telar.colors.accent
                font.pixelSize: 14 * root.ratio * telar.chromeTextScale
                Accessible.name: placeholderText
                background: Rectangle {
                    visible: !root.historyMode
                    color: telar.colors.background
                    border.color: search.activeFocus ? telar.colors.accent : telar.colors.elevated
                    radius: 5 * root.ratio
                }

                onTextEdited: {
                    if (root.historyMode) {
                        telar.searchHistory(text);
                    }
                }
                onAccepted: {
                    if (!root.listing && text.trim().length > 0)
                        telar.submitDialog({text: text, path: directory.text});
                }
                Keys.onDownPressed: root.moveSelection(1)
                Keys.onUpPressed: root.moveSelection(-1)
                Keys.onReturnPressed: event => root.acceptKey(event)
                Keys.onEnterPressed: event => root.acceptKey(event)
                Keys.onEscapePressed: {
                    if (root.historyMode) {
                        historyBrowser.cancelHistory();
                    } else {
                        telar.execute(GuiController.Action.cancel);
                    }
                }
                Keys.onPressed: event => {
                    event.accepted = root.historyMode && historyBrowser.handleKey(event);
                }
                Keys.onTabPressed: event => {
                    if (root.historyMode) {
                        historyBrowser.cycleFilter(event);
                    } else {
                        event.accepted = false;
                    }
                }
                Keys.onBacktabPressed: event => {
                    if (root.historyMode) {
                        historyBrowser.cycleFilter(event);
                    } else {
                        event.accepted = false;
                    }
                }
            }

            TextField {
                id: directory

                Layout.fillWidth: true
                visible: root.workspaceMode
                placeholderText: "Directory"
                color: telar.colors.foreground
                font.pixelSize: 14 * root.ratio * telar.chromeTextScale
                Accessible.name: "Workspace directory"
                onAccepted: {
                    if (search.text.trim().length > 0)
                        telar.submitDialog({text: search.text, path: text});
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                visible: !root.listing

                Button {
                    text: "Cancel"
                    onClicked: telar.execute(GuiController.Action.cancel)
                }

                Button {
                    text: root.workspaceMode ? "Create workspace" : "Rename"
                    enabled: search.text.trim().length > 0
                    onClicked: telar.submitDialog({text: search.text, path: directory.text})
                }
            }
        }
    }
}
