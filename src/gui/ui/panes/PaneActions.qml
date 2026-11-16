pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Row {
    id: root
    objectName: "paneActions"

    required property GuiController controller
    required property string paneKey
    required property var colors
    required property var typography
    property real ratio: 1
    // The tab's panes while this one is fullscreen, in display order; empty otherwise.
    property var entries: []
    property bool prefixPending: false
    // The width the pane selectors may take; the panes past it are counted instead.
    property real entryRoom: 0
    readonly property bool zoomed: entries.length > 0
    readonly property real side: 24 * ratio
    readonly property real entryWidth: 23 * ratio
    // The selectors are a window on the tab's panes that keeps the focused one in view.
    readonly property int capacity: Math.max(1, Math.floor(entryRoom / entryWidth))
    readonly property int first: Math.max(0, Math.min(entries.findIndex(entry => entry.focused) - Math.floor((capacity - 1) / 2), entries.length - capacity))
    readonly property var shown: entries.slice(first, first + capacity)

    spacing: 2 * ratio

    function execute(action) {
        controller.execute(GuiController.Action.focus_pane, paneKey);
        controller.execute(action);
    }

    component ActionButton: ChromeButton {
        id: action

        required property var modelData
        property bool engaged: false
        readonly property color ink: engaged ? root.colors.accent : hovered ? root.colors.chromeText : root.colors.text
        objectName: "paneAction"
        width: root.side
        height: root.side
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        contentItem: Item {
            // Font split glyphs lose their divider at this size, so these two are drawn.
            NativeRoundedRectangle {
                id: outline
                anchors.centerIn: parent
                width: 13 * root.ratio
                height: 11 * root.ratio
                radius: 2 * root.ratio
                color: "transparent"
                borderColor: action.ink
                borderWidth: root.ratio
                visible: action.modelData.divider !== undefined
            }

            Rectangle {
                anchors.centerIn: outline
                width: action.modelData.divider === "vertical" ? root.ratio : outline.width
                height: action.modelData.divider === "vertical" ? outline.height : root.ratio
                color: action.ink
                visible: outline.visible
            }

            ChromeIcon {
                anchors.fill: parent
                glyph: action.modelData.glyph ?? ""
                color: action.ink
                pixelSize: 14 * root.ratio
                visible: action.modelData.glyph !== undefined
            }
        }
        Accessible.name: modelData.label
        onClicked: root.execute(modelData.action)
    }

    Repeater {
        model: [
            {label: "Split right", divider: "vertical", action: GuiController.Action.split_horizontal},
            {label: "Split below", divider: "horizontal", action: GuiController.Action.split_vertical}
        ]

        delegate: ActionButton {}
    }

    // Fullscreen is one object: the panes it covers and the button that leaves it.
    Item {
        objectName: "paneZoomCapsule"
        width: selectors.width
        height: root.side

        NativeRoundedRectangle {
            anchors.fill: parent
            radius: ChromeStyle.controlRadius * root.ratio
            color: Qt.alpha(root.colors.accent, 0.12)
            visible: root.zoomed
        }

        Row {
            id: selectors
            leftPadding: root.zoomed ? 2 * root.ratio : 0

            Repeater {
                model: root.shown

                delegate: ChromeButton {
                    id: selector

                    required property var modelData
                    readonly property var entry: modelData
                    readonly property bool attention: (entry.attentionColor ?? "").length > 0
                    objectName: "fullscreenPaneEntry"
                    width: root.entryWidth
                    height: root.side
                    enabled: !entry.focused
                    colors: root.colors
                    pixelSize: root.typography.body
                    cornerRadius: ChromeStyle.controlRadius * root.ratio
                    contentItem: Item {
                        ApplicationTile {
                            anchors.centerIn: parent
                            width: 18 * root.ratio
                            height: 14 * root.ratio
                            radius: ChromeStyle.smallRadius * root.ratio
                            mark: selector.entry
                            colors: root.colors
                            typography: root.typography
                            ratio: root.ratio
                            number: root.prefixPending ? selector.entry.index : ""
                            attentionColor: selector.entry.attentionColor ?? ""
                            statusColor: selector.attention ? "" : (selector.entry.agent?.statusColor ?? "")
                            dimmed: !selector.entry.focused && !selector.attention && !selector.hovered && !root.prefixPending
                        }

                        Rectangle {
                            objectName: "fullscreenPaneFocus"
                            x: 4 * root.ratio
                            y: parent.height - height - root.ratio
                            width: parent.width - 2 * x
                            height: 2 * root.ratio
                            radius: height / 2
                            color: root.colors.accent
                            visible: selector.entry.focused
                        }
                    }
                    Accessible.name: entry.program
                    onClicked: root.controller.execute(GuiController.Action.focus_pane, entry.key)

                    ChromeToolTip {
                        visible: selector.hovered
                        text: selector.entry.program + ((selector.entry.context ?? "").length > 0 ? "\n" + selector.entry.context : "")
                        colors: root.colors
                        typography: root.typography
                        ratio: root.ratio
                    }
                }
            }

            ChromeText {
                objectName: "fullscreenPaneOverflow"
                width: implicitWidth + 6 * root.ratio
                height: root.side
                text: "+" + (root.entries.length - root.shown.length)
                pixelSize: root.typography.small
                color: root.colors.accent
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideNone
                visible: root.shown.length < root.entries.length
            }

            // One button per state: a binding on the required modelData leaves it undefined.
            ActionButton {
                modelData: ({label: "Restore panes", glyph: "", action: GuiController.Action.fullscreen})
                engaged: true
                visible: root.zoomed
            }

            ActionButton {
                modelData: ({label: "Expand pane", glyph: "", action: GuiController.Action.fullscreen})
                visible: !root.zoomed
            }
        }
    }

    ActionButton {
        modelData: ({label: "Close pane", glyph: "", action: GuiController.Action.close_pane})
    }
}
