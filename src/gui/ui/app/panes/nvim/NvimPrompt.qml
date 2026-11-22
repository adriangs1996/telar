pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// What vim.ui.select or vim.ui.input asks, as a dialog of telar's own: a list to choose from or
// a field to type in, whatever in Neovim asked and whatever its configuration loads. It takes
// the keyboard while it is open and gives it back to the editor when it is answered.
FocusScope {
    id: root

    // The editor's prompt: id, kind ("select", "input" or empty), title, initial, choices.
    required property var prompt
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property bool selecting: prompt.kind === "select"
    readonly property bool typing: prompt.kind === "input"
    readonly property bool shown: selecting || typing
    readonly property var choices: prompt.choices ?? []
    readonly property int visibleRows: Math.min(choices.length, 9)
    readonly property real rowHeight: 30 * ratio
    readonly property real inset: 8 * ratio
    readonly property real headerHeight: 40 * ratio
    readonly property real footerHeight: 30 * ratio
    property int current: 0
    readonly property int firstRow: Math.max(0, Math.min(choices.length - visibleRows, current - Math.floor(visibleRows / 2)))
    property real reveal: shown ? 1 : 0
    // The answer: the choice at `index`, or the text typed; nothing accepted when dismissed.
    signal answered(bool accepted, int index, string text)

    width: Math.min(parent.width - 32 * ratio, 460 * ratio)
    height: headerHeight + (selecting ? visibleRows * rowHeight + inset : rowHeight + inset) + footerHeight
    x: Math.round((parent.width - width) / 2)
    y: Math.round(Math.max(16 * ratio, (parent.height - height) * 0.32)) - (1 - reveal) * 8 * ratio
    opacity: reveal
    visible: reveal > 0

    // Each prompt starts on its first choice, with what Neovim proposed in the field.
    onPromptChanged: {
        current = 0;
        if (typing) {
            field.text = prompt.initial ?? "";
            field.selectAll();
        }

        if (shown) {
            forceActiveFocus();
        }
    }

    Behavior on reveal {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Keys.onPressed: event => {
        if (!root.shown) {
            return;
        }

        if (event.key === Qt.Key_Escape) {
            root.answered(false, 0, "");
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.answered(true, root.current, root.typing ? field.text : "");
        } else if (root.selecting && (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)))) {
            root.current = (root.current + 1) % Math.max(1, root.choices.length);
        } else if (root.selecting && (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)))) {
            root.current = (root.current + root.choices.length - 1) % Math.max(1, root.choices.length);
        } else if (root.selecting && event.text.length === 1 && event.text >= "1" && event.text <= "9" && Number(event.text) <= root.choices.length) {
            root.answered(true, Number(event.text) - 1, "");
        } else {
            return;
        }

        event.accepted = true;
    }

    NvimSurface {
        anchors.fill: parent
        colors: root.colors
        ratio: root.ratio
    }

    // What is asked: a choice among items, or a text to type.
    ChromeIcon {
        id: asking
        x: 16 * root.ratio
        y: Math.round((root.headerHeight - height) / 2)
        width: Math.round(root.typography.body * 1.15)
        height: width
        glyph: root.selecting ? "\ueb85" : "\uea73"
        pixelSize: width
        color: root.colors.accent
    }

    ChromeText {
        x: asking.x + asking.width + 8 * root.ratio
        width: root.width - x - 16 * root.ratio
        height: root.headerHeight
        text: (root.prompt.title ?? "").replace(/[:\s]+$/, "") || (root.selecting ? "Select" : "Input")
        pixelSize: root.typography.body
        emphasized: true
        color: root.colors.text
    }

    Rectangle {
        y: root.headerHeight - height
        width: root.width
        height: Math.max(1, root.ratio) / Screen.devicePixelRatio
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    Item {
        x: root.inset
        y: root.headerHeight + root.inset / 2
        width: root.width - 2 * root.inset
        height: root.visibleRows * root.rowHeight
        visible: root.selecting
        clip: true

        Repeater {
            model: root.selecting ? root.visibleRows : 0

            delegate: Item {
                id: choice

                required property int index
                readonly property int choiceIndex: root.firstRow + index
                readonly property bool chosen: choiceIndex === root.current

                y: index * root.rowHeight
                width: parent.width
                height: root.rowHeight

                HoverHandler {
                    onHoveredChanged: {
                        if (hovered) {
                            root.current = choice.choiceIndex;
                        }
                    }
                }

                TapHandler {
                    onTapped: root.answered(true, choice.choiceIndex, "")
                }

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: ChromeStyle.controlRadius * root.ratio
                    color: Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
                    visible: choice.chosen
                }

                // The number that picks the row at once, as the key it is.
                Rectangle {
                    x: 6 * root.ratio
                    y: Math.round((parent.height - height) / 2)
                    width: 20 * root.ratio
                    height: 20 * root.ratio
                    radius: 5 * root.ratio
                    color: "transparent"
                    border.width: Math.max(1, root.ratio) / Screen.devicePixelRatio
                    border.color: Qt.alpha(root.colors.text, 0.22)
                    visible: choice.choiceIndex < 9

                    ChromeText {
                        anchors.fill: parent
                        horizontalAlignment: Text.AlignHCenter
                        text: String(choice.choiceIndex + 1)
                        pixelSize: root.typography.small
                        color: Qt.alpha(root.colors.text, choice.chosen ? 0.8 : 0.5)
                    }
                }

                ChromeText {
                    x: 36 * root.ratio
                    width: parent.width - x - 8 * root.ratio
                    height: parent.height
                    text: root.choices[choice.choiceIndex] ?? ""
                    pixelSize: root.typography.body
                    color: choice.chosen ? root.colors.text : root.colors.subtext0
                }
            }
        }
    }

    TextInput {
        id: field
        x: 16 * root.ratio
        y: root.headerHeight + root.inset / 2
        width: root.width - 32 * root.ratio
        height: root.rowHeight
        visible: root.typing
        focus: root.typing
        color: root.colors.text
        selectionColor: Qt.alpha(root.colors.accent, 0.35)
        selectedTextColor: root.colors.text
        font.pixelSize: root.typography.body
        verticalAlignment: TextInput.AlignVCenter
        clip: true
    }

    KeyHintBar {
        y: root.height - root.footerHeight
        width: root.width
        height: root.footerHeight
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        hints: root.selecting ? [{keys: ["1–9"], word: "Choose"}, {keys: ["esc"], word: "Cancel"}] : [{keys: ["esc"], word: "Cancel"}]
        trailing: ({keys: ["↵"], word: root.selecting ? "Choose" : "Accept"})
    }
}
