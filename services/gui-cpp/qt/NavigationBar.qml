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
    readonly property real machineControlHeight: 26 * ratio
    readonly property real contextInset: 4 * ratio
    readonly property real contextMaximum: 160 * ratio
    readonly property real separatorGap: 10 * ratio
    readonly property real separatorHeight: 18 * ratio
    readonly property real physicalPixel: 1 / Screen.devicePixelRatio
    readonly property real controlsRight: toggle.x + toggle.width + controlGap
    readonly property real machineRight: machine.shown ? machine.x + machine.width + controlGap : controlsRight
    readonly property real contextWidth: rail ? Math.max(0, Math.min(contextName.implicitWidth, contextMaximum, (width - padding - machineRight) / 3 - contextInset)) : 0
    readonly property real contextRight: machineRight + contextInset + contextWidth + 2 * separatorGap + physicalPixel

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

    MachineChrome {
        id: machine
        objectName: "topBarMachineSegment"
        controller: root.controller
        segment: true
        x: root.controlsRight
        y: (root.height - height) / 2
        width: Math.max(0, Math.min(preferredWidth, (root.width - root.padding - x) / 3))
        height: Math.min(root.height, root.machineControlHeight)
        colors: root.colors
    }

    ChromeText {
        id: contextName
        x: root.machineRight + root.contextInset
        width: root.contextWidth
        height: parent.height
        text: root.workspace.name ?? "workspace"
        color: root.colors.text
        pixelSize: root.typography.body
        emphasized: true
        visible: root.rail
        elide: Text.ElideNone
        clip: true
    }

    Rectangle {
        x: Math.floor((contextName.x + contextName.width + root.separatorGap) * Screen.devicePixelRatio) / Screen.devicePixelRatio
        y: Math.floor((parent.height - height) * Screen.devicePixelRatio / 2) / Screen.devicePixelRatio
        width: root.physicalPixel
        height: Math.min(parent.height, root.separatorHeight)
        color: root.colors.surface1
        visible: root.rail && root.contextWidth > 0
    }

    TerminalTabs {
        controller: root.controller
        model: root.tabModel
        x: root.rail ? root.contextRight : Math.max(root.machineRight, root.workbenchLeft)
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
