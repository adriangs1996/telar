pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

// The menu under the top bar's machine switcher: every machine of the window in a fixed order,
// the one it shows marked, each with its link, what its agents do and a stack of the ones that
// work or wait. Choosing a row switches to that machine; the last row opens the machine picker,
// where a machine is added, set up, enabled or disabled.
Popup {
    id: root

    required property MachineChromeController controller
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property real inset: Math.round(6 * ratio)
    readonly property real footerHeight: Math.round(32 * ratio)
    readonly property real hairline: 1 / Screen.devicePixelRatio

    objectName: "machineMenu"
    padding: 0
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.max(Math.round(280 * ratio), list.preferredWidth + 2 * inset)
    height: inset + list.preferredHeight + inset + hairline + inset + footerHeight + inset
    background: DialogSurface {
        colors: root.colors
        ratio: root.ratio
    }
    // The menu dims nothing: the panes stay readable while a machine is chosen.
    Overlay.modal: Item {}

    contentItem: Item {
        MachineChrome {
            id: list
            objectName: "machineMenuList"
            controller: root.controller
            segment: false
            roster: true
            x: root.inset
            y: root.inset
            width: Math.max(0, parent.width - 2 * root.inset)
            height: preferredHeight
            colors: root.colors
            typography: root.typography
            onChosen: root.close()
        }

        Rectangle {
            objectName: "machineMenuSeparator"
            x: root.inset
            y: list.y + list.height + root.inset
            width: Math.max(0, parent.width - 2 * root.inset)
            height: root.hairline
            color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
        }

        ChromeButton {
            id: manage
            objectName: "machineMenuManage"
            x: root.inset
            y: list.y + list.height + 2 * root.inset + root.hairline
            width: Math.max(0, parent.width - 2 * root.inset)
            height: root.footerHeight
            colors: root.colors
            pixelSize: root.typography.body
            cornerRadius: ChromeStyle.surfaceRadius * root.ratio
            Accessible.name: "Add or manage machines"
            onClicked: {
                root.close();
                root.controller.pick();
            }
            contentItem: Item {
                ChromeText {
                    x: Math.round(8 * root.ratio)
                    width: Math.max(0, parent.width - 2 * x)
                    height: parent.height
                    text: "Add or manage machines…"
                    color: root.colors.subtext0
                    pixelSize: root.typography.body
                }
            }
        }
    }
}
