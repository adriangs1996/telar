pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick

Item {
    id: root

    required property GuiController application
    property real ratio: 1
    property bool keyboardCovered: false

    AttachmentShelf {
        application: root.application
        ratio: root.ratio
    }

    Repeater {
        model: root.application.panes

        delegate: Item {
            id: pane

            required property var record
            readonly property bool framed: record.framed
            x: record.x
            y: record.y
            width: record.width
            height: record.height
            Repeater {
                model: pane.record.panels

                delegate: Rectangle {
                    required property rect modelData
                    x: modelData.x
                    y: modelData.y
                    width: modelData.width
                    height: modelData.height
                    color: root.application.colors.panelBackground

                    MouseArea {
                        anchors.fill: parent
                        onPressed: root.application.execute(GuiController.Action.focus_pane, pane.record.key)
                    }
                }
            }

            NativeRoundedRectangle {
                objectName: "paneFrame"
                x: pane.record.frame.x
                y: pane.record.frame.y
                width: pane.record.frame.width
                height: pane.record.frame.height
                borderColor: pane.record.focused ? root.application.colors.accent : root.application.colors.overlay0
                borderWidth: pane.record.frameLineWidth
                radius: pane.record.frameRadius * root.ratio
                visible: pane.framed
            }

            PaneHeader {
                id: header

                x: 0
                y: 0
                width: parent.width
                height: pane.framed ? Math.min(parent.height, root.application.windowGeometry.paneHeader, root.application.windowGeometry.typography.grid.cellHeight) : 0
                visible: pane.framed && !pane.record.fullscreen
                record: pane.record.chrome
                colors: root.application.colors
                typography: root.application.windowGeometry.typography
                ratio: root.ratio
                bandHeight: root.application.windowGeometry.paneHeader

                MouseArea {
                    anchors.fill: parent
                    onPressed: root.application.execute(GuiController.Action.focus_pane, pane.record.key)
                }
            }

            TerminalView {
                id: terminal

                x: pane.record.content.x
                y: pane.record.content.y
                width: pane.record.content.width
                height: pane.record.content.height
                application: root.application
                paneId: pane.record.key
                focus: pane.record.focused && root.application.dialog.length === 0 && !root.keyboardCovered

                Rectangle {
                    anchors.fill: parent
                    visible: pane.framed && !pane.record.focused
                    color: Qt.rgba(root.application.colors.background.r, root.application.colors.background.g, root.application.colors.background.b, 1)
                    opacity: pane.record.dimAlpha
                }

                LinkPreview {
                    preview: terminal.linkPreview
                    colors: root.application.colors

                    function publishBounds() {
                        terminal.setLinkPreviewBounds(visible ? Qt.rect(x, y, width, height) : Qt.rect(0, 0, 0, 0));
                    }

                    onVisibleChanged: publishBounds()
                    onXChanged: publishBounds()
                    onYChanged: publishBounds()
                    onWidthChanged: publishBounds()
                    onHeightChanged: publishBounds()
                }

                Connections {
                    target: root.application
                    function onDialogChanged() {
                        if (root.application.dialog.length === 0 && pane.record.focused && !root.keyboardCovered)
                            terminal.forceActiveFocus();
                    }
                }
            }

            Loader {
                y: pane.height - height
                width: pane.width
                height: Math.min(pane.height, root.application.windowGeometry.typography.grid.cellHeight)
                active: pane.framed && pane.record.fullscreen
                sourceComponent: FullscreenStrip {
                    objectName: "paneFullscreenStrip"
                    entries: pane.record.fullscreenEntries ?? []
                    record: pane.record.chrome
                    colors: root.application.colors
                    typography: root.application.windowGeometry.typography
                    ratio: root.ratio
                    bandHeight: root.application.windowGeometry.paneHeader
                    onSelected: key => root.application.execute(GuiController.Action.focus_pane, key)
                    onLeaveFullscreen: root.application.execute(GuiController.Action.fullscreen)
                }
            }

            Loader {
                x: pane.record.frame.x
                y: pane.record.frame.y
                width: pane.record.frame.width
                height: pane.record.frame.height
                active: pane.framed && !pane.record.focused && (pane.record.chrome.needsAttention ?? false)
                sourceComponent: NativePaneAttention {
                    objectName: "paneAttentionRing"
                    attachment: pane.record.attentionKey
                    active: true
                    ratio: root.ratio
                    color: root.application.colors[pane.record.chrome.agent.statusColor ?? "overlay1"]
                }
            }
        }
    }

    Repeater {
        model: root.application.dividers

        delegate: MouseArea {
            required property var record
            readonly property real hitWidth: 8 * root.ratio
            x: record.horizontal ? record.x + (record.width - hitWidth) / 2 : record.x
            y: record.horizontal ? record.y : record.y + (record.height - hitWidth) / 2
            width: record.horizontal ? hitWidth : record.width
            height: record.horizontal ? record.height : hitWidth
            cursorShape: record.horizontal ? Qt.SplitHCursor : Qt.SplitVCursor
            preventStealing: true

            function resize(mouse, commit) {
                const position = mapToItem(root, mouse.x, mouse.y);
                root.application.resizeDivider(Number(record.key), position.x, position.y, commit);
            }

            onPositionChanged: mouse => {
                if (pressed)
                    resize(mouse, false);
            }
            onReleased: mouse => resize(mouse, true)
        }
    }
}
