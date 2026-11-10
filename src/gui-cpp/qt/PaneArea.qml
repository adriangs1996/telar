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
            readonly property var elements: record.chrome?.elements ?? ({})
            readonly property bool drawnHeader: elements.pane_header !== undefined
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

            HoverHandler {
                id: paneHover
            }

            ElevationShadow {
                x: pane.record.frame.x
                y: pane.record.frame.y
                width: pane.frameWidth
                height: pane.frameHeight
                ratio: root.ratio
                cornerRadius: pane.record.frameRadius * root.ratio
                strength: 0.09
                visible: pane.framed && pane.record.focused && !pane.record.fullscreen
            }

            NativeRoundedRectangle {
                objectName: "paneSurface"
                x: pane.record.frame.x
                y: pane.record.frame.y
                width: pane.frameWidth
                height: pane.frameHeight
                radius: pane.framed ? pane.record.frameRadius * root.ratio : 0
                color: root.application.colors.paneBackground
                replaceBackground: true
                backdropColor: root.application.colors.workbenchBackground
            }

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
                    color: "transparent"

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
                borderColor: pane.record.focused ? root.application.colors.accent : root.application.colors.chromeText
                borderAlpha: pane.record.focused ? 0.8 : 0.06
                borderWidth: pane.record.focused ? root.ratio : pane.record.frameLineWidth
                radius: pane.record.frameRadius * root.ratio
                visible: pane.framed
            }

            PaneHeader {
                id: header

                // The band's own margin lands the tile on the terminal's first column.
                readonly property real bandInset: Math.max(0, pane.record.content.x - pane.record.frame.x - bandMargin)
                readonly property real bandMargin: 8 * root.ratio
                x: pane.record.frame.x + bandInset
                y: pane.record.frame.y
                width: Math.max(0, pane.frameWidth - bandInset - (paneActions.visible ? paneActions.width + 4 * root.ratio : 0))
                height: pane.framed ? Math.min(pane.frameHeight, pane.record.content.y - y, root.application.windowGeometry.paneHeader) : 0
                visible: pane.framed && !pane.record.fullscreen && !pane.drawnHeader
                record: pane.record.chrome
                controller: root.application
                colors: root.application.colors
                typography: root.application.windowGeometry.typography
                ratio: root.ratio
                bandHeight: height
                focused: pane.record.focused
                prefixPending: root.application.prefixPending

                MouseArea {
                    anchors.fill: parent
                    onPressed: {
                        root.application.execute(GuiController.Action.focus_pane, pane.record.key);
                        terminal.forceActiveFocus(Qt.MouseFocusReason);
                    }
                }
            }

            PaneActions {
                id: paneActions
                x: pane.record.frame.x + pane.frameWidth - width - 6 * root.ratio
                y: pane.record.frame.y + (header.height - height) / 2
                visible: pane.framed && !pane.record.fullscreen && !pane.drawnHeader && !pane.elements.pane_actions && (pane.record.focused || paneHover.hovered) && header.height >= height && pane.frameWidth > width + 80 * root.ratio
                controller: root.application
                paneKey: pane.record.key
                colors: root.application.colors
                typography: root.application.windowGeometry.typography
                ratio: root.ratio
            }

            // A mod's whole header, or only its actions, in place of the QML ones.
            ElementHost {
                objectName: "paneHeaderElements"
                x: header.x
                y: header.y
                width: Math.max(0, pane.frameWidth - header.bandInset - 4 * root.ratio)
                height: pane.framed ? Math.min(pane.frameHeight, pane.record.content.y - pane.record.frame.y, root.application.windowGeometry.paneHeader) : 0
                visible: pane.drawnHeader && pane.framed && !pane.record.fullscreen
                content: pane.elements.pane_header ?? null
                colors: root.application.colors
                typography: root.application.windowGeometry.typography
                ratio: root.ratio
                controller: root.application
                builtins: Object.assign({pane_actions: actionsPiece}, header.builtins)
            }

            ElementHost {
                objectName: "paneActionsElements"
                x: pane.record.frame.x + pane.frameWidth - width - 6 * root.ratio
                y: pane.record.frame.y + (header.height - height) / 2
                width: implicitWidth
                height: Math.min(implicitHeight, header.height)
                visible: !pane.drawnHeader && pane.elements.pane_actions !== undefined && pane.framed && !pane.record.fullscreen
                content: pane.elements.pane_actions ?? null
                colors: root.application.colors
                typography: root.application.windowGeometry.typography
                ratio: root.ratio
                controller: root.application
                builtins: ({pane_actions: actionsPiece})
            }

            Component {
                id: actionsPiece
                PaneActions {
                    controller: root.application
                    paneKey: pane.record.key
                    colors: root.application.colors
                    typography: root.application.windowGeometry.typography
                    ratio: root.ratio
                }
            }

            Item {
                id: viewport
                x: pane.record.content.x
                y: pane.record.content.y
                width: pane.contentWidth
                height: pane.contentHeight
                clip: true

                NativeRoundedRectangle {
                    objectName: "paneTerminalBackground"
                    anchors.fill: parent
                    color: root.application.colors.terminalBackground
                    replaceBackground: true
                }

                TerminalView {
                    id: terminal

                    // Commit the terminal grid once; animate only its viewport.
                    width: pane.record.content.width
                    height: pane.record.content.height
                    application: root.application
                    paneId: pane.record.key
                    backgroundProvided: true
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

                // The commands the shell ran: a separator over each one's prompt, and a dot per
                // command beside the pane to reach it.
                CommandSeparators {
                    view: terminal
                    colors: root.application.colors
                    grid: root.application.windowGeometry.typography.grid
                    ratio: root.ratio
                    moving: island.moving
                    landing: island.landing
                    holding: island.flying
                }

                CommandRail {
                    view: terminal
                    colors: root.application.colors
                    ratio: root.ratio
                    moving: island.moving
                    anchors.right: parent.right
                    anchors.rightMargin: 4 * root.ratio
                    anchors.top: parent.top
                    anchors.topMargin: 12 * root.ratio
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: (island.visible ? island.height : 0) + 28 * root.ratio
                }

                PromptIsland {
                    id: island
                    application: root.application
                    paneId: pane.record.key
                    colors: root.application.colors
                    grid: root.application.windowGeometry.typography.grid
                    terminal: terminal
                    ratio: root.ratio
                    focused: pane.record.focused
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
