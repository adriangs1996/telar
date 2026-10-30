pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick

Rectangle {
    id: root

    required property GuiController application
    property real ratio: application.chromeRatio
    readonly property var shelf: application.attachments
    readonly property bool modalOpen: (shelf.modal.id ?? "").length > 0
    readonly property var region: application.attachmentGeometry
    readonly property real padding: 6 * ratio
    readonly property real gap: 6 * ratio
    readonly property real closeSide: 18 * ratio
    readonly property real cardWidth: Math.min(180 * ratio, (width - padding * 2 - Math.max(0, shelf.items.length - 1) * gap) / Math.max(1, shelf.items.length))
    x: region.x ?? 0
    y: region.y ?? 0
    width: region.width ?? 0
    height: region.height ?? 0
    visible: width > 0 && height > 0 && shelf.items.length > 0
    color: application.colors.panelBackground
    clip: true

    function hovered(area): bool {
        if (modalOpen)
            return false;
        if (shelf.hoverReady)
            return area.containsMouse;
        if (!shelf.hoverKnown)
            return false;
        const point = area.mapFromItem(null, shelf.hoverPosition);
        return point.x >= 0 && point.y >= 0 && point.x < area.width && point.y < area.height;
    }

    Repeater {
        model: root.shelf.items
        delegate: NativeRoundedRectangle {
            id: card

            required property var modelData
            required property int index
            x: root.padding + index * (root.cardWidth + root.gap)
            y: root.padding
            width: root.cardWidth
            height: Math.max(0, root.height - root.padding * 2)
            radius: 8 * root.ratio
            color: root.hovered(pointer) ? root.application.colors.surface1 : root.application.colors.surface0

            MouseArea {
                id: pointer
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.shelf.open(card.modelData.id)
                Accessible.role: Accessible.Button
                Accessible.name: "Open image preview"
            }

            AttachmentImage {
                readonly property real fit: Math.min((card.width - root.padding * 2) / card.modelData.width, (card.height - root.padding * 2) / card.modelData.height)
                width: Math.max(0, card.modelData.width * fit)
                height: Math.max(0, card.modelData.height * fit)
                anchors.centerIn: parent
                thumbnail: true
                image: root.shelf.image(card.modelData.id, false)
            }

            NativeRoundedRectangle {
                x: card.width - root.closeSide - root.padding
                y: root.padding
                width: root.closeSide
                height: root.closeSide
                radius: root.closeSide / 2
                color: root.application.colors.surface1

                ChromeText {
                    anchors.fill: parent
                    text: "×"
                    color: root.hovered(closePointer) ? root.application.colors.red : root.application.colors.subtext0
                    horizontalAlignment: Text.AlignHCenter
                    pixelSize: root.application.windowGeometry.typography.body
                    emphasized: true
                }

                MouseArea {
                    id: closePointer
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.shelf.dismiss(card.modelData.id)
                    Accessible.role: Accessible.Button
                    Accessible.name: "Remove image"
                }
            }
        }
    }
}
