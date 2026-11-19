pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick
import QtQuick.Controls

// A configured panel: a title line with refresh and close, the rendered blocks, and a footer that
// says how fresh they are and holds the panel's trailing actions.
Popup {
    id: root

    required property ComponentsController controller
    // The host metrics, by name, that metric nodes read.
    property var hostMetrics: ({})
    // The machine chrome that `ui.builtin("machines")` shows.
    property MachineChromeController machineChrome: null
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var state: controller.panel
    readonly property var anchor: state.anchor ?? Qt.point(-1, -1)
    readonly property real margin: 12 * ratio
    readonly property real inset: 16 * ratio
    readonly property real buttonSide: 26 * ratio
    readonly property real headerHeight: Math.max(buttonSide, typography.bodyRow) + 2 * margin
    readonly property real footerHeight: 28 * ratio + 2 * 6 * ratio
    readonly property real maximumHeight: Math.max(headerHeight, (parent?.height ?? 640) - 2 * margin)
    readonly property real settledY: Math.max(margin, Math.min((parent?.height ?? height) - height - margin, anchor.y >= 0 ? (anchor.y > height + margin ? anchor.y - height - margin : anchor.y + headerHeight) : (parent?.height ?? height) - height - 36 * ratio))
    readonly property real entranceOffset: Math.min(12 * ratio, Math.max(0, (parent?.height ?? height) - settledY - height - margin))
    // A trailing `ui.actions` block sits in the footer, beside the freshness note.
    readonly property var topNodes: (state.nodes ?? []).filter(node => node.parent === -1 && !node.tooltip)
    readonly property var footerActions: topNodes.length > 0 && topNodes[topNodes.length - 1].kind === "actions" ? topNodes[topNodes.length - 1] : null
    readonly property var bodyRoots: footerActions === null ? [] : topNodes.slice(0, topNodes.length - 1).map(node => node.index)
    readonly property bool hasBody: footerActions === null || bodyRoots.length > 0
    property real now: Date.now()
    readonly property string freshness: {
        const at = root.state.renderedAt ?? 0;
        if (at <= 0) {
            return "Loading…";
        }

        const minutes = Math.floor((root.now - at) / 60000);
        if (minutes < 1) {
            return "Updated just now";
        }

        return minutes < 60 ? "Updated " + minutes + " min ago" : "Updated at " + Qt.formatTime(new Date(at), "HH:mm");
    }

    ModalRevealLayout {
        id: motion
        objectName: "componentPanelMotion"
        active: root.visible
        generation: root.state.identity ?? ""
    }
    visible: state.open ?? false
    focus: !(controller.pick.open ?? false)
    modal: false
    padding: 0
    width: Math.max(0, Math.min((state.width ?? 420) * ratio, (parent?.width ?? 720) - 2 * margin))
    height: Math.min(maximumHeight, headerHeight + (hasBody ? body.implicitHeight + margin : 0) + (errorText.visible ? errorText.implicitHeight + margin : 0) + footerHeight)
    x: Math.max(margin, Math.min((parent?.width ?? width) - width - margin, (anchor.x >= 0 ? anchor.x : (parent?.width ?? width) / 2) - width / 2))
    y: settledY + entranceOffset * (1 - motion.reveal)
    opacity: motion.reveal
    objectName: "configuredPanel"
    closePolicy: (controller.pick.open ?? false) ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: DialogSurface { colors: root.colors; ratio: root.ratio }
    onClosed: if (state.open) controller.closePanel()

    // The freshness note counts minutes only while the panel shows.
    Timer {
        interval: 30000
        repeat: true
        running: root.visible
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    contentItem: Item {
        OverlayHeader {
            x: root.inset
            y: root.margin
            width: Math.max(0, parent.width - root.inset - root.margin)
            height: root.headerHeight - 2 * root.margin
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            title: root.state.title ?? ""

            ChromeIconButton {
                width: root.buttonSide
                height: root.buttonSide
                anchors.verticalCenter: parent.verticalCenter
                colors: root.colors
                glyph: "\uf021"
                pixelSize: root.typography.small
                cornerRadius: ChromeStyle.controlRadius * root.ratio
                Accessible.name: "Refresh panel"
                onClicked: root.controller.refreshPanel()
            }

            ChromeIconButton {
                width: root.buttonSide
                height: root.buttonSide
                anchors.verticalCenter: parent.verticalCenter
                colors: root.colors
                glyph: "\uf00d"
                pixelSize: root.typography.small
                cornerRadius: ChromeStyle.controlRadius * root.ratio
                objectName: "overlayClose"
                Accessible.name: "Close panel"
                onClicked: root.controller.closePanel()
            }
        }

        Flickable {
            id: body
            x: root.inset
            y: root.headerHeight
            width: Math.max(0, parent.width - 2 * root.inset)
            height: Math.max(0, parent.height - y - root.footerHeight - root.margin - (errorText.visible ? errorText.implicitHeight + root.margin : 0))
            implicitHeight: Math.min(tree.implicitHeight, root.maximumHeight)
            contentHeight: tree.implicitHeight
            clip: true
            visible: root.hasBody
            ComponentTree {
                id: tree
                width: parent.width
                controller: root.controller
                hostMetrics: root.hostMetrics
                machineChrome: root.machineChrome
                surface: root.state
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                horizontal: false
                roots: root.bodyRoots
                gap: 14 * root.ratio
            }
            ScrollBar.vertical: ScrollBar {}
        }

        Text {
            id: errorText
            x: root.inset
            y: parent.height - root.footerHeight - root.margin - implicitHeight
            width: Math.max(0, parent.width - 2 * root.inset)
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

        Item {
            id: footer
            y: parent.height - root.footerHeight
            width: parent.width
            height: root.footerHeight

            Rectangle {
                width: parent.width
                height: Math.min(root.ratio, parent.height)
                color: root.colors.surface1
            }

            ChromeText {
                objectName: "componentPanelFreshness"
                x: root.inset
                width: Math.max(0, actions.x - x - root.margin)
                height: parent.height
                text: root.freshness
                color: root.colors.subtext0
                pixelSize: root.typography.small
            }

            ComponentBranch {
                id: actions
                x: parent.width - width - root.margin
                y: (parent.height - height) / 2
                width: implicitWidth
                height: 28 * root.ratio
                active: root.footerActions !== null
                controller: root.controller
                hostMetrics: root.hostMetrics
                machineChrome: root.machineChrome
                surface: root.state
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: 28 * root.ratio
                roots: root.footerActions !== null ? [root.footerActions.index] : []
                fit: false
            }
        }
    }
}
