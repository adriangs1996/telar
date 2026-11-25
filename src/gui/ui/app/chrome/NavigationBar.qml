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
    // The tab strip's controller, which takes the strip that drags tabs.
    property TabsController tabs: null
    // The window's machine chrome: the switcher reads the machine it shows from it, and its menu
    // lists every machine.
    property MachineChromeController machineChrome: null
    readonly property var machine: machineChrome?.active ?? ({})
    // A mod's top bar, which replaces every control; the window buttons keep their inset.
    property var drawn: null
    property real ratio: 1
    property real textScale: 1
    property bool rail: false
    property bool prefixPending: false
    signal sidebarToggled()
    signal workspaceSelected(string key)
    signal workspaceCreated()
    signal tabSelected(string key)
    signal tabClosed(string key)
    signal tabRenamed()
    signal tabCreated()
    signal paletteRequested()
    // A click on an element a mod drew in the bar or a tab.
    signal elementActivated(string slot, string key, string revision, int element)

    readonly property real padding: 8 * ratio
    // Controls follow the bar's height, which follows the font size:
    // 28-point controls on the default 44-point bar.
    readonly property real toggleSide: Math.round(height * 0.635)
    readonly property real identityGap: Math.round(height * 0.26)
    readonly property real glyphSide: Math.round(toggleSide * 0.6)
    readonly property real controlGap: 8 * ratio
    // The bar reads in the order of what holds what: the machine, its workspaces, then the tabs
    // of the workspace in front. The tabs keep tabsFloor before the other two get any room, so
    // a narrow window shortens those first: the machine's label down to labelFloor, then the
    // workspaces' names, then the workspaces that do not fit.
    readonly property real tabsFloor: 220 * ratio
    readonly property real machineMaximum: 240 * ratio
    readonly property real labelFloor: 72 * ratio
    readonly property real sideRoom: Math.max(0, paletteButton.x - identity.x - 3 * controlGap - tabsFloor)
    readonly property real machineWanted: Math.min(identity.preferredWidth, machineMaximum)
    readonly property real machineFloor: Math.min(machineWanted, identity.minimumWidth + labelFloor)
    readonly property real machineRoom: Math.min(sideRoom, Math.max(machineFloor, Math.min(machineWanted, sideRoom - controlGap - track.preferredWidth)))
    readonly property real trackRoom: Math.max(0, sideRoom - identity.width - controlGap)
    readonly property real tabsLeft: (track.width > 0 ? track.x + track.width : identity.x + identity.width) + 2 * controlGap
    readonly property real tabsWidth: Math.max(0, paletteButton.x - controlGap - tabsLeft)

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

    MachineSwitch {
        id: identity
        objectName: "topBarIdentity"
        visible: root.drawn === null
        x: toggle.x + toggle.width + root.identityGap
        y: (parent.height - height) / 2
        width: root.machineRoom
        height: Math.min(parent.height, root.toggleSide)
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        machine: root.machine
        open: machineMenu.visible
        onRequested: machineMenu.open()
    }

    WorkspaceTrack {
        id: track
        objectName: "workspaceTrack"
        visible: root.drawn === null && implicitWidth > 0
        x: identity.x + identity.width + root.controlGap
        y: (parent.height - height) / 2
        width: implicitWidth
        height: Math.min(parent.height, implicitHeight)
        room: root.drawn === null ? root.trackRoom : 0
        model: root.workspaceModel
        selectedIndex: root.workspace.index ?? -1
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        onSelected: key => root.workspaceSelected(key)
        onListRequested: workspaceMenu.open()
    }

    MachineMenu {
        id: machineMenu
        parent: root
        x: Math.max(root.padding, Math.min(identity.x + identity.anchor.x, root.width - width - root.padding))
        y: root.height - 2 * root.ratio
        controller: root.machineChrome
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
    }

    WorkspaceMenu {
        id: workspaceMenu
        parent: root
        x: Math.max(root.padding, Math.min(track.x, root.width - width - root.padding))
        y: root.height - 2 * root.ratio
        maximumHeight: Math.max(rowHeight, (root.Window.height ?? 600) - root.height - 24 * root.ratio)
        model: root.workspaceModel
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        onSelected: key => root.workspaceSelected(key)
        onCreateRequested: root.workspaceCreated()
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
        controller: root.tabs
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
        onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
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
        onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
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
        MachineSwitch {
            implicitHeight: root.toggleSide
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            machine: root.machine
            open: machineMenu.visible
            onRequested: machineMenu.open()
        }
    }

    // A mod's bar keeps the name it was written with: its project switcher is the workspace
    // track, which asks for every name and draws what the width it is given holds.
    Component {
        id: projectsPiece
        WorkspaceTrack {
            room: width > 0 ? width : preferredWidth
            model: root.workspaceModel
            selectedIndex: root.workspace.index ?? -1
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            onSelected: key => root.workspaceSelected(key)
            onListRequested: workspaceMenu.open()
        }
    }

    Component {
        id: tabsPiece
        TerminalTabs {
            controller: root.tabs
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
            onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
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
