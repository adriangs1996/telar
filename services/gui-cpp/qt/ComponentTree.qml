pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

Item {
    id: root

    required property var controller
    required property var surface
    required property var colors
    required property var typography
    property real ratio: 1
    property int parentIndex: -1
    property bool tooltip: false
    property bool horizontal: true
    property bool fit: horizontal && parentIndex < 0
    property var roots: []
    property real rowHeight: 28 * ratio
    readonly property real gap: 8 * ratio
    readonly property var entries: (surface.nodes ?? []).filter(node => node.parent === parentIndex && node.tooltip === tooltip && (parentIndex >= 0 || roots.length === 0 || roots.indexOf(node.index) >= 0))
    property var reductions: []
    property real fullWidth: 0
    readonly property var hiddenRoots: entries.filter((node, index) => (reductions[index] ?? 0) === 2).map(node => node.index)

    implicitWidth: horizontal ? row.implicitWidth : column.implicitWidth
    implicitHeight: horizontal ? rowHeight : column.implicitHeight

    function refit() {
        const reduced = entries.map(() => 0);
        const widths = entries.map((node, index) => rowRepeater.itemAt(index)?.unreducedWidth ?? 0);
        const compactWidths = entries.map((node, index) => rowRepeater.itemAt(index)?.compactWidthDelta ?? 0);
        fullWidth = widths.reduce((sum, value) => sum + value, 0) + Math.max(0, entries.length - 1) * gap;
        if (!fit || width <= 0) {
            reductions = reduced;
            return;
        }
        let total = fullWidth;
        let hidden = 0;
        for (let step = 0; step < 2 * entries.length && total + (hidden > 0 ? overflow.implicitWidth + gap : 0) > width; ++step) {
            let chosen = -1;
            for (let index = 0; index < entries.length; ++index) {
                if (reduced[index] === 2) continue;
                if (chosen < 0 || entries[index].priority <= entries[chosen].priority) chosen = index;
            }
            if (chosen < 0) break;
            if (entries[chosen].kind === "meter" && reduced[chosen] === 0) {
                reduced[chosen] = 1;
                total -= compactWidths[chosen];
            } else {
                const previous = reduced[chosen];
                reduced[chosen] = 2;
                total -= widths[chosen] - (previous === 1 ? compactWidths[chosen] : 0) + (entries.length - hidden > 1 ? gap : 0);
                ++hidden;
            }
        }
        reductions = reduced;
    }

    onWidthChanged: Qt.callLater(refit)
    onEntriesChanged: Qt.callLater(refit)
    onFitChanged: Qt.callLater(refit)

    Row {
        id: row
        spacing: root.gap
        visible: root.horizontal

        Repeater {
            id: rowRepeater
            model: root.horizontal ? root.entries : []

            delegate: ComponentNode {
                required property var modelData
                required property int index
                controller: root.controller
                surface: root.surface
                node: modelData
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.rowHeight
                width: implicitWidth
                height: root.rowHeight
                compact: (root.reductions[index] ?? 0) === 1
                visible: (root.reductions[index] ?? 0) !== 2
                onImplicitWidthChanged: Qt.callLater(root.refit)
            }
        }

        AbstractButton {
            id: overflow
            objectName: "componentOverflow"
            visible: root.fit && root.hiddenRoots.length > 0
            implicitWidth: overflowLabel.implicitWidth + 12 * root.ratio
            height: root.rowHeight
            hoverEnabled: true
            Accessible.name: "Show " + root.hiddenRoots.length + " hidden components"
            contentItem: Text {
                id: overflowLabel
                text: "+" + root.hiddenRoots.length
                color: root.colors.subtext0
                font.family: "IBM Plex Sans"
                font.pixelSize: root.typography.small
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                color: overflow.hovered ? root.colors.surface1 : "transparent"
                radius: 4 * root.ratio
            }
            onClicked: overflowPopup.open()
        }
    }

    Column {
        id: column
        width: root.width
        spacing: root.gap
        visible: !root.horizontal

        Repeater {
            model: root.horizontal ? [] : root.entries

            delegate: ComponentNode {
                required property var modelData
                controller: root.controller
                surface: root.surface
                node: modelData
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.rowHeight
                width: root.width
                height: implicitHeight
            }
        }
    }

    Popup {
        id: overflowPopup
        parent: root
        y: -height - root.gap
        width: Math.min(420 * root.ratio, root.Window.window?.width ?? 420 * root.ratio)
        padding: 12 * root.ratio
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: DialogSurface { colors: root.colors; ratio: root.ratio }
        contentItem: Flickable {
            implicitHeight: Math.min(480 * root.ratio, hiddenTree.implicitHeight)
            contentHeight: hiddenTree.implicitHeight
            clip: true
            ComponentBranch {
                id: hiddenTree
                active: overflowPopup.visible
                width: parent.width
                controller: root.controller
                surface: root.surface
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                horizontal: false
                roots: root.hiddenRoots
            }
        }
    }
}
