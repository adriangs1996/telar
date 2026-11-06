import QtQuick
import Telar.Gui

Rectangle {
    id: root

    required property var colors
    required property var typography
    required property var workspace
    required property var tabModel
    required property real controlsInset
    required property real workbenchLeft
    property var controller: null
    property real ratio: 1
    property real textScale: 1
    property bool rail: false
    property bool prefixPending: false
    signal sidebarToggled()
    signal tabSelected(string key)
    signal tabClosed(string key)
    signal tabRenamed()
    signal tabCreated()

    readonly property real padding: 8 * ratio
    readonly property real toggleSide: 28 * ratio
    readonly property real controlGap: 8 * ratio
    readonly property real contextMaximum: 160 * ratio
    readonly property var machineContext: controller?.machineContext ?? {}
    readonly property real contextRoom: Math.max(0, Math.min(contextMaximum, (width - padding - identity.x) * 0.28))

    color: colors.panelBackground
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
        cornerRadius: root.controlGap
        emphasized: !root.rail
        text: "\u2261"
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
        cornerRadius: 6 * root.ratio
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
                color: root.colors.text
                pixelSize: root.typography.body
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
                color: root.colors.subtext0
                pixelSize: root.typography.small
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

    TerminalTabs {
        controller: root.controller
        model: root.tabModel
        x: root.rail ? identity.x + identity.width + root.controlGap : Math.max(identity.x + identity.width + root.controlGap, root.workbenchLeft)
        width: Math.max(0, root.width - root.padding - x)
        height: root.height
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        textScale: root.textScale
        prefixPending: root.prefixPending
        onSelected: key => root.tabSelected(key)
        onClosed: key => root.tabClosed(key)
        onRenamed: root.tabRenamed()
        onCreated: root.tabCreated()
    }
}
