pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

// The menu under the top bar's machine switcher: every machine of the window in a fixed order,
// the one it shows marked, each with its link, what its agents do and a stack of the ones that
// work or wait. Choosing a row switches to that machine, with the pointer or with the arrows and
// Enter as in the workspace menu; the last row opens the machine picker, where a machine is
// added, set up, enabled or disabled.
Popup {
    id: root

    required property MachineChromeController controller
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property real inset: Math.round(6 * ratio)

    objectName: "machineMenu"
    padding: 0
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    // As wide as the workspace menu, unless a label needs more.
    width: Math.max(Math.round(320 * ratio), list.preferredWidth + 2 * inset)
    height: inset + list.preferredHeight + inset + footer.height + inset
    background: DialogSurface {
        colors: root.colors
        ratio: root.ratio
    }
    // The menu dims nothing: the panes stay readable while a machine is chosen.
    Overlay.modal: Item {}

    onAboutToShow: list.selectCurrent()
    onOpened: keys.forceActiveFocus()

    contentItem: Item {
        id: keys
        focus: true
        Keys.onUpPressed: list.move(-1)
        Keys.onDownPressed: list.move(1)
        Keys.onReturnPressed: list.chooseSelection()
        Keys.onEnterPressed: list.chooseSelection()

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

        MenuFooter {
            id: footer
            objectName: "machineMenuManage"
            x: root.inset
            y: list.y + list.height + root.inset
            width: Math.max(0, parent.width - 2 * root.inset)
            height: implicitHeight
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            text: "Add or manage machines"
            onTriggered: {
                root.close();
                root.controller.pick();
            }
        }
    }
}
