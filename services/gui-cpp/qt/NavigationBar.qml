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
    readonly property real toggleSide: 28 * ratio
    readonly property real controlGap: 8 * ratio
    readonly property real contextMaximum: 160 * ratio
    readonly property real tabsShare: 0.64
    readonly property real tabsMinimum: identity.x + identity.width + 2 * controlGap
    readonly property real tabsMaximum: projects.x - (projects.width > 0 ? 2 * controlGap : controlGap)
    readonly property real tabsWidth: Math.max(0, Math.min(width * tabsShare, tabsMaximum - tabsMinimum))
    readonly property real tabsLeft: Math.max(tabsMinimum, Math.min((width - tabsWidth) / 2, tabsMaximum - tabsWidth))
    readonly property var machineContext: controller?.machineContext ?? {}
    readonly property real contextRoom: Math.max(0, Math.min(contextMaximum, (width - padding - identity.x) * 0.28))

    color: colors.topbarBackground
    replaceBackground: true
    clip: true

    ChromeButton {
        id: toggle
        objectName: "sidebarToggle"
        x: Math.max(root.padding, root.controlsInset)
        y: (parent.height - height) / 2
        width: Math.min(root.toggleSide, parent.height, Math.max(0, parent.width - root.padding - x))
        height: width
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        emphasized: !root.rail
        contentItem: ChromeIcon {
            glyph: "\uf0db"
            color: root.colors.chromeText
            pixelSize: 18 * root.ratio
        }
        Accessible.name: "Toggle sidebar"
        onClicked: root.sidebarToggled()
    }

    ChromeButton {
        id: identity
        objectName: "topBarIdentity"
        x: toggle.x + toggle.width + root.controlGap
        y: (parent.height - height) / 2
        width: Math.min(root.contextRoom, Math.max(contextName.implicitWidth, machineName.implicitWidth) + 8 * root.ratio + (root.machineContext.attention ? 12 * root.ratio : 0))
        height: Math.min(parent.height, (root.typography.bodyRow ?? root.typography.body * 1.25) + (root.typography.smallRow ?? root.typography.small * 1.25))
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        Accessible.name: contextName.text + ", " + machineName.text + ", switch machine"
        onClicked: {
            if (root.controller) root.controller.execute(GuiController.Action.machine_picker);
        }
        contentItem: Item {
            ChromeText {
                id: contextName
                objectName: "workspaceContextName"
                x: 4 * root.ratio
                width: Math.max(0, parent.width - x - 4 * root.ratio - (root.machineContext.attention ? 12 * root.ratio : 0))
                height: parent.height * 0.55
                text: root.workspace.name || "workspace"
                color: root.colors.chromeText
                pixelSize: root.typography.body + 2 * root.ratio
                emphasized: true
            }

            ChromeText {
                id: machineName
                objectName: "topBarMachineLabel"
                x: contextName.x
                y: contextName.height
                width: contextName.width
                height: parent.height - y
                text: root.machineContext.label || ""
                color: root.colors.text
                pixelSize: root.typography.small + root.ratio
            }

            NativeRoundedRectangle {
                x: Math.max(0, parent.width - width - 4 * root.ratio)
                y: (parent.height - height) / 2
                width: 6 * root.ratio
                height: width
                radius: width / 2
                color: root.colors.yellow
                visible: root.machineContext.attention ?? false
            }
        }
    }

    ProjectSwitcher {
        id: projects
        objectName: "projectSwitcher"
        x: paletteButton.x - (width > 0 ? root.controlGap : 0) - width
        width: Math.max(0, Math.min(preferredWidth, root.width * 0.14))
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
            pixelSize: 16 * root.ratio
        }
        Accessible.name: "Open command palette"
        onClicked: root.paletteRequested()
    }

    ChromeButton {
        id: createTab
        objectName: "createTabButton"
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
}
