import QtQuick
import Telar.Gui

NativeRoundedRectangle {
    id: root

    required property var colors
    required property var typography
    required property var workspace
    required property var tabModel
    property var workspaceModel: null
    required property real controlsInset
    property var controller: null
    property real ratio: 1
    property real textScale: 1
    property bool rail: false
    property bool prefixPending: false
    signal sidebarToggled()
    signal workspaceSelected(string key)
    signal workspacePickerRequested()
    signal tabSelected(string key)
    signal tabClosed(string key)
    signal tabRenamed()
    signal tabCreated()
    signal paletteRequested()

    readonly property real padding: 8 * ratio
    // Controls and the telar mark follow the bar's height, which follows the font size:
    // 28-point controls on the default 44-point bar.
    readonly property real toggleSide: Math.round(height * 0.635)
    readonly property real markSide: Math.round(toggleSide * 0.92)
    readonly property real identityGap: Math.round(height * 0.26)
    readonly property real glyphSide: Math.round(toggleSide * 0.6)
    readonly property real controlGap: 8 * ratio
    readonly property real contextMaximum: 280 * ratio
    readonly property real tabsShare: 0.64
    readonly property real tabsMinimum: identity.x + identity.width + 2 * controlGap
    readonly property real tabsMaximum: projects.x - (projects.width > 0 ? 2 * controlGap : controlGap)
    readonly property real tabsWidth: Math.max(0, Math.min(width * tabsShare, tabsMaximum - tabsMinimum))
    readonly property real tabsLeft: Math.max(tabsMinimum, Math.min((width - tabsWidth) / 2, tabsMaximum - tabsWidth))
    readonly property var machineContext: controller?.machineContext ?? {}
    // The tabs keep this much before the identity and the project switcher get any room,
    // so a narrow window drops those two first.
    readonly property real tabsFloor: 220 * ratio
    readonly property real sideRoom: Math.max(0, paletteButton.x - identity.x - 3 * controlGap - tabsFloor)
    readonly property real contextRoom: Math.max(0, Math.min(contextMaximum, (width - padding - identity.x) * 0.28, sideRoom))
    // A mod's top bar replaces every control; the window buttons keep their inset.
    readonly property var drawn: controller?.elementBars?.top_bar ?? null

    color: colors.topbarBackground
    replaceBackground: true
    clip: true

    ChromeButton {
        id: toggle
        objectName: "sidebarToggle"
        visible: root.drawn === null
        x: Math.max(root.padding, root.controlsInset)
        y: (parent.height - height) / 2
        width: Math.min(root.toggleSide, parent.height, Math.max(0, parent.width - root.padding - x))
        height: width
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        checked: !root.rail
        contentItem: ChromeIcon {
            glyph: "\uec02"
            color: root.colors.chromeText
            pixelSize: root.glyphSide
        }
        Accessible.name: "Toggle sidebar"
        onClicked: root.sidebarToggled()
    }

    WorkspaceIdentity {
        id: identity
        objectName: "topBarIdentity"
        visible: root.drawn === null
        x: toggle.x + toggle.width + root.identityGap
        y: (parent.height - height) / 2
        width: Math.min(root.contextRoom, preferredWidth)
        height: Math.min(parent.height, root.toggleSide)
        markSide: root.markSide
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        machine: root.machineContext.label || ""
        workspace: root.workspace.name || "workspace"
        attention: root.rail && (root.machineContext.attention ?? false)
        onMachineRequested: {
            if (root.controller) root.controller.execute(GuiController.Action.machine_picker);
        }
        onWorkspaceRequested: root.workspacePickerRequested()
    }

    ProjectSwitcher {
        id: projects
        objectName: "projectSwitcher"
        visible: root.drawn === null
        x: paletteButton.x - (width > 0 ? root.controlGap : 0) - width
        width: Math.max(0, Math.min(preferredWidth, root.width * 0.14, root.sideRoom - identity.width))
        height: root.height
        model: root.workspaceModel
        selectedIndex: root.workspace.index ?? -1
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        onSelected: key => root.workspaceSelected(key)
        onOverflowRequested: root.workspacePickerRequested()
    }

    ChromeButton {
        id: paletteButton
        objectName: "paletteButton"
        visible: root.drawn === null
        x: createTab.x - 4 * root.ratio - width
        y: (parent.height - height) / 2
        width: root.toggleSide
        height: width
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        contentItem: ChromeIcon {
            glyph: "\u{f0633}"
            color: root.colors.chromeText
            pixelSize: Math.round(root.glyphSide * 0.9)
        }
        Accessible.name: "Open command palette"
        onClicked: root.paletteRequested()
    }

    ChromeButton {
        id: createTab
        objectName: "createTabButton"
        visible: root.drawn === null
        x: root.width - root.padding - width
        y: (parent.height - height) / 2
        width: root.toggleSide
        height: width
        colors: root.colors
        pixelSize: root.typography.body + 4 * root.ratio
        emphasized: true
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        text: "+"
        Accessible.name: "New tab"
        onClicked: root.tabCreated()
    }

    TerminalTabs {
        controller: root.controller
        visible: root.drawn === null
        model: root.tabModel
        x: root.tabsLeft
        width: root.tabsWidth
        createBounds: Qt.rect(createTab.x - x, createTab.y, createTab.width, createTab.height)
        height: root.height
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        textScale: root.textScale
        prefixPending: root.prefixPending
        onSelected: key => root.tabSelected(key)
        onClosed: key => root.tabClosed(key)
        onRenamed: root.tabRenamed()
    }

    ElementHost {
        objectName: "topBarElements"
        x: Math.max(root.padding, root.controlsInset)
        width: Math.max(0, root.width - x - root.padding)
        height: root.height
        visible: root.drawn !== null
        content: root.drawn
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        controller: root.controller
        builtins: ({sidebar_toggle: togglePiece, workspace_identity: identityPiece, project_switcher: projectsPiece, tabs: tabsPiece, palette_button: palettePiece, new_tab: newTabPiece})
    }

    component Control: ChromeButton {
        implicitWidth: root.toggleSide
        implicitHeight: root.toggleSide
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.controlRadius * root.ratio
    }

    Component {
        id: togglePiece
        Control {
            checked: !root.rail
            contentItem: ChromeIcon {
                glyph: "\uec02"
                color: root.colors.chromeText
                pixelSize: root.glyphSide
            }
            Accessible.name: "Toggle sidebar"
            onClicked: root.sidebarToggled()
        }
    }

    Component {
        id: identityPiece
        WorkspaceIdentity {
            implicitHeight: root.toggleSide
            markSide: root.markSide
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            machine: root.machineContext.label || ""
            workspace: root.workspace.name || "workspace"
            attention: root.rail && (root.machineContext.attention ?? false)
            onMachineRequested: {
                if (root.controller) root.controller.execute(GuiController.Action.machine_picker);
            }
            onWorkspaceRequested: root.workspacePickerRequested()
        }
    }

    Component {
        id: projectsPiece
        ProjectSwitcher {
            implicitWidth: preferredWidth
            implicitHeight: root.height
            model: root.workspaceModel
            selectedIndex: root.workspace.index ?? -1
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            onSelected: key => root.workspaceSelected(key)
            onOverflowRequested: root.workspacePickerRequested()
        }
    }

    Component {
        id: tabsPiece
        TerminalTabs {
            controller: root.controller
            model: root.tabModel
            implicitHeight: root.height
            createBounds: Qt.rect(0, 0, 0, 0)
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            textScale: root.textScale
            prefixPending: root.prefixPending
            onSelected: key => root.tabSelected(key)
            onClosed: key => root.tabClosed(key)
            onRenamed: root.tabRenamed()
        }
    }

    Component {
        id: palettePiece
        Control {
            contentItem: ChromeIcon {
                glyph: "\u{f0633}"
                color: root.colors.chromeText
                pixelSize: Math.round(root.glyphSide * 0.9)
            }
            Accessible.name: "Open command palette"
            onClicked: root.paletteRequested()
        }
    }

    Component {
        id: newTabPiece
        Control {
            emphasized: true
            pixelSize: root.typography.body + 4 * root.ratio
            text: "+"
            Accessible.name: "New tab"
            onClicked: root.tabCreated()
        }
    }
}
