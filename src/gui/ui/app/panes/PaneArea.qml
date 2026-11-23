pragma ComponentBehavior: Bound

import Telar.Gui
import QtQuick

Item {
    id: root

    required property PanesController controller
    required property TerminalController terminals
    required property NvimController editors
    required property DocumentsController documents
    required property CopyController copy
    // The controllers of the overlays a pane hosts: the attachment shelf, and the history, path
    // and prompt searches of its prompt line.
    required property AttachmentsController attachments
    required property HistoryController history
    required property PathPickerController pathPicker
    required property PromptController prompt
    required property var colors
    required property var typography
    // The height of a pane's header band.
    required property real headerHeight
    // The dialog open over the workbench, a Store.Dialog.
    required property int dialog
    // The search a prompt line hosts, {kind: a Store.Dialog, pane: the key of the pane whose line
    // it is}, as one value that changes at once.
    required property var lineSearch
    required property bool prefixPending
    // The platform's Control and Command modifiers, as event modifier masks.
    required property int controlModifier
    required property int superModifier
    property real ratio: 1
    property bool keyboardCovered: false
    // What a pane asks of the window: a WindowActions.Action on `target`, a pane's key or empty.
    signal actionRequested(int action, string target)
    // A click on an element a mod drew in a pane's header.
    signal elementActivated(string slot, string key, string revision, int element)
    // The parent raises it each time the window shows or closes a dialog, once `dialog` holds the
    // new one: the focused pane's terminal takes the keyboard back when none is open.
    signal dialogShown()

    AttachmentShelf {
        controller: root.attachments
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
    }

    // The pane at a point of the area, as its key and its frame; none where no pane is.
    function paneAt(point) {
        for (let index = 0; index < shown.count; ++index) {
            const pane = shown.itemAt(index);

            if (pane && point.x >= pane.x && point.x < pane.x + pane.width && point.y >= pane.y && point.y < pane.y + pane.height)
                return {key: pane.record.key, x: pane.x + pane.record.frame.x, y: pane.y + pane.record.frame.y, width: pane.frameWidth, height: pane.frameHeight};
        }

        return null;
    }

    PaneMotionLayout {
        id: motion
        anchors.fill: parent
        model: root.controller.rows
    }

    Repeater {
        id: shown
        model: motion.items

        delegate: Item {
            id: pane

            required property var record
            readonly property bool framed: record.framed
            readonly property var elements: record.chrome?.elements ?? ({})
            readonly property bool drawnHeader: elements.pane_header !== undefined
            readonly property var fullscreenEntries: record.fullscreenEntries ?? []
            // The pane selectors take a share of the header, and never the room its buttons and a short title need.
            readonly property real selectorRoom: Math.min(0.4 * frameWidth, frameWidth - 200 * root.ratio)
            x: record.visualBounds.x
            y: record.visualBounds.y
            width: record.visualBounds.width
            height: record.visualBounds.height
            readonly property real contentWidth: resizing ? Math.max(0, record.content.width + width - record.width) : record.content.width
            readonly property real contentHeight: resizing ? Math.max(0, record.content.height + height - record.height) : record.content.height
            readonly property real frameWidth: resizing ? Math.max(0, record.frame.width + width - record.width) : record.frame.width
            readonly property real frameHeight: resizing ? Math.max(0, record.frame.height + height - record.height) : record.frame.height
            readonly property bool resizing: width !== record.width || height !== record.height
            // What draws the pane and takes its keys: the editor's view, or the terminal's.
            readonly property Item contentView: editorView.item ?? terminal
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
                color: root.colors.paneBackground
                replaceBackground: true
                backdropColor: root.colors.workbenchBackground
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
                            root.actionRequested(WindowActions.Action.focus_pane, pane.record.key);
                            pane.contentView.forceActiveFocus(Qt.MouseFocusReason);
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
                borderColor: pane.record.focused ? root.colors.accent : root.colors.chromeText
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
                height: pane.framed ? Math.min(pane.frameHeight, pane.record.content.y - y, root.headerHeight) : 0
                visible: pane.framed && !pane.drawnHeader
                record: pane.record.chrome
                // An editor says which file it shows; its mode is on its status line.
                detail: {
                    const shown = editorView.item?.editor;

                    return !shown || !shown.ready || pane.record.title === pane.record.chrome.program ? "" : pane.record.title;
                }
                onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                bandHeight: height
                focused: pane.record.focused
                prefixPending: root.prefixPending

                MouseArea {
                    anchors.fill: parent
                    onPressed: {
                        root.actionRequested(WindowActions.Action.focus_pane, pane.record.key);
                        pane.contentView.forceActiveFocus(Qt.MouseFocusReason);
                    }
                }
            }

            PaneActions {
                id: paneActions
                x: pane.record.frame.x + pane.frameWidth - width - 6 * root.ratio
                y: pane.record.frame.y + (header.height - height) / 2
                visible: pane.framed && !pane.drawnHeader && !pane.elements.pane_actions && (pane.record.focused || paneHover.hovered) && header.height >= height && pane.frameWidth > width + 80 * root.ratio
                onActionRequested: (action, target) => root.actionRequested(action, target)
                paneKey: pane.record.key
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                entries: pane.fullscreenEntries
                prefixPending: root.prefixPending
                entryRoom: pane.selectorRoom
            }

            // A mod's whole header, or only its actions, in place of the QML ones.
            ElementHost {
                objectName: "paneHeaderElements"
                x: header.x
                y: header.y
                width: Math.max(0, pane.frameWidth - header.bandInset - 4 * root.ratio)
                height: pane.framed ? Math.min(pane.frameHeight, pane.record.content.y - pane.record.frame.y, root.headerHeight) : 0
                visible: pane.drawnHeader && pane.framed
                content: pane.elements.pane_header ?? null
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
                builtins: Object.assign({pane_actions: actionsPiece}, header.builtins)
            }

            ElementHost {
                objectName: "paneActionsElements"
                x: pane.record.frame.x + pane.frameWidth - width - 6 * root.ratio
                y: pane.record.frame.y + (header.height - height) / 2
                width: implicitWidth
                height: Math.min(implicitHeight, header.height)
                visible: !pane.drawnHeader && pane.elements.pane_actions !== undefined && pane.framed
                content: pane.elements.pane_actions ?? null
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
                builtins: ({pane_actions: actionsPiece})
            }

            Component {
                id: actionsPiece
                PaneActions {
                    onActionRequested: (action, target) => root.actionRequested(action, target)
                    paneKey: pane.record.key
                    colors: root.colors
                    typography: root.typography
                    ratio: root.ratio
                    entries: pane.fullscreenEntries
                    prefixPending: root.prefixPending
                    entryRoom: pane.selectorRoom
                }
            }

            Item {
                id: viewport
                x: pane.record.content.x
                y: pane.record.content.y
                width: pane.contentWidth
                height: pane.contentHeight
                clip: true
                // The terminal and what is drawn over its rows rise together while the prompt line
                // needs rows past the screen's last, so the line never covers output.
                property real rise: promptLine.lift
                Behavior on rise {
                    enabled: promptLine.moving
                    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                }

                NativeRoundedRectangle {
                    objectName: "paneTerminalBackground"
                    anchors.fill: parent
                    color: root.colors.terminalBackground
                    replaceBackground: true
                }

                TerminalView {
                    id: terminal
                    transform: Translate { y: -viewport.rise }

                    // Commit the terminal grid once; animate only its viewport.
                    width: pane.record.content.width
                    height: pane.record.content.height
                    controller: root.terminals
                    paneId: pane.record.key
                    backgroundProvided: true
                    property bool focusReady: false
                    readonly property bool modelFocused: pane.record.focused

                    function focusSelectedPane() {
                        if (terminal.modelFocused && root.dialog === Store.Dialog.none && !root.keyboardCovered) {
                            pane.contentView.forceActiveFocus();
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
                            pane.contentView.focus = false;
                        } else if (terminal.focusReady) {
                            terminal.focusSelectedPane();
                        }
                    }
                    Component.onCompleted: {
                        terminal.focusReady = true;
                        terminal.focusSelectedPane();
                    }

                    Rectangle {
                        // Down to the viewport's bottom while the terminal rises.
                        width: parent.width
                        height: parent.height + viewport.rise
                        visible: pane.framed && !pane.record.focused
                        color: Qt.rgba(root.colors.background.r, root.colors.background.g, root.colors.background.b, 1)
                        opacity: pane.record.dimAlpha
                    }

                    LinkPreview {
                        preview: terminal.linkPreview
                        colors: root.colors

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
                        target: root
                        function onDialogShown() {
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

                // An editor pane draws its own grids in the terminal's place. Bound only for an
                // editor, so a terminal's own visibility is nobody else's to set.
                Binding {
                    target: terminal
                    property: "visible"
                    value: false
                    when: pane.record.editor
                }

                // What a terminal draws over its rows: the documents, the commands' separators and
                // rail, the prompt line. An editor pane has none of them.
                Item {
                    anchors.fill: parent
                    visible: !pane.record.editor

                    // The commands the shell ran: a separator over each one's prompt, and a dot per
                    // command beside the pane to reach it.
                    // Documents drawn in place of the rows of text they stand for, moving with them,
                    // under the separators and the prompt line.
                    InlineDocuments {
                        anchors.fill: parent
                        transform: Translate { y: -viewport.rise }
                        controller: root.documents
                        paneId: pane.record.key
                        view: terminal
                        colors: root.colors
                        grid: root.typography.grid
                        ratio: root.ratio
                    }

                    CommandSeparators {
                        id: separators
                        view: terminal
                        // With the rows, which a view scrolled by pixels draws shifted up.
                        transform: Translate { y: -viewport.rise - terminal.scrollShift }
                        pinnedOffset: viewport.rise + terminal.scrollShift
                        colors: root.colors
                        grid: root.typography.grid
                        ratio: root.ratio
                        moving: promptLine.moving
                        interruptKey: promptLine.interruptKey
                        queueing: promptLine.queueing
                        secret: promptLine.secret
                        offerFailure: promptLine.offerFailure
                    }

                    PromptLine {
                        id: promptLine
                        revealDelay: separators.revealDelay
                        transform: Translate { y: -viewport.rise }
                        paneId: pane.record.key
                        colors: root.colors
                        typography: root.typography
                        grid: root.typography.grid
                        history: root.history
                        pathPicker: root.pathPicker
                        copy: root.copy
                        prompt: root.prompt
                        lineSearch: root.lineSearch
                        controlModifier: root.controlModifier
                        superModifier: root.superModifier
                        terminal: terminal
                        ratio: root.ratio
                        focused: pane.record.focused
                        onCancelled: root.actionRequested(WindowActions.Action.cancel, "")
                    }

                    // Back to the live end, above the docked line.
                    JumpToEnd {
                        view: terminal
                        colors: root.colors
                        grid: root.typography.grid
                        ratio: root.ratio
                        moving: promptLine.moving
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: promptLine.dockedHeight + 10 * root.ratio
                        z: 3
                    }

                    CommandRail {
                        view: terminal
                        colors: root.colors
                        ratio: root.ratio
                        moving: promptLine.moving
                        anchors.right: parent.right
                        anchors.rightMargin: 4 * root.ratio
                        anchors.top: parent.top
                        anchors.topMargin: 12 * root.ratio
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 28 * root.ratio
                    }

                    // A document the pane's program shows natively covers its rows while it runs.
                    DocumentView {
                        anchors.fill: parent
                        z: 4
                        controller: root.documents
                        paneId: pane.record.key
                        colors: root.colors
                        grid: root.typography.grid
                        ratio: root.ratio
                        focusTarget: terminal
                        onFocusRequested: paneId => root.actionRequested(WindowActions.Action.focus_pane, paneId)
                    }
                }

                // A Neovim the runtime runs, drawn natively in place of a terminal's rows.
                Loader {
                    id: editorView
                    width: pane.record.content.width
                    height: pane.record.content.height
                    active: pane.record.editor
                    onLoaded: terminal.focusSelectedPane()
                    sourceComponent: NvimPane {
                        controller: root.editors
                        paneId: pane.record.key
                        colors: root.colors
                        typography: root.typography
                        ratio: root.ratio
                        onPressed: root.actionRequested(WindowActions.Action.focus_pane, pane.record.key)

                        Rectangle {
                            anchors.fill: parent
                            z: 1000
                            visible: pane.framed && !pane.record.focused
                            color: Qt.rgba(root.colors.background.r, root.colors.background.g, root.colors.background.b, 1)
                            opacity: pane.record.dimAlpha
                        }
                    }
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
                    color: root.colors[pane.record.chrome.agent.statusColor ?? "overlay1"]
                }
            }
        }
    }

    Repeater {
        model: root.controller.dividers

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
                root.controller.resizeDivider(Number(record.key), position.x, position.y, commit);
            }

            onPositionChanged: mouse => {
                if (pressed)
                    resize(mouse, false);
            }
            onReleased: mouse => resize(mouse, true)
        }
    }
}
