import Telar.Gui
import QtQuick

Window {
    id: root

    width: 1200
    height: 800
    minimumWidth: 320
    minimumHeight: 200
    visible: true
    title: telar.title
    color: telar.colors.windowBackground

    readonly property real ratio: telar.chromeRatio
    readonly property var geometry: telar.windowGeometry
    readonly property real sidebarWidth: geometry.sidebar.width

    NavigationBar {
        controller: telar
        x: root.geometry.navigation.x
        y: root.geometry.navigation.y
        width: root.geometry.navigation.width
        height: root.geometry.navigation.height
        visible: height > 0
        colors: telar.colors
        typography: root.geometry.typography
        workspace: telar.workspaceContext
        tabModel: telar.tabs
        prefixPending: telar.prefixPending
        controlsInset: telar.windowControls
        workbenchLeft: root.geometry.terminal.x
        ratio: root.ratio
        textScale: telar.chromeTextScale
        rail: root.geometry.rail
        onSidebarToggled: telar.execute(GuiController.Action.toggle_sidebar)
        onTabSelected: key => telar.execute(GuiController.Action.select_tab, key)
        onTabClosed: key => telar.execute(GuiController.Action.close_tab, key)
        onTabRenamed: telar.execute(GuiController.Action.rename_tab)
        onTabCreated: telar.execute(GuiController.Action.new_tab)
    }

    Sidebar {
        id: sidebar
        controller: telar

        x: root.geometry.sidebar.x
        y: root.geometry.sidebar.y
        width: root.geometry.sidebar.width
        height: root.geometry.sidebar.height
        ratio: root.ratio
        expanded: !root.geometry.rail
        colors: telar.colors
        typography: sidebar.regions.typography
        regions: telar.sidebarGeometry
        workspaceModel: telar.workspaces
        agentModel: telar.agents
        preferredWidth: telar.sidebarWidth
        textScale: telar.chromeTextScale
        onWorkspaceSelected: key => telar.execute(GuiController.Action.select_workspace, key)
        onAgentSelected: key => telar.execute(GuiController.Action.select_agent, key)
        onAgentPeekRequested: key => telar.peekActivity(key)
        onSidebarResized: requestedWidth => telar.setSidebarWidth(requestedWidth)
    }

    PaneArea {
        application: telar
        x: root.geometry.terminal.x
        y: root.geometry.terminal.y
        width: root.geometry.terminal.width
        height: root.geometry.terminal.height
        ratio: root.ratio
    }

    StatusBar {
        controller: telar
        x: root.geometry.status.x
        y: root.geometry.status.y
        width: root.geometry.status.width
        height: root.geometry.status.height
        visible: height > 0
        metrics: telar.hostMetrics
        colors: telar.colors
        typography: root.geometry.typography
        diagnostic: telar.error
        tlsColor: telar.tlsBadgeColor
        mode: telar.statusMode
        ratio: root.ratio
        onDiagnosticDismissed: telar.dismissDiagnostic()
    }

    LinkStatus {
        controller: telar
    }

    CommandDialog {
        id: commandDialog

        ratio: root.ratio
    }

    ComponentPanel {
        parent: root.contentItem
        controller: telar
        colors: telar.colors
        typography: root.geometry.typography
        ratio: root.ratio
    }

    ComponentPick {
        parent: root.contentItem
        controller: telar
        colors: telar.colors
        typography: root.geometry.typography
        ratio: root.ratio
    }

    NotificationOverlay {
        anchors.fill: parent
        controller: telar
        colors: telar.colors
    }

    AttachmentModal {
        anchors.fill: parent
        application: telar
    }

    Shortcut {
        sequences: ["Ctrl+Shift+P", "Meta+Shift+P"]
        onActivated: telar.execute(GuiController.Action.palette)
    }
}
