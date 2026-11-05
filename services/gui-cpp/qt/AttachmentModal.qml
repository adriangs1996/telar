pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick

FocusScope {
    id: root
    required property GuiController application
    readonly property var shelf: application.attachments
    readonly property var state: shelf.modal
    readonly property var regions: application.attachmentModalGeometry
    readonly property var host: regions.host
    readonly property color background: application.colors.background
    readonly property var grid: application.windowGeometry.typography.grid
    readonly property real physicalPixel: 1 / Screen.devicePixelRatio
    visible: (state.id ?? "").length > 0
    z: 50
    onVisibleChanged: {
        if (visible)
            forceActiveFocus();
    }

    Rectangle {
        x: root.host?.x ?? 0
        y: root.host?.y ?? 0
        width: root.host?.width ?? 0
        height: root.host?.height ?? 0
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)
        opacity: 0.55
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: mouse => mouse.accepted = true
        onWheel: wheel => wheel.accepted = true
    }

    MouseArea {
        x: root.host?.x ?? 0
        y: root.host?.y ?? 0
        width: root.host?.width ?? 0
        height: root.host?.height ?? 0
        acceptedButtons: Qt.AllButtons
        onClicked: mouse => {
            if (mouse.button === Qt.LeftButton)
                root.shelf.close();
        }
        onWheel: wheel => wheel.accepted = true
        Accessible.name: "Close image preview"
    }

    Rectangle {
        id: modal
        x: root.regions.bounds?.x ?? 0
        y: root.regions.bounds?.y ?? 0
        width: root.regions.bounds?.width ?? 0
        height: root.regions.bounds?.height ?? 0
        color: root.application.colors.panel_bg
        border.color: root.application.colors.accent
        border.width: root.physicalPixel

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => mouse.accepted = true
            onWheel: wheel => wheel.accepted = true
        }

        CellText {
            x: root.regions.title?.x ?? 0
            y: root.regions.title?.y ?? 0
            width: root.regions.title?.width ?? 0
            height: root.regions.title?.height ?? 0
            text: "Image preview"
            grid: root.grid
            color: root.application.colors.accent
            bold: true
        }

        CellText {
            x: root.regions.close?.x ?? 0
            y: root.regions.close?.y ?? 0
            width: root.regions.close?.width ?? 0
            height: root.regions.close?.height ?? 0
            text: "×"
            grid: root.grid
            color: root.application.colors.subtext0

            MouseArea {
                anchors.fill: parent
                onClicked: root.shelf.close()
                Accessible.name: "Close image preview"
            }
        }

        Item {
            x: root.regions.image?.x ?? 0
            y: root.regions.image?.y ?? 0
            width: root.regions.image?.width ?? 0
            height: root.regions.image?.height ?? 0
            clip: true

            AttachmentImage {
                readonly property real fit: Math.min(parent.width / Math.max(1, root.state.width ?? 0), parent.height / Math.max(1, root.state.height ?? 0))
                width: Math.max(0, (root.state.width ?? 0) * fit)
                height: Math.max(0, (root.state.height ?? 0) * fit)
                anchors.centerIn: parent
                image: root.shelf.image(root.state.id ?? "", true)
            }
        }

        CellText {
            x: root.regions.footer?.x ?? 0
            y: root.regions.footer?.y ?? 0
            width: root.regions.footer?.width ?? 0
            height: root.regions.footer?.height ?? 0
            text: "Esc close"
            grid: root.grid
            color: root.application.colors.subtext0
        }
    }
}
