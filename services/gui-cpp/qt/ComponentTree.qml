pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "ComponentFit.js" as ComponentFit

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
    property real gap: 8 * ratio
    readonly property var entries: (surface.nodes ?? []).filter(node => node.parent === parentIndex && node.tooltip === tooltip && (roots.length === 0 || roots.indexOf(node.index) >= 0))
    property var fittedLevels: null
    property var reductions: ({})
    readonly property var levels: fittedLevels ?? reductions
    property var fitNodes: []
    property real fullWidth: 0
    property bool modelReady: false
    readonly property string sourceIdentity: surface.identity + ":" + surface.generation + ":" + surface.source
    readonly property real overflowWidth: overflowMeasure.implicitWidth + 12 * ratio
    readonly property var hiddenRoots: entries.filter((node, index) => (levels[node.index] ?? ComponentFit.Level.full) === ComponentFit.Level.hidden).map(node => node.index)

    implicitWidth: horizontal ? row.implicitWidth : column.implicitWidth
    implicitHeight: horizontal ? rowHeight : column.implicitHeight

    function reconcileEntries() {
        if (!modelReady) {
            return;
        }

        for (let index = 0; index < entries.length; ++index) {
            const record = entries[index];
            const key = sourceIdentity + ":" + record.index + ":" + record.kind + ":" + (record.actionIdentity ?? "");
            let found = index;
            while (found < retained.count && retained.get(found).key !== key) {
                ++found;
            }

            if (found === retained.count) {
                retained.insert(index, {
                    key,
                    record
                });
            } else {
                if (found !== index) {
                    retained.move(found, index, 1);
                }

                retained.setProperty(index, "record", record);
            }
        }

        if (retained.count > entries.length) {
            retained.remove(entries.length, retained.count - entries.length);
        }
    }

    function refit() {
        let nodes = [];
        for (let index = 0; index < rowRepeater.count; ++index) {
            nodes = nodes.concat(rowRepeater.itemAt(index)?.fitNodes ?? []);
        }
        fitNodes = nodes;
        fullWidth = ComponentFit.measure(fitNodes, {}, gap).width;
        reductions = !fit || width <= 0 || fittedLevels !== null ? {} : ComponentFit.fit(fitNodes, width, gap, overflow.implicitWidth);
    }

    onWidthChanged: Qt.callLater(refit)
    onEntriesChanged: {
        reconcileEntries();
        Qt.callLater(refit);
    }
    onSourceIdentityChanged: reconcileEntries()
    onFitChanged: Qt.callLater(refit)
    onGapChanged: Qt.callLater(refit)

    Component.onCompleted: {
        modelReady = true;
        reconcileEntries();
    }

    ListModel {
        id: retained
        dynamicRoles: true
    }

    Row {
        id: row
        spacing: root.gap
        visible: root.horizontal

        Repeater {
            id: rowRepeater
            model: root.horizontal ? retained : null
            onItemAdded: Qt.callLater(root.refit)
            onItemRemoved: Qt.callLater(root.refit)

            delegate: ComponentNode {
                required property var record
                required property int index
                controller: root.controller
                surface: root.surface
                node: record
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.rowHeight
                width: implicitWidth
                height: root.rowHeight
                fittedLevels: root.levels
                barGroup: root.parentIndex < 0
                compact: (root.levels[node.index] ?? ComponentFit.Level.full) === ComponentFit.Level.compact
                visible: (root.levels[node.index] ?? ComponentFit.Level.full) !== ComponentFit.Level.hidden
                onFitNodesChanged: Qt.callLater(root.refit)
            }
        }

        AbstractButton {
            id: overflow
            objectName: "componentOverflow"
            visible: root.fit && root.hiddenRoots.length > 0
            implicitWidth: root.overflowWidth
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
                color: overflow.hovered || overflow.activeFocus ? root.colors.surface1 : "transparent"
                radius: 4 * root.ratio
            }
            Keys.onEscapePressed: event => {
                overflow.focus = false;
                event.accepted = false;
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
            model: root.horizontal ? null : retained

            delegate: ComponentNode {
                required property var record
                controller: root.controller
                surface: root.surface
                node: record
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.rowHeight
                width: root.width
                height: implicitHeight
            }
        }
    }

    Text {
        id: overflowMeasure
        visible: false
        text: "+" + "9".repeat(Math.max(1, root.entries.length).toString().length)
        font.family: "IBM Plex Sans"
        font.pixelSize: root.typography.small
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
    }

    Popup {
        id: overflowPopup
        Connections {
            target: overflowPopup.visible ? root.controller : null
            function onComponentsChanged() {
                if (root.controller.componentPanel.open ?? false) {
                    overflowPopup.close();
                }
            }
        }
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
