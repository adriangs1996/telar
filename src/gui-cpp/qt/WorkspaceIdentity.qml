import QtQuick
import Telar.Gui

// The telar mark, then `machine / workspace` on one line. The machine opens the machine
// picker and the workspace the workspace picker; when the row is narrow the machine elides
// first, so the workspace stays readable.
Item {
    id: root

    required property var colors
    required property var typography
    required property string machine
    required property string workspace
    property real ratio: 1
    property bool attention: false
    signal machineRequested()
    signal workspaceRequested()

    readonly property real markSide: 18 * ratio
    readonly property real gap: 6 * ratio
    readonly property real inset: 4 * ratio
    readonly property real dotSide: 6 * ratio
    readonly property real dotRoom: attention ? dotSide + gap : 0
    readonly property real separatorWidth: separator.implicitWidth + 2 * ratio
    readonly property real labelsRoom: Math.max(0, width - markSide - gap - separatorWidth)
    readonly property real workspaceWidth: Math.min(workspaceLabel.implicitWidth + 2 * inset, labelsRoom)
    readonly property real machineWidth: Math.max(0, Math.min(machineLabel.implicitWidth + 2 * inset + dotRoom, labelsRoom - workspaceWidth))
    readonly property real preferredWidth: markSide + gap + machineLabel.implicitWidth + 2 * inset + dotRoom + separatorWidth + workspaceLabel.implicitWidth + 2 * inset

    implicitWidth: preferredWidth
    implicitHeight: Math.round(28 * ratio)

    ProviderMark {
        objectName: "topBarTelarMark"
        x: 0
        y: (root.height - height) / 2
        width: root.markSide
        height: root.markSide
        telarMark: true
        color: root.colors.chromeText
        ratio: root.ratio
    }

    ChromeButton {
        id: machineButton
        objectName: "topBarMachine"
        x: root.markSide + root.gap
        width: root.machineWidth
        height: root.height
        visible: width > 0
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        Accessible.name: root.machine + ", switch machine" + (root.attention ? ", another machine needs attention" : "")
        onClicked: root.machineRequested()
        contentItem: Item {
            ChromeText {
                id: machineLabel
                objectName: "topBarMachineLabel"
                x: root.inset
                width: Math.max(0, parent.width - 2 * root.inset - root.dotRoom)
                height: parent.height
                text: root.machine
                color: root.colors.subtext0
                pixelSize: root.typography.body
            }

            NativeRoundedRectangle {
                x: parent.width - root.inset - width
                y: (parent.height - height) / 2
                width: root.dotSide
                height: width
                radius: width / 2
                color: root.colors.yellow
                visible: root.attention
            }
        }
    }

    ChromeText {
        id: separator
        x: machineButton.x + machineButton.width + 1 * root.ratio
        width: implicitWidth
        height: root.height
        text: "/"
        color: root.colors.overlay1
        pixelSize: root.typography.body
        elide: Text.ElideNone
        Accessible.ignored: true
    }

    ChromeButton {
        objectName: "topBarWorkspace"
        x: separator.x + separator.width + 1 * root.ratio
        width: root.workspaceWidth
        height: root.height
        visible: width > 0
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        Accessible.name: root.workspace + ", switch workspace"
        onClicked: root.workspaceRequested()
        contentItem: Item {
            ChromeText {
                id: workspaceLabel
                objectName: "workspaceContextName"
                x: root.inset
                width: Math.max(0, parent.width - 2 * root.inset)
                height: parent.height
                text: root.workspace
                color: root.colors.chromeText
                pixelSize: root.typography.body
                emphasized: true
            }
        }
    }
}
