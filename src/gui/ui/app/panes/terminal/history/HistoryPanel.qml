pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick
import QtQuick.Controls

Item {
    id: root
    objectName: "historyPanel"

    property real ratio: 1
    readonly property var browserState: root.controller.state
    readonly property bool actionable: !root.controller.loading && root.browserState.phase === "ready" && root.browserState.count > 0
    readonly property real resultBottomInset: 6 * ratio
    required property HistoryController controller
    required property var colors
    required property var typography
    // The workspace the "search everywhere" hint names.
    property string workspaceName: ""
    // The platform's Control and Command modifiers, as event modifier masks.
    required property int controlModifier
    required property int superModifier
    property var queryField: null
    readonly property var regions: controller.geometry
    // Escape or Control+H outside the inspector: the window closes the search.
    signal cancelled()
    property alias searchHost: historySearch.fieldHost
    property alias rowsView: results
    property bool retiringRows: false

    ModalRevealLayout {
        id: inspectorMotion
        objectName: "historyInspectorMotion"
        active: root.visible && root.browserState.inspecting
        generation: root.browserState.generation ?? ""
    }

    HistorySelectionLayout {
        id: selectionMotion
        selection: ({
            active: root.visible && !root.browserState.inspecting && root.browserState.count > 0,
            generation: root.browserState.generation ?? "",
            id: root.browserState.selectedId ?? "",
            index: root.browserState.selection
        })
    }

    function restoreRows() {
        root.retiringRows = false;
    }

    function revealSelection() {
        if (root.actionable) {
            results.forceLayout();
            results.positionViewAtIndex(root.browserState.selection, ListView.Contain);
        }
    }

    HistoryKeys {
        id: keys
        controller: root.controller
        controlModifier: root.controlModifier
        superModifier: root.superModifier
        queryField: root.queryField
        onCancelled: root.cancelled()
        pageInspector: older => (inspector.item as HistoryInspector)?.page(older)
    }

    function moveSelection(delta) {
        keys.moveSelection(delta);
    }

    function cycleFilter(event) {
        keys.cycleFilter(event);
    }

    function cancelHistory() {
        keys.cancel();
    }

    function handleKey(event) {
        return keys.handle(event);
    }

    Keys.onPressed: event => event.accepted = root.handleKey(event)
    Keys.onReturnPressed: event => keys.submit(event)
    Keys.onEnterPressed: event => keys.submit(event)
    Keys.onEscapePressed: root.cancelHistory()
    Keys.onUpPressed: root.moveSelection(1)
    Keys.onDownPressed: root.moveSelection(-1)

    HistoryFilters {
        controller: root.controller
        x: root.regions.header.x
        y: root.regions.header.y
        width: root.regions.header.width
        height: root.regions.header.height
        visible: height > 0
        clip: true
        ratio: root.ratio
        density: root.regions.density
        state: root.browserState
        colors: root.colors
        grid: root.typography.grid
        pixelSize: root.typography.small
        onScopeSelected: scope => root.controller.setFilters({scope: scope})
        onAuthorSelected: author => root.controller.setFilters({author: author})
        onFailedToggled: root.controller.setFilters({failedOnly: !root.browserState.failedOnly})
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
            model: root.retiringRows ? null : root.controller.rows
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
                readonly property bool leaving: !selected && selectionMotion.leavingIndex === index && selectionMotion.leavingKey === record.key
                readonly property real open: root.browserState.inspecting ? 0 : (selected ? selectionMotion.selectedOpen : (leaving ? selectionMotion.leavingOpen : 0))
                readonly property real highlight: selected ? 1 : (leaving ? selectionMotion.leavingOpen : 0)
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
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    emphasized: true
                    elide: Text.ElideNone
                }

                HistoryRow {
                    id: commandRow
                    y: result.headingHeight
                    width: result.width
                    height: result.height - y
                    record: result.record
                    commandText: result.selected ? root.controller.command : result.record.command
                    query: root.browserState.query
                    commandLoaded: !result.selected || root.browserState.commandLoaded
                    inspectionKey: root.browserState.inspectionKey
                    macStyle: root.browserState.macStyle
                    paneOpen: result.selected && root.browserState.paneOpen
                    viewportHeight: root.regions.results.height
                    colors: root.colors
                    typography: root.typography
                    rowHeight: root.regions.rowHeight
                    ratio: root.ratio
                    selected: result.selected
                    open: result.open
                    highlight: result.highlight
                    grouped: root.browserState.grouped
                    showCwd: root.browserState.effectiveScope === "global" || root.browserState.effectiveScope === "workspace"
                    interactive: root.actionable
                    controller: root.controller
                    historyIndex: result.index
                    revision: root.browserState.revision
                    onActivated: revision => root.controller.selectPresented(result.index, revision)
                    onActionTriggered: action => {
                        const actions = {copy: HistoryController.Action.copy, erase: HistoryController.Action.erase, visit: HistoryController.Action.visit};
                        root.controller.execute(actions[action], result.record.key);
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
                reveal: inspectorMotion.reveal
                controller: root.controller
                details: root.controller.inspection
                browserState: root.browserState
                colors: root.colors
                typography: root.typography
                command: root.controller.command
                output: root.controller.output
                ratio: root.ratio
                density: root.regions.density
                split: root.regions.results.width > 0
                interactive: root.actionable
                onActionTriggered: (action, revision) => {
                    switch (action) {
                    case "submit":
                        root.controller.usePresented(revision);
                        break;
                    case "alternate":
                        root.controller.usePresented(revision, true);
                        break;
                    default:
                        const actions = {copy: HistoryController.Action.copy, erase: HistoryController.Action.erase, visit: HistoryController.Action.visit};
                        root.controller.execute(actions[action], root.controller.inspection.identity);
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
                    colors: root.colors
                    typography: root.typography
                    workspace: root.workspaceName
                    ratio: root.ratio
                    onSearchEverywhere: root.controller.setFilters({scope: "global"})
                }
            }
        }
    }

    HistoryFooter {
        controller: root.controller
        x: root.regions.footer.x
        y: root.regions.footer.y
        width: root.regions.footer.width
        height: root.regions.footer.height
        state: root.browserState
        colors: root.colors
        pixelSize: root.typography.small
        ratio: root.ratio
        interactive: root.actionable
        onActionTriggered: (action, revision) => {
            switch (action) {
            case "submit":
                root.controller.usePresented(revision);
                break;
            case "alternate":
                root.controller.usePresented(revision, true);
                break;
            case "inspect":
                root.controller.execute(HistoryController.Action.inspect);
                break;
            case "visit":
                root.controller.execute(HistoryController.Action.visit);
                break;
            }
        }
    }

    HistorySearchBar {
        id: historySearch
        colors: root.colors
        typography: root.typography
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
        target: root.controller.rows
        function onRowsAboutToBeRemoved() {
            root.retiringRows = true;
        }
        function onRowsRemoved() {
            Qt.callLater(root.restoreRows);
        }
    }

    Connections {
        target: root.controller
        function onInspectionScrolled(lines) {
            const view = inspector.item as HistoryInspector;
            if (view) {
                view.scroll += lines;
            }
        }

        function onChanged() {
            Qt.callLater(root.revealSelection);
        }
    }

    Component.onCompleted: root.controller.registerPanel(root)
}
