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

    // Everything the window shows but the theme picker, which shows this content live.
    Item {
        id: windowContent
        objectName: "windowContent"
        anchors.fill: parent

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
            machineContext: telar.machines.context
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
            onSidebarToggled: telar.commands.execute(WindowActions.Action.toggle_sidebar)
            onWorkspaceSelected: key => telar.commands.execute(WindowActions.Action.select_workspace, key)
            onWorkspacePickerRequested: telar.commands.execute(WindowActions.Action.goto_picker)
            onTabSelected: key => telar.commands.execute(WindowActions.Action.select_tab, key)
            onTabClosed: key => telar.commands.execute(WindowActions.Action.close_tab, key)
            onTabRenamed: telar.commands.execute(WindowActions.Action.rename_tab)
            onTabCreated: telar.commands.execute(WindowActions.Action.new_tab)
            onPaletteRequested: telar.commands.execute(WindowActions.Action.palette)
            onMachinePickerRequested: telar.commands.execute(WindowActions.Action.machine_picker)
            onElementActivated: (slot, key, revision, element) => telar.commands.activateElement(slot, key, revision, element)
        }

        Sidebar {
            id: sidebar
            controller: telar.sidebar
            activity: telar.activity
            machineChrome: telar.machineChrome
            machineContext: telar.machines.context

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
            transfers: telar.explorer?.transfers ?? []
            onTransferCancelled: id => telar.explorer.cancelTransfer(id)
            onAgentSelected: key => telar.commands.execute(WindowActions.Action.select_agent, key)
            onAgentPeekRequested: key => telar.commands.peekActivity(key)
            onSidebarResized: requestedWidth => telar.display.setSidebarWidth(requestedWidth)
            onElementActivated: (slot, key, revision, element) => telar.commands.activateElement(slot, key, revision, element)
        }

        PaneArea {
            id: paneArea
            controller: telar.panes
            terminals: telar.terminals
            editors: telar.editors
            documents: telar.documents
            copy: telar.copy
            attachments: telar.attachments
            history: telar.history
            pathPicker: telar.paths
            prompt: telar.prompt
            colors: telar.colors
            typography: root.geometry.typography
            headerHeight: root.geometry.paneHeader
            dialog: telar.dialogs.kind
            // The kind and the pane in one value, read together on each dialogChanged.
            lineSearch: ({kind: telar.dialogs.lineSearch, pane: telar.dialogs.lineSearchPane})
            prefixPending: telar.status.prefixPending
            controlModifier: telar.controlModifier
            superModifier: telar.superModifier
            keyboardCovered: componentPanelPopup.visible || componentPickPopup.visible
            x: root.geometry.terminal.x
            y: root.geometry.terminal.y
            width: root.geometry.terminal.width
            height: root.geometry.terminal.height
            ratio: root.ratio
            onActionRequested: (action, target) => telar.commands.execute(action, target)
            onElementActivated: (slot, key, revision, element) => telar.commands.activateElement(slot, key, revision, element)
        }

        // Once the panes read the new dialog, the focused one takes the keyboard back if none is open.
        Connections {
            target: telar.dialogs
            function onChanged() {
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
            onElementActivated: (slot, key, revision, element) => telar.commands.activateElement(slot, key, revision, element)
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

        MonitorOverlay {
            anchors.fill: parent
            controller: telar.monitor
            colors: telar.colors
            typography: root.geometry.typography
            ratio: root.ratio
            topInset: root.geometry.navigation.y + root.geometry.navigation.height
        }

        ExplorerOverlay {
            // Over the panes of the tab, with the sidebar and the bars left in view; or, as a pane
            // of the tab, in the room that pane has.
            area: telar.explorer.pinned ? Qt.rect(paneArea.x + paneArea.explorerRoom.x, paneArea.y + paneArea.explorerRoom.y, paneArea.explorerRoom.width, paneArea.explorerRoom.height) : root.geometry.terminal
            paneArea: paneArea
            controller: telar.explorer
            colors: telar.colors
            typography: root.geometry.typography
        }

        AttachmentModal {
            anchors.fill: parent
            controller: telar.attachments
            colors: telar.colors
            typography: root.geometry.typography
        }
    }

    ThemePickerOverlay {
        controller: telar.themes
        source: windowContent
        colors: telar.colors
        typography: root.geometry.typography
        ratio: root.ratio
    }

    Shortcut {
        sequences: ["Ctrl+Shift+P", "Meta+Shift+P"]
        onActivated: telar.commands.execute(WindowActions.Action.palette)
    }
}
