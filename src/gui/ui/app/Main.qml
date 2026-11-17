import Telar.Gui
import QtQuick

Window {
    id: root

    width: 1200
    height: 800
    minimumWidth: 320
    minimumHeight: 200
    visible: true
    title: telar.status.title
    color: "transparent"

    readonly property real ratio: telar.display.chromeRatio
    readonly property var geometry: telar.display.geometry
    readonly property real sidebarWidth: geometry.sidebar.width

    NativeRoundedRectangle {
        objectName: "workspaceBackground"
        x: root.geometry.sidebar.width
        y: root.geometry.navigation.height
        width: Math.max(0, root.width - x)
        height: Math.max(0, root.geometry.status.y - y)
        color: telar.colors.workbenchBackground
        replaceBackground: true
    }

    NavigationBar {
        tabs: telar.tabs
        machineContext: telar.machineContext
        drawn: telar.components.elementBars.top_bar ?? null
        x: root.geometry.navigation.x
        y: root.geometry.navigation.y
        width: root.geometry.navigation.width
        height: root.geometry.navigation.height
        visible: height > 0
        colors: telar.colors
        typography: root.geometry.typography
        workspace: telar.workspaces.context
        tabModel: telar.tabs.rows
        workspaceModel: telar.workspaces.rows
        prefixPending: telar.status.prefixPending
        controlsInset: telar.display.windowControls
        ratio: root.ratio
        textScale: telar.display.chromeTextScale
        rail: root.geometry.rail
        onSidebarToggled: telar.execute(WindowActions.Action.toggle_sidebar)
        onWorkspaceSelected: key => telar.execute(WindowActions.Action.select_workspace, key)
        onWorkspacePickerRequested: telar.execute(WindowActions.Action.goto_picker)
        onTabSelected: key => telar.execute(WindowActions.Action.select_tab, key)
        onTabClosed: key => telar.execute(WindowActions.Action.close_tab, key)
        onTabRenamed: telar.execute(WindowActions.Action.rename_tab)
        onTabCreated: telar.execute(WindowActions.Action.new_tab)
        onPaletteRequested: telar.execute(WindowActions.Action.palette)
        onMachinePickerRequested: telar.execute(WindowActions.Action.machine_picker)
        onElementActivated: (slot, key, revision, element) => telar.activateElement(slot, key, revision, element)
    }

    Sidebar {
        id: sidebar
        controller: telar.sidebar
        activity: telar.activity
        machineChrome: telar.machineChrome
        machineContext: telar.machineContext

        x: root.geometry.sidebar.x
        y: root.geometry.sidebar.y
        width: root.geometry.sidebar.width
        height: root.geometry.sidebar.height
        ratio: root.ratio
        expanded: !root.geometry.rail
        colors: telar.colors
        typography: sidebar.regions.typography
        regions: telar.sidebar.regions
        agentModel: telar.activity.rows
        preferredWidth: telar.display.sidebarWidth
        textScale: telar.display.chromeTextScale
        onAgentSelected: key => telar.execute(WindowActions.Action.select_agent, key)
        onAgentPeekRequested: key => telar.peekActivity(key)
        onSidebarResized: requestedWidth => telar.display.setSidebarWidth(requestedWidth)
        onElementActivated: (slot, key, revision, element) => telar.activateElement(slot, key, revision, element)
    }

    PaneArea {
        id: paneArea
        controller: telar.panes
        terminals: telar.terminals
        documents: telar.documents
        copy: telar.copy
        attachments: telar.attachments
        history: telar.history
        pathPicker: telar.paths
        prompt: telar.prompt
        colors: telar.colors
        typography: root.geometry.typography
        headerHeight: root.geometry.paneHeader
        dialog: telar.dialog
        // The kind and the pane in one value, read together on each dialogChanged.
        lineSearch: ({kind: telar.lineSearch, pane: telar.lineSearchPane})
        prefixPending: telar.status.prefixPending
        controlModifier: telar.controlModifier
        superModifier: telar.superModifier
        keyboardCovered: componentPanelPopup.visible || componentPickPopup.visible
        x: root.geometry.terminal.x
        y: root.geometry.terminal.y
        width: root.geometry.terminal.width
        height: root.geometry.terminal.height
        ratio: root.ratio
        onActionRequested: (action, target) => telar.execute(action, target)
        onElementActivated: (slot, key, revision, element) => telar.activateElement(slot, key, revision, element)
    }

    // Once the panes read the new dialog, the focused one takes the keyboard back if none is open.
    Connections {
        target: telar
        function onDialogChanged() {
            paneArea.dialogShown();
        }
    }

    StatusBar {
        components: telar.components
        machineChrome: telar.machineChrome
        drawn: telar.components.elementBars.bottom_bar ?? null
        x: root.geometry.status.x
        y: root.geometry.status.y
        width: root.geometry.status.width
        height: root.geometry.status.height
        visible: height > 0
        metrics: telar.status.hostMetrics
        colors: telar.colors
        typography: root.geometry.typography
        diagnostic: telar.status.error
        tlsColor: telar.status.tlsBadgeColor
        mode: telar.status.mode
        ratio: root.ratio
        onDiagnosticDismissed: telar.status.dismiss()
        onElementActivated: (slot, key, revision, element) => telar.activateElement(slot, key, revision, element)
    }

    LinkStatus {
        controller: telar.linkStatus
        colors: telar.colors
        typography: root.geometry.typography
    }

    CommandDialog {
        id: commandDialog

        ratio: root.ratio
    }

    ComponentPanel {
        id: componentPanelPopup
        parent: root.contentItem
        controller: telar.components
        hostMetrics: telar.status.hostMetrics
        machineChrome: telar.machineChrome
        colors: telar.colors
        typography: root.geometry.typography
        ratio: root.ratio
    }

    ComponentPick {
        id: componentPickPopup
        parent: root.contentItem
        controller: telar.components
        colors: telar.colors
        typography: root.geometry.typography
        ratio: root.ratio
    }

    NotificationOverlay {
        anchors.fill: parent
        controller: telar.notifications
        colors: telar.colors
    }

    AttachmentModal {
        anchors.fill: parent
        controller: telar.attachments
        colors: telar.colors
        typography: root.geometry.typography
    }

    Shortcut {
        sequences: ["Ctrl+Shift+P", "Meta+Shift+P"]
        onActivated: telar.execute(WindowActions.Action.palette)
    }
}
