pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick
import QtQuick.Controls

Item {
    id: root
    objectName: "historyPanel"

    property real ratio: 1
    readonly property var browserState: root.controller.historyState
    readonly property bool actionable: !root.controller.historyLoading && root.browserState.phase === "ready" && root.browserState.count > 0
    readonly property real resultBottomInset: 6 * ratio
    readonly property real searchPadding: historySearch.fieldPadding
    required property var controller
    property var queryField: null
    readonly property var regions: controller.historyGeometry
    property alias searchHost: historySearch.fieldHost
    property alias rowsView: results
    property bool retiringRows: false

    function restoreRows() {
        root.retiringRows = false;
    }

    function revealSelection() {
        if (root.actionable) {
            results.forceLayout();
            results.positionViewAtIndex(root.browserState.selection, ListView.Contain);
        }
    }

    function moveSelection(delta) {
        if (!actionable) {
            return;
        }

        const selected = root.browserState.selection + delta;
        if (selected >= root.browserState.count && root.browserState.canOlder) {
            root.controller.executeHistory(GuiController.HistoryAction.older);
        } else if (selected < 0 && root.browserState.canNewer) {
            root.controller.executeHistory(GuiController.HistoryAction.newer);
        } else {
            root.controller.selectHistoryRow(Math.max(0, Math.min(root.browserState.count - 1, selected)));
        }
    }

    function cycleScope() {
        const scopes = ["global", "workspace", "cwd", "pane"];
        const next = (scopes.indexOf(root.browserState.scope) + 1) % scopes.length;
        root.controller.setHistoryFilters({scope: scopes[next]});
    }

    function cycleAuthor() {
        const authors = ["human", "agent", "all"];
        const next = (authors.indexOf(root.browserState.author) + 1) % authors.length;
        root.controller.setHistoryFilters({author: authors[next]});
    }

    function cycleFilter(event) {
        if (event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) !== 0) {
            root.cycleAuthor();
        } else {
            root.cycleScope();
        }
    }

    function cancelHistory() {
        if (root.browserState.inspecting) {
            root.controller.executeHistory(GuiController.HistoryAction.inspect);
        } else {
            root.controller.execute(GuiController.Action.cancel);
        }
    }

    function submit(event) {
        if ((event.modifiers & Qt.AltModifier) !== 0) {
            root.controller.executeHistory(GuiController.HistoryAction.visit);
        } else {
            root.controller.useHistoryRow(root.browserState.selection, (event.modifiers & Qt.ShiftModifier) !== 0);
        }
    }

    function pageKey(older) {
        if (!root.browserState.inspecting) {
            root.controller.executeHistory(older ? GuiController.HistoryAction.older : GuiController.HistoryAction.newer);
            return;
        }

        const view = inspector.item as HistoryInspector;
        view?.page(older);
    }

    function handleKey(event) {
        if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
            pageKey(event.key === Qt.Key_PageUp);
            return true;
        }

        const control = (event.modifiers & root.controller.controlModifier) !== 0;
        const command = (event.modifiers & root.controller.superModifier) !== 0;
        if (command && event.key === Qt.Key_Backspace) {
            root.controller.executeHistory(GuiController.HistoryAction.erase);
            return true;
        }

        if ((control || command) && event.key === Qt.Key_C) {
            if (root.queryField && root.queryField.selectionStart !== root.queryField.selectionEnd) {
                root.queryField.copy();
            } else {
                root.controller.executeHistory(GuiController.HistoryAction.copy);
            }

            return true;
        }

        if (!control || (event.modifiers & Qt.AltModifier) !== 0) {
            return false;
        }

        switch (event.key) {
        case Qt.Key_D:
            root.controller.executeHistory(GuiController.HistoryAction.erase);
            return true;
        case Qt.Key_O:
            root.controller.executeHistory(GuiController.HistoryAction.inspect);
            return true;
        case Qt.Key_H:
            if (command || (event.modifiers & Qt.ShiftModifier) !== 0) {
                return false;
            }

            cancelHistory();
            return true;
        case Qt.Key_L:
            if (command || (event.modifiers & Qt.ShiftModifier) !== 0) {
                return false;
            }

            root.controller.useHistoryRow(root.browserState.selection);
            return true;
        case Qt.Key_J:
            moveSelection(-1);
            return true;
        case Qt.Key_K:
            moveSelection(1);
            return true;
        default:
            return false;
        }
    }

    Keys.onPressed: event => event.accepted = root.handleKey(event)
    Keys.onReturnPressed: event => root.submit(event)
    Keys.onEnterPressed: event => root.submit(event)
    Keys.onEscapePressed: root.cancelHistory()
    Keys.onUpPressed: root.moveSelection(1)
    Keys.onDownPressed: root.moveSelection(-1)

    HistoryFilters {
        x: root.regions.header.x
        y: root.regions.header.y
        width: root.regions.header.width
        height: root.regions.header.height
        visible: height > 0
        clip: true
        ratio: root.ratio
        density: root.regions.density
        state: root.browserState
        colors: root.controller.colors
        grid: root.controller.windowGeometry.typography.grid
        pixelSize: root.controller.windowGeometry.typography.small
        onScopeSelected: scope => root.controller.setHistoryFilters({scope: scope})
        onAuthorSelected: author => root.controller.setHistoryFilters({author: author})
        onFailedToggled: root.controller.setHistoryFilters({failedOnly: !root.browserState.failedOnly})
    }

    Item {
        x: root.regions.results.x
        y: root.regions.results.y
        width: root.width - x
        height: root.regions.results.height

        ListView {
            id: results
            objectName: "historyResults"

            x: 0
            y: 0
            width: root.regions.results.width
            height: Math.max(0, parent.height - root.resultBottomInset)
            visible: width > 0
            clip: true
            spacing: 0
            model: root.retiringRows ? null : root.controller.history
            opacity: historySearch.rowsOpacity
            verticalLayoutDirection: ListView.BottomToTop
            currentIndex: root.browserState.selection
            ScrollBar.vertical: ScrollBar {}

            delegate: Item {
                id: result
                objectName: "historyResult"

                required property int index
                required property var record
                readonly property bool selected: results.currentIndex === index
                readonly property bool expanded: selected && !root.browserState.inspecting
                readonly property real headingHeight: root.browserState.grouped && record.groupEnds ? root.regions.groupHeight : 0
                width: results.width
                height: headingHeight + commandRow.implicitHeight

                ChromeText {
                    objectName: "historyDayHeading"
                    x: 18 * root.ratio
                    width: Math.max(0, parent.width - 2 * x)
                    height: result.headingHeight
                    visible: height > 0
                    text: result.record.dayLabel.toUpperCase()
                    color: root.controller.colors.subtext0
                    pixelSize: root.controller.windowGeometry.typography.small
                    emphasized: true
                    elide: Text.ElideNone
                }

                HistoryRow {
                    id: commandRow
                    y: result.headingHeight
                    width: result.width
                    height: result.height - y
                    record: result.record
                    commandText: result.selected ? root.controller.historyCommand : result.record.command
                    query: root.browserState.query
                    commandLoaded: !result.selected || root.browserState.commandLoaded
                    inspectionKey: root.browserState.inspectionKey
                    macStyle: root.browserState.macStyle
                    paneOpen: result.selected && root.browserState.paneOpen
                    viewportHeight: root.regions.results.height
                    colors: root.controller.colors
                    typography: root.controller.windowGeometry.typography
                    rowHeight: root.regions.rowHeight
                    ratio: root.ratio
                    selected: result.selected
                    expanded: result.expanded
                    grouped: root.browserState.grouped
                    showCwd: root.browserState.effectiveScope === "global" || root.browserState.effectiveScope === "workspace"
                    interactive: root.actionable
                    actionController: root.controller
                    revision: root.browserState.revision
                    onActivated: revision => root.controller.selectPresentedHistoryRow(result.index, revision)
                    onActionTriggered: action => {
                        const actions = {copy: GuiController.HistoryAction.copy, erase: GuiController.HistoryAction.erase, visit: GuiController.HistoryAction.visit};
                        root.controller.executeHistory(actions[action], result.record.key);
                    }
                    onImplicitHeightChanged: {
                        if (result.selected) {
                            Qt.callLater(root.revealSelection);
                        }
                    }
                }
            }
        }

        Loader {
            id: inspector
            x: root.regions.inspection.x - parent.x
            y: root.regions.inspection.y - parent.y
            width: root.regions.inspection.width
            height: root.regions.inspection.height
            active: root.browserState.inspecting && root.browserState.count > 0
            sourceComponent: HistoryInspector {
                details: root.controller.historyInspection
                browserState: root.browserState
                colors: root.controller.colors
                typography: root.controller.windowGeometry.typography
                command: root.controller.historyCommand
                output: root.controller.historyOutput
                ratio: root.ratio
                density: root.regions.density
                split: root.regions.results.width > 0
                interactive: root.actionable
                onActionTriggered: (action, revision) => {
                    switch (action) {
                    case "submit":
                        root.controller.usePresentedHistory(revision);
                        break;
                    case "alternate":
                        root.controller.usePresentedHistory(revision, true);
                        break;
                    default:
                        const actions = {copy: GuiController.HistoryAction.copy, erase: GuiController.HistoryAction.erase, visit: GuiController.HistoryAction.visit};
                        root.controller.executeHistory(actions[action], root.controller.historyInspection.identity);
                        break;
                    }
                }
            }
        }

        Loader {
            x: -parent.x
            y: -parent.y
            width: root.width
            height: root.height
            active: root.browserState.count === 0
            clip: true
            sourceComponent: Item {
                HistoryEmpty {
                    readonly property var area: root.regions.results.width > 0 ? root.regions.results : root.regions.inspection
                    x: area.x
                    y: area.y
                    width: area.width
                    height: area.height
                    state: root.browserState
                    colors: root.controller.colors
                    typography: root.controller.windowGeometry.typography
                    workspace: root.controller.workspaceContext?.name ?? ""
                    ratio: root.ratio
                    onSearchEverywhere: root.controller.setHistoryFilters({scope: "global"})
                }
            }
        }
    }

    HistoryFooter {
        x: root.regions.footer.x
        y: root.regions.footer.y
        width: root.regions.footer.width
        height: root.regions.footer.height
        state: root.browserState
        colors: root.controller.colors
        pixelSize: root.controller.windowGeometry.typography.small
        ratio: root.ratio
        interactive: root.actionable
        onActionTriggered: (action, revision) => {
            switch (action) {
            case "submit":
                root.controller.usePresentedHistory(revision);
                break;
            case "alternate":
                root.controller.usePresentedHistory(revision, true);
                break;
            case "inspect":
                root.controller.executeHistory(GuiController.HistoryAction.inspect);
                break;
            case "visit":
                root.controller.executeHistory(GuiController.HistoryAction.visit);
                break;
            }
        }
    }

    HistorySearchBar {
        id: historySearch
        colors: root.controller.colors
        typography: root.controller.windowGeometry.typography
        ratio: root.ratio
        density: root.regions.density
        inspecting: root.browserState.inspecting
        replacing: root.browserState.phase === "loading" && root.browserState.hasPage === true
        onCancelled: root.cancelHistory()
        x: root.regions.search.x
        y: root.regions.search.y
        width: root.regions.search.width
        height: root.regions.search.height
    }

    Connections {
        target: root.controller.history
        function onRowsAboutToBeRemoved() {
            root.retiringRows = true;
        }
        function onRowsRemoved() {
            Qt.callLater(root.restoreRows);
        }
    }

    Connections {
        target: root.controller
        function onHistoryInspectionScrolled(lines) {
            const view = inspector.item as HistoryInspector;
            if (view) {
                view.scroll += lines;
            }
        }

        function onHistoryChanged() {
            Qt.callLater(root.revealSelection);
        }
    }

    Component.onCompleted: root.controller.registerHistoryPanel(root)
}
