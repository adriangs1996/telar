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

    PaneMotionLayout {
        id: motion
        anchors.fill: parent
        model: root.application.panes
    }

    Repeater {
        model: motion.items

        delegate: Item {
            id: pane

            required property var record
            readonly property bool framed: record.framed
            x: record.visualBounds.x
            y: record.visualBounds.y
            width: record.visualBounds.width
            height: record.visualBounds.height
            readonly property real contentWidth: resizing ? Math.max(0, record.content.width + width - record.width) : record.content.width
            readonly property real contentHeight: resizing ? Math.max(0, record.content.height + height - record.height) : record.content.height
            readonly property real frameWidth: resizing ? Math.max(0, record.frame.width + width - record.width) : record.frame.width
            readonly property real frameHeight: resizing ? Math.max(0, record.frame.height + height - record.height) : record.frame.height
            readonly property bool resizing: width !== record.width || height !== record.height
            visible: width > 0 && height > 0

            Repeater {
                model: !pane.framed ? [] : !pane.resizing ? pane.record.panels : [
                    Qt.rect(0, 0, pane.frameWidth, pane.record.content.y),
                    Qt.rect(0, pane.record.content.y + pane.contentHeight, pane.frameWidth, Math.max(0, pane.frameHeight - pane.record.content.y - pane.contentHeight)),
                    Qt.rect(0, pane.record.content.y, pane.record.content.x, pane.contentHeight),
                    Qt.rect(pane.record.content.x + pane.contentWidth, pane.record.content.y, Math.max(0, pane.frameWidth - pane.record.content.x - pane.contentWidth), pane.contentHeight)
                ]

                delegate: Rectangle {
                    required property rect modelData
                    x: modelData.x
                    y: modelData.y
                    width: modelData.width
                    height: modelData.height
                    color: root.application.colors.panelBackground

                    MouseArea {
                        anchors.fill: parent
                        onPressed: {
                            root.application.execute(GuiController.Action.focus_pane, pane.record.key);
                            terminal.forceActiveFocus(Qt.MouseFocusReason);
                        }
                    }
                }
            }

            NativeRoundedRectangle {
                objectName: "paneFrame"
                x: pane.record.frame.x
                y: pane.record.frame.y
                width: pane.frameWidth
                height: pane.frameHeight
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
                    onPressed: {
                        root.application.execute(GuiController.Action.focus_pane, pane.record.key);
                        terminal.forceActiveFocus(Qt.MouseFocusReason);
                    }
                }
            }

            Item {
                id: viewport
                x: pane.record.content.x
                y: pane.record.content.y
                width: pane.contentWidth
                height: pane.contentHeight
                clip: true

                TerminalView {
                    id: terminal

                    // Commit the terminal grid once; animate only its viewport.
                    width: pane.record.content.width
                    height: pane.record.content.height
                    application: root.application
                    paneId: pane.record.key
                    property bool focusReady: false
                    readonly property bool modelFocused: pane.record.focused

                    function focusSelectedPane() {
                        if (terminal.modelFocused && root.application.dialog.length === 0 && !root.keyboardCovered) {
                            terminal.forceActiveFocus();
                        }
                    }

                    function restoreFocusIfVacant() {
                        const window = terminal.Window.window;
                        if (!window) {
                            return;
                        }

                        const owner = window.activeFocusItem;
                        // Visual loaders can inherit focus after their input control is retired.
                        if (owner && owner !== window.contentItem && !(owner instanceof Loader) && owner.visible && owner.enabled) {
                            return;
                        }

                        terminal.focusSelectedPane();
                    }

                    onVisibleChanged: {
                        if (visible && terminal.focusReady && terminal.modelFocused) {
                            Qt.callLater(terminal.focusSelectedPane);
                        }
                    }

                    // Geometry refreshes keep the same selection and must preserve chrome focus.
                    onModelFocusedChanged: {
                        if (!terminal.modelFocused) {
                            terminal.focus = false;
                        } else if (terminal.focusReady) {
                            terminal.focusSelectedPane();
                        }
                    }
                    Component.onCompleted: {
                        terminal.focusReady = true;
                        terminal.focusSelectedPane();
                    }

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
                            terminal.focusSelectedPane();
                        }
                    }

                    Connections {
                        target: terminal.Window.window
                        function onActiveFocusItemChanged() {
                            if (terminal.modelFocused) {
                                Qt.callLater(terminal.restoreFocusIfVacant);
                            }
                        }
                    }

                    Connections {
                        target: root
                        function onKeyboardCoveredChanged() {
                            if (!root.keyboardCovered && terminal.modelFocused) {
                                Qt.callLater(terminal.restoreFocusIfVacant);
                            }
                        }
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
                width: pane.frameWidth
                height: pane.frameHeight
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
