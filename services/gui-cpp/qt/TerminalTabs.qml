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
    readonly property real wellPadding: 3 * ratio
    signal selected(string key)
    signal closed(string key)
    signal renamed()
    signal created()

    TabStripLayout {
        id: layout
        objectName: "tabStripLayout"
        x: root.wellPadding
        width: Math.max(0, root.width - 2 * root.wellPadding)
        height: root.height
        model: root.model
        ratio: root.ratio
        hovered: pointer.hovered
        font.family: "IBM Plex Sans"
        font.pixelSize: root.typography.body
        font.weight: Font.Normal
        pixelSize: root.typography.body
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
        color: root.colors.text
        opacity: 0.045
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

    NativeRoundedRectangle {
        objectName: "tabSelection"
        x: layout.x + layout.selectionBounds.x
        y: layout.selectionBounds.y
        width: layout.selectionBounds.width
        height: layout.selectionBounds.height
        radius: layout.style.pillRadius
        color: root.colors.surface1
        borderColor: root.colors.text
        borderAlpha: 0.18
        borderWidth: 1 / Screen.devicePixelRatio
        visible: width > 0 && height > 0

        Rectangle {
            anchors.fill: parent
            anchors.margins: 1 / Screen.devicePixelRatio
            radius: Math.max(0, parent.radius - anchors.margins)
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(root.colors.text.r, root.colors.text.g, root.colors.text.b, 0.09) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
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
            color: pointed && !source.selected ? root.colors.surface0 : "transparent"
            clip: true
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

            NativeRoundedRectangle {
                x: tab.record.chip.x
                y: tab.record.chip.y
                width: tab.record.chip.width
                height: tab.record.chip.height
                radius: layout.style.chipRadius
                color: root.colors.text
                opacity: tab.source.selected ? layout.style.selectedChipAlpha : layout.style.chipAlpha
            }

            ApplicationMark {
                primaryFamily: root.typography.primaryFamily ?? ""
                primaryStyle: root.typography.primaryStyle ?? ""
                x: tab.record.chip.x + (tab.record.chip.width - width) / 2
                y: tab.record.chip.y + (tab.record.chip.height - height) / 2
                width: Math.min(tab.record.chip.width, layout.style.markSide)
                height: width
                mark: tab.source
                colors: root.colors
                dimmed: !tab.lit
                ratio: root.ratio
                pixelSize: root.typography.body
                visible: !root.prefixPending
            }

            ChromeText {
                objectName: "tabNumber"
                x: tab.record.chip.x + (tab.record.chip.width - width) / 2
                y: tab.record.chip.y
                width: Math.min(tab.record.chip.width, implicitWidth)
                height: tab.record.chip.height
                text: tab.source.number
                pixelSize: root.typography.small
                color: root.colors.text
                emphasized: true
                visible: root.prefixPending
                elide: Text.ElideNone
            }

            ChromeText {
                x: tab.record.caption.x
                y: tab.record.caption.y
                width: tab.record.caption.width
                height: tab.record.caption.height
                text: tab.source.label
                pixelSize: root.typography.body
                color: tab.lit ? root.colors.text : root.colors.subtext0
                visible: !tab.record.compact
                elide: Text.ElideNone
                fadeWidth: tab.record.truncated ? layout.style.fadeWidth : 0
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
            Accessible.name: source.label
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
                color: hiddenCounter.pointerHovered || hiddenCounter.visualFocus ? root.colors.text : root.colors.subtext0
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

    ChromeButton {
        objectName: "createTabButton"
        z: 2
        x: layout.x + layout.plus.x
        y: layout.plus.y
        width: layout.plus.width
        height: layout.plus.height
        visible: width > 0 && height > 0
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: layout.style.pillRadius
        text: "+"
        Accessible.name: "New tab"
        onClicked: root.created()
    }
}
