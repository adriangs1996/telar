pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The machine the window shows as one control: its avatar with the dot of its link, its label
// and a chevron. It opens the menu of every machine. A dot before the chevron says another
// machine needs the person. When the row is narrow the label elides, and the avatar still tells
// which machine it is.
Item {
    id: root

    required property var colors
    required property var typography
    // The machine chrome's `active`: label, initial, ink, live and attention.
    required property var machine
    property real ratio: 1
    // The menu is open: the control stays pressed under it.
    property bool open: false
    readonly property string label: machine.label ?? ""
    readonly property bool attention: machine.attention ?? false
    readonly property color ink: (machine.ink?.a ?? 0) > 0 ? machine.ink : colors.accent
    readonly property real inset: Math.round(5 * ratio)
    readonly property real avatarSide: Math.round(20 * ratio)
    readonly property real labelGap: Math.round(7 * ratio)
    readonly property real chevronSide: Math.round(12 * ratio)
    readonly property real dotSide: Math.round(6 * ratio)
    readonly property real dotRoom: attention ? dotSide + labelGap : 0
    // The control with no label: what is left when the bar has no room for one.
    // The pill's round end needs more room past the chevron than the avatar's disc does.
    readonly property real endInset: Math.round(9 * ratio)
    readonly property real bareWidth: inset + avatarSide + dotRoom + labelGap + chevronSide + endInset
    readonly property real minimumWidth: bareWidth
    readonly property real preferredWidth: minimumWidth + (label.length > 0 ? labelGap + Math.ceil(labelText.implicitWidth) : 0)
    // Where the menu hangs from, in this item's coordinates.
    readonly property rect anchor: Qt.rect(control.x, control.y, control.width, control.height)
    signal requested()

    implicitWidth: preferredWidth
    implicitHeight: Math.round(28 * ratio)

    ChromeButton {
        id: control
        objectName: "topBarMachine"
        width: Math.max(0, Math.min(root.preferredWidth, root.width))
        height: root.height
        visible: width >= root.bareWidth
        colors: root.colors
        pixelSize: root.typography.body
        checked: root.open
        Accessible.name: root.label + ", switch machine" + (root.attention ? ", another machine needs attention" : "")
        onClicked: root.requested()
        // At rest it sits on the same well as the workspace track beside it.
        background: NativeRoundedRectangle {
            objectName: "topBarMachineWell"
            color: Qt.alpha(root.colors.chromeText, ChromeStyle.wellAlpha + (control.down || control.checked ? ChromeStyle.selectionAlpha : control.hovered || control.visualFocus ? ChromeStyle.hoverAlpha : 0))
            radius: height / 2
            borderColor: root.colors.accent
            borderAlpha: ChromeStyle.focusAlpha
            borderWidth: control.visualFocus ? 1 / Screen.devicePixelRatio : 0
        }
        contentItem: Item {
            // The machine's color and initial in a disc, which no workspace's square mark takes
            // for a machine, with the dot of its link at the corner.
            NativeRoundedRectangle {
                id: avatar
                objectName: "topBarMachineAvatar"
                x: root.inset
                y: (parent.height - height) / 2
                width: root.avatarSide
                height: root.avatarSide
                radius: width / 2
                color: Qt.alpha(root.ink, 0.16)
                borderColor: root.ink
                borderAlpha: 0.4
                borderWidth: 1 / Screen.devicePixelRatio

                ChromeText {
                    objectName: "topBarMachineInitial"
                    anchors.fill: parent
                    text: root.machine.initial ?? ""
                    color: root.ink
                    pixelSize: root.typography.small
                    emphasized: true
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideNone
                    Accessible.ignored: true
                }

                NativeRoundedRectangle {
                    objectName: "topBarMachineLink"
                    x: parent.width - width * 0.7
                    y: parent.height - height * 0.7
                    width: Math.round(7 * root.ratio)
                    height: width
                    radius: width / 2
                    color: (root.machine.live ?? false) ? root.colors.green : root.colors.overlay1
                    borderColor: root.colors.topbarBackground
                    borderAlpha: 1
                    borderWidth: Math.max(1, Math.round(1.5 * root.ratio))
                }
            }

            ChromeText {
                id: labelText
                objectName: "topBarMachineLabel"
                x: avatar.x + avatar.width + root.labelGap
                width: Math.max(0, chevron.x - root.dotRoom - root.labelGap - x)
                height: parent.height
                text: root.label
                color: root.colors.chromeText
                pixelSize: root.typography.body
                emphasized: true
                visible: width > 0
            }

            NativeRoundedRectangle {
                objectName: "topBarMachineAttention"
                x: chevron.x - root.labelGap - width
                y: (parent.height - height) / 2
                width: root.dotSide
                height: width
                radius: width / 2
                color: root.colors.yellow
                visible: root.attention
            }

            ProviderMark {
                id: chevron
                objectName: "topBarMachineChevron"
                x: parent.width - root.endInset - width
                y: (parent.height - height) / 2
                width: root.chevronSide
                height: root.chevronSide
                symbol: "chevron-down"
                color: root.colors.subtext0
            }
        }
    }
}
