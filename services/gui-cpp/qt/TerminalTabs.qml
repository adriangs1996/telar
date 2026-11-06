pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    clip: true

    property var controller: null
    required property var model
    required property var colors
    required property var typography
    property real ratio: 1
    property real textScale: 1
    property bool prefixPending: false
    property rect createBounds
    readonly property real wellPadding: 3 * ratio
    readonly property real captionSize: typography.title
    readonly property real scaling: typography.title / 14
    signal selected(string key)
    signal closed(string key)
    signal renamed()

    TabStripLayout {
        id: layout
        objectName: "tabStripLayout"
        x: root.wellPadding
        width: Math.max(0, root.width - 2 * root.wellPadding)
        height: root.height
        model: root.model
        ratio: root.ratio * root.scaling
        hovered: pointer.hovered
        plus: Qt.rect(root.createBounds.x - x, root.createBounds.y, root.createBounds.width, root.createBounds.height)
        font.family: "IBM Plex Sans"
        font.pixelSize: root.captionSize
        // Reserve the heavier label width so selection does not shift adjacent tabs.
        font.weight: Font.DemiBold
        pixelSize: root.captionSize
    }

    HoverHandler {
        id: pointer
    }

    Component.onCompleted: {
        if (root.controller) root.controller.registerTabStrip(layout);
    }

    NativeRoundedRectangle {
        objectName: "tabWell"
        x: layout.x + layout.stripBounds.x - root.wellPadding
        y: layout.stripBounds.y - root.wellPadding
        width: Math.min(root.width, layout.stripBounds.width + 2 * root.wellPadding)
        height: Math.min(root.height, layout.stripBounds.height + 2 * root.wellPadding)
        radius: height / 2
        color: Qt.alpha(root.colors.chromeText, 0.07)
        visible: layout.stripBounds.width > 0
    }

    NativeRoundedRectangle {
        objectName: "tabSelectionShadow"
        x: layout.x + layout.selectionBounds.x
        y: layout.selectionBounds.y + root.ratio
        width: layout.selectionBounds.width
        height: layout.selectionBounds.height
        radius: layout.style.pillRadius
        color: "black"
        opacity: 0.18
        visible: width > 0 && height > 0
    }

    // The selection is a lens: its rim carries the signal, its fill stays close to the surface.
    NativeRoundedRectangle {
        objectName: "tabSelection"
        x: layout.x + layout.selectionBounds.x
        y: layout.selectionBounds.y
        width: layout.selectionBounds.width
        height: layout.selectionBounds.height
        radius: layout.style.pillRadius
        color: Qt.alpha(root.colors.chromeText, 0.05)
        borderColor: root.colors.chromeText
        borderAlpha: 0.32
        borderWidth: root.ratio
        visible: width > 0 && height > 0
    }

    NativeRoundedRectangle {
        x: layout.x + layout.dropMarker.x
        y: layout.dropMarker.y
        width: layout.dropMarker.width
        height: layout.dropMarker.height
        radius: layout.style.pillRadius
        color: "transparent"
        borderColor: root.colors.surface1
        borderWidth: root.ratio
        visible: width > 0 && height > 0
    }

    Repeater {
        model: layout.items

        delegate: NativeRoundedRectangle {
            id: tab
            objectName: "tabPill"
            required property var record
            readonly property var source: record.tab
            readonly property string tabKey: source.key
            readonly property bool pointed: root.controller ? layout.hoveredTab === tabKey : mouse.containsMouse
            readonly property bool lit: source.selected || pointed

            x: layout.x + record.bounds.x
            y: record.bounds.y
            width: record.bounds.width
            height: record.bounds.height
            radius: layout.style.pillRadius
            color: pointed && !source.selected ? Qt.alpha(root.colors.chromeText, ChromeStyle.hoverAlpha) : "transparent"
            z: record.dragging ? 1 : 0

            Rectangle {
                objectName: "tabSeparator"
                x: parent.width - width
                y: (parent.height - height) / 2
                width: 1 / Screen.devicePixelRatio
                height: 14 * root.ratio
                color: root.colors.text
                opacity: 0.12
                visible: tab.record.separator && !tab.pointed
            }

            Repeater {
                model: tab.record.cards.length

                delegate: ApplicationTile {
                    required property int index
                    readonly property var card: tab.record.cards[index] ?? ({})
                    readonly property real rank: card.rank ?? 0
                    objectName: "tabCard"
                    x: tab.record.chip.x + (card.x ?? 0)
                    y: tab.record.chip.y + (tab.record.chip.height - height) / 2 + (card.y ?? 0)
                    z: card.layer ?? 0
                    width: layout.style.tileWidth
                    height: layout.style.tileHeight
                    rotation: card.rotation ?? 0
                    scale: card.scale ?? 1
                    radius: layout.style.tileRadius
                    visible: rank < 3
                    mark: card
                    attentionColor: rank > 0 ? (card.attentionColor ?? "") : ""
                    colors: root.colors
                    typography: root.typography
                    ratio: root.ratio
                    number: root.prefixPending && rank === 0 ? tab.source.number : ""
                    borderColor: "#0a0810"
                    borderAlpha: 0.72
                    borderWidth: root.ratio
                }
            }

            ChromeText {
                id: caption
                objectName: "tabCaption"
                x: tab.record.caption.x
                y: tab.record.caption.y
                width: Math.min(tab.record.caption.width, implicitWidth)
                height: tab.record.caption.height
                text: (tab.record.truncated && !root.prefixPending ? tab.source.number + " · " : "") + (tab.source.title ?? tab.source.label)
                pixelSize: root.captionSize
                color: tab.source.selected ? root.colors.chromeText : root.colors.text
                emphasized: true
                visible: !tab.record.compact
                elide: Text.ElideRight
            }

            ChromeText {
                objectName: "tabPath"
                x: caption.x + caption.width + layout.style.pathGap
                y: tab.record.caption.y
                width: Math.max(0, tab.record.caption.x + tab.record.caption.width - x)
                height: tab.record.caption.height
                text: tab.source.path ?? ""
                pixelSize: root.captionSize
                color: root.colors.subtext0
                visible: !tab.record.compact && width > 0 && text.length > 0
                elide: Text.ElideNone
                fadeWidth: implicitWidth > width ? layout.style.fadeWidth : 0
            }

            NativeTabActivity {
                objectName: "tabActivity"
                x: tab.record.status.x
                y: tab.record.status.y
                width: tab.record.status.width
                height: tab.record.status.height
                ratio: root.ratio
                record: tab.source
                color: root.colors[tab.source.activityColor ?? "teal"]
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                onPressed: event => {
                    if (event.button === Qt.LeftButton) {
                        if (root.controller) root.controller.selectCapturedTab();
                        else root.selected(tab.source.key);
                    }
                }
                onClicked: event => {
                    if (event.button === Qt.MiddleButton) {
                        root.closed(tab.source.key);
                    }
                }
                onDoubleClicked: root.renamed()
            }

            Accessible.role: Accessible.PageTab
            Accessible.name: (record.truncated ? source.number + ", " : "") + source.label
            Accessible.selected: source.selected
            Accessible.onPressAction: root.selected(source.key)
        }
    }

    NativeRoundedRectangle {
        objectName: "draggedTabOutline"
        z: 1
        x: layout.x + layout.draggedBounds.x
        y: layout.draggedBounds.y
        width: layout.draggedBounds.width
        height: layout.draggedBounds.height
        radius: layout.style.pillRadius
        color: "transparent"
        borderColor: root.colors.accent
        borderWidth: root.ratio
        visible: width > 0 && height > 0
    }

    ChromeButton {
        id: hiddenCounter
        z: 2
        pointerHovered: root.controller ? layout.hoveredTab === layout.counter.key : hovered
        objectName: "hiddenTabCounter"
        x: layout.x + (layout.counter.bounds?.x ?? 0)
        y: layout.counter.bounds?.y ?? 0
        width: layout.counter.bounds?.width ?? 0
        height: layout.counter.bounds?.height ?? 0
        visible: width > 0 && height > 0
        colors: root.colors
        pixelSize: root.typography.small
        cornerRadius: layout.style.pillRadius
        text: "+" + (layout.counter.count ?? 0)
        Accessible.name: "Nearest hidden tab"
        contentItem: Item {
            readonly property bool hasAttention: (layout.counter.attentionColor ?? "").length > 0
            readonly property real diameter: 6 * root.ratio
            readonly property real dotGap: 6 * root.ratio
            readonly property real reserve: hasAttention ? diameter + dotGap : 0
            readonly property real captionRoom: Math.max(0, width - 2 * reserve)

            ChromeText {
                x: parent.reserve + (parent.captionRoom - width) / 2
                width: Math.min(parent.captionRoom, implicitWidth)
                height: parent.height
                text: "+" + (layout.counter.count ?? 0)
                pixelSize: root.typography.small
                color: root.colors.text
                elide: Text.ElideNone
            }

            NativeRoundedRectangle {
                objectName: "hiddenTabAttention"
                x: Math.max(0, parent.width - parent.dotGap - parent.diameter)
                y: Math.max(0, (parent.height - parent.diameter) / 2)
                width: Math.min(parent.diameter, parent.width)
                height: Math.min(parent.diameter, parent.height)
                radius: parent.diameter / 2
                color: root.colors[layout.counter.attentionColor || "overlay1"]
                visible: parent.hasAttention
            }
        }
        onPressed: {
            if (root.controller) root.controller.selectCapturedTab();
            else root.selected(layout.counter.key);
        }
    }
}
