pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui
import "Elements.js" as Elements

// One element a mod returned. Containers lay out their children with ElementLayout, which
// reads each child's `element` record; leaves draw text, icons, marks, canvases or a
// built-in QML piece the host provides.
Item {
    id: node

    required property var host
    property var element: null
    readonly property string kind: element?.kind ?? ""
    readonly property bool container: kind === "row" || kind === "column" || kind === "stack"
    readonly property real ratio: host?.ratio ?? 1
    readonly property var padding: element?.padding ?? [0, 0, 0, 0]
    readonly property bool clickable: element?.clickable ?? false
    readonly property string tooltip: element?.tooltip ?? ""
    // A tile's box follows the tile's own rounding unless the mod sets a radius.
    readonly property real boxRadius: (element?.radius ?? 0) > 0 ? element.radius * ratio : kind === "tile" ? Math.round(height * 0.3) : 0
    readonly property var entries: container ? (host?.nodes ?? []).filter(child => child.parent === element.index) : []
    property bool modelReady: false

    implicitWidth: container ? layout.implicitWidth : (leaf.item?.implicitWidth ?? 0) + (padding[0] + padding[2]) * ratio
    implicitHeight: container ? layout.implicitHeight : (leaf.item?.implicitHeight ?? 0) + (padding[1] + padding[3]) * ratio
    clip: element?.clip ?? false

    function reconcile() {
        if (!modelReady) return;
        for (let index = 0; index < entries.length; ++index) {
            const record = entries[index];
            const key = record.key.length > 0 ? "id:" + record.key : "at:" + index + ":" + record.kind;
            let found = index;
            while (found < retained.count && retained.get(found).identity !== key) ++found;
            if (found === retained.count) {
                retained.insert(index, {identity: key, record: record});
            } else {
                if (found !== index) retained.move(found, index, 1);
                retained.setProperty(index, "record", record);
            }
        }
        if (retained.count > entries.length) retained.remove(entries.length, retained.count - entries.length);
    }

    onEntriesChanged: reconcile()
    Component.onCompleted: {
        modelReady = true;
        reconcile();
    }

    ElevationShadow {
        anchors.fill: parent
        ratio: node.ratio
        cornerRadius: node.boxRadius
        visible: node.element?.shadow ?? false
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        readonly property var fill: pointer.hovered && node.element?.hover ? node.element.hover : node.element?.background
        radius: node.boxRadius
        color: fill ?? "transparent"
        borderColor: node.element?.border ?? "transparent"
        borderWidth: (node.element?.borderWidth ?? 0) * node.ratio
        visible: fill !== undefined || (node.element?.borderWidth ?? 0) > 0
    }

    ListModel {
        id: retained
        dynamicRoles: true
    }

    ElementLayout {
        id: layout
        anchors.fill: parent
        visible: node.container
        // ElementLayout::Direction: 0 row, 1 column, 2 stack.
        direction: node.kind === "column" ? 1 : node.kind === "stack" ? 2 : 0
        gap: node.element?.gap ?? 0
        padding: node.padding
        align: node.element?.align ?? 0
        justify: node.element?.justify ?? 0
        ratio: node.ratio

        Repeater {
            model: node.container ? retained : null
            delegate: Loader {
                id: child
                required property var record
                readonly property var element: record
                // Containers nest through a Loader so a component may contain itself.
                // The layout sizes the Loader, and a sized Loader sizes its item.
                Component.onCompleted: setSource(Qt.resolvedUrl("ElementNode.qml"), {host: node.host, element: Qt.binding(() => child.record)})
            }
        }
    }

    Loader {
        id: leaf
        x: node.padding[0] * node.ratio
        y: node.padding[1] * node.ratio
        width: Math.max(0, node.width - (node.padding[0] + node.padding[2]) * node.ratio)
        height: Math.max(0, node.height - (node.padding[1] + node.padding[3]) * node.ratio)
        active: !node.container && node.kind.length > 0
        sourceComponent: {
            switch (node.kind) {
            case "label":
            case "elapsed":
            case "clock": return label;
            case "icon": return icon;
            case "mark": return mark;
            case "badge": return badge;
            case "tile": return tile;
            case "canvas": return canvas;
            case "builtin": return node.host?.builtins?.[node.element?.text] ?? null;
            default: return spacer;
            }
        }
    }

    HoverHandler {
        id: pointer
        enabled: node.clickable || node.tooltip.length > 0 || node.element?.hover !== undefined
        cursorShape: node.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
    }

    TapHandler {
        enabled: node.clickable
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: node.host?.activate(node.element)
    }

    ToolTip.visible: pointer.hovered && tooltip.length > 0
    ToolTip.text: tooltip
    ToolTip.delay: 500

    Accessible.role: clickable ? Accessible.Button : Accessible.StaticText
    Accessible.name: element?.text ?? ""

    Component {
        id: spacer
        Item {}
    }

    Component {
        id: label
        Item {
            readonly property real pixelSize: (node.element?.size ?? 0) > 0 ? node.element.size * node.ratio : ([node.host?.typography?.title, node.host?.typography?.body, node.host?.typography?.small][node.element?.sizeRole ?? 1] ?? 0)
            readonly property string shown: node.kind === "elapsed" ? Elements.elapsed(node.element.since, clock.now) : node.kind === "clock" ? Elements.clock(node.element.text, clock.now) : node.element?.text ?? ""
            implicitWidth: (node.element?.maxLines ?? 1) > 1 ? wrapped.implicitWidth : single.implicitWidth
            implicitHeight: (node.element?.maxLines ?? 1) > 1 ? wrapped.implicitHeight : pixelSize * 1.3

            ChromeText {
                id: single
                anchors.fill: parent
                visible: (node.element?.maxLines ?? 1) <= 1
                text: parent.shown
                pixelSize: parent.pixelSize
                color: node.element?.color ?? node.host?.colors?.text
                emphasized: node.element?.bold ?? false
            }

            Text {
                id: wrapped
                anchors.fill: parent
                visible: (node.element?.maxLines ?? 1) > 1
                text: parent.shown
                font.family: "IBM Plex Sans"
                font.pixelSize: parent.pixelSize
                font.weight: (node.element?.bold ?? false) ? Font.DemiBold : Font.Normal
                font.italic: node.element?.italic ?? false
                color: node.element?.color ?? node.host?.colors?.text
                wrapMode: Text.Wrap
                maximumLineCount: node.element?.maxLines ?? 1
                elide: Text.ElideRight
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
            }

            // Time-based labels tick here, never in Lua.
            Timer {
                id: clock
                property double now: Date.now()
                interval: node.kind === "clock" && !(node.element?.text ?? "").includes("%S") ? 60000 - (Date.now() % 60000) : 1000
                running: (node.kind === "elapsed" || node.kind === "clock") && node.visible
                repeat: true
                onTriggered: now = Date.now()
            }
        }
    }

    Component {
        id: icon
        ChromeIcon {
            glyph: node.element?.glyph ?? ""
            color: node.element?.color ?? node.host?.colors?.text
            pixelSize: (node.element?.size ?? 0) > 0 ? node.element.size * node.ratio : 14 * node.ratio
            implicitWidth: pixelSize
            implicitHeight: pixelSize
        }
    }

    Component {
        id: mark
        ApplicationMark {
            mark: node.element
            colors: node.host?.colors
            pixelSize: 14 * node.ratio
            ratio: node.ratio
            implicitWidth: pixelSize
            implicitHeight: pixelSize
        }
    }

    Component {
        id: badge
        NativeRoundedRectangle {
            readonly property real pixelSize: (node.element?.size ?? 0) > 0 ? node.element.size * node.ratio : node.host?.typography?.small
            implicitWidth: badgeText.implicitWidth + 12 * node.ratio
            implicitHeight: pixelSize * 1.6
            radius: height / 2
            color: Qt.alpha(node.element?.color ?? node.host?.colors?.text, 0.16)
            ChromeText {
                id: badgeText
                anchors.centerIn: parent
                text: node.element?.text ?? ""
                pixelSize: parent.pixelSize
                color: node.element?.color ?? node.host?.colors?.text
                emphasized: true
            }
        }
    }

    Component {
        id: tile
        ApplicationTile {
            mark: node.element
            colors: node.host?.colors
            typography: node.host?.typography
            ratio: node.ratio
            // The same proportion as the tab cards: about a third of the tile's height.
            radius: Math.round(height * 0.3)
            implicitWidth: ((node.element?.size ?? 0) > 0 ? node.element.size : 18) * node.ratio
            implicitHeight: implicitWidth * 0.78
        }
    }

    Component {
        id: canvas
        ElementCanvas {
            operations: node.element?.operations ?? []
            ratio: node.ratio
            implicitWidth: Math.max(0, node.element?.width ?? 0) * node.ratio
            implicitHeight: Math.max(0, node.element?.height ?? 0) * node.ratio
            Accessible.role: Accessible.Graphic
            Accessible.name: node.element?.text ?? ""
        }
    }
}
