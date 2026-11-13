pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick
import QtQuick.Controls

Popup {
    id: root

    required property var controller
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var state: controller.componentPanel
    readonly property var anchor: state.anchor ?? Qt.point(-1, -1)
    readonly property real margin: 12 * ratio
    readonly property real headerHeight: 32 * ratio
    readonly property real timestampHeight: 14 * ratio
    readonly property real maximumHeight: Math.max(headerHeight, (parent?.height ?? 640) - 2 * margin)
    readonly property real settledY: Math.max(margin, Math.min((parent?.height ?? height) - height - margin, anchor.y >= 0 ? (anchor.y > height + margin ? anchor.y - height - margin : anchor.y + headerHeight) : (parent?.height ?? height) - height - 36 * ratio))
    readonly property real entranceOffset: Math.min(12 * ratio, Math.max(0, (parent?.height ?? height) - settledY - height - margin))

    ModalRevealLayout {
        id: motion
        objectName: "componentPanelMotion"
        active: root.visible
        generation: root.state.identity ?? ""
    }
    visible: state.open ?? false
    focus: !(controller.componentPick.open ?? false)
    modal: false
    padding: margin
    width: Math.max(0, Math.min((state.width ?? 420) * ratio, (parent?.width ?? 720) - 2 * margin))
    height: Math.min(maximumHeight, headerHeight + margin + body.implicitHeight + (errorText.visible ? errorText.implicitHeight + margin : 0) + 2 * padding)
    x: Math.max(margin, Math.min((parent?.width ?? width) - width - margin, (anchor.x >= 0 ? anchor.x : (parent?.width ?? width) / 2) - width / 2))
    y: settledY + entranceOffset * (1 - motion.reveal)
    opacity: motion.reveal
    objectName: "configuredPanel"
    closePolicy: (controller.componentPick.open ?? false) ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: DialogSurface { colors: root.colors; ratio: root.ratio }
    onClosed: if (state.open) controller.closeComponentPanel()

    contentItem: Item {
        ChromeText {
            x: 0
            width: Math.max(0, parent.width - 2 * root.headerHeight)
            height: root.headerHeight - root.timestampHeight
            text: root.state.title ?? ""
            color: root.colors.text
            pixelSize: root.typography.body
            emphasized: true
        }
        ChromeText {
            y: root.headerHeight - root.timestampHeight
            width: Math.max(0, parent.width - 2 * root.headerHeight)
            height: root.timestampHeight
            text: root.state.lastRender?.length > 0 ? root.state.lastRender : "Loading…"
            color: root.colors.subtext0
            pixelSize: root.typography.small
        }

        ChromeButton {
            x: parent.width - 2 * root.headerHeight
            width: root.headerHeight
            height: root.headerHeight
            colors: root.colors
            text: "↻"
            pixelSize: root.typography.body
            cornerRadius: 5 * root.ratio
            Accessible.name: "Refresh panel"
            onClicked: root.controller.refreshComponentPanel()
        }

        ChromeButton {
            x: parent.width - root.headerHeight
            width: root.headerHeight
            height: root.headerHeight
            colors: root.colors
            text: "×"
            pixelSize: root.typography.body
            cornerRadius: 5 * root.ratio
            Accessible.name: "Close panel"
            onClicked: root.controller.closeComponentPanel()
        }

        Flickable {
            id: body
            y: root.headerHeight + root.margin
            width: parent.width
            height: Math.max(0, parent.height - y - (errorText.visible ? errorText.implicitHeight + root.margin : 0))
            implicitHeight: Math.min(tree.implicitHeight, root.maximumHeight)
            contentHeight: tree.implicitHeight
            clip: true
            ComponentTree {
                id: tree
                width: parent.width
                controller: root.controller
                surface: root.state
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                horizontal: false
            }
            ScrollBar.vertical: ScrollBar {}
        }

        Text {
            id: errorText
            y: parent.height - implicitHeight
            width: parent.width
            text: root.state.error ?? ""
            visible: text.length > 0
            color: root.colors.red
            font.family: "IBM Plex Sans"
            font.pixelSize: root.typography.small
            textFormat: Text.PlainText
            renderType: Text.NativeRendering
            wrapMode: Text.Wrap
            maximumLineCount: 3
        }
    }
}
