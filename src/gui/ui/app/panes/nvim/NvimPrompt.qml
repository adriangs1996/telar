pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// What vim.ui.select or vim.ui.input asks, as a dialog of telar's own: a list to choose from or
// a field to type in, whatever in Neovim asked and whatever its configuration loads. It opens by
// the word under the cursor, says who asks, and a long list opens as the window's picker, with
// a search. It takes the keyboard while it is open and gives it back to the editor when it is
// answered.
FocusScope {
    id: root
    objectName: "editorPrompt"

    // The editor's prompt: id, kind ("select", "input" or empty), title, origin, initial, choices.
    required property var prompt
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property bool selecting: prompt.kind === "select"
    readonly property bool typing: prompt.kind === "input"
    readonly property bool shown: selecting || typing
    readonly property var choices: prompt.choices ?? []
    // A list longer than the keys that pick it is searched, in the window's picker.
    readonly property int keyed: 9
    readonly property bool searching: selecting && choices.length > keyed
    property string query: ""
    // The choices the query finds, each {index, runs}: its letters in turn, case aside.
    readonly property var found: searching ? choices.map((text, index) => ({index: index, runs: matchRuns(text, query)})).filter(entry => entry.runs !== null) : []
    readonly property int visibleRows: Math.min(choices.length, keyed)
    readonly property real rowHeight: 30 * ratio
    readonly property real inset: 8 * ratio
    readonly property real headerHeight: 40 * ratio
    readonly property real footerHeight: 30 * ratio
    property int current: 0
    readonly property int firstRow: Math.max(0, Math.min(choices.length - visibleRows, current - Math.floor(visibleRows / 2)))
    property real reveal: shown ? 1 : 0
    // The answer: the choice at `index`, or the text typed; nothing accepted when dismissed.
    signal answered(bool accepted, int index, string text)

    // The cell of the editor's cursor, in the parent's coordinates: the prompt opens under it, by
    // the word it asks about, or over it where there is no room under it.
    property rect anchor: Qt.rect(0, 0, 0, 0)
    readonly property real margin: 8 * ratio
    readonly property bool anchored: anchor.width > 0 && anchor.height > 0
    readonly property bool below: anchor.y + anchor.height + margin + height <= parent.height - margin

    width: Math.min(parent.width - 32 * ratio, (typing ? 320 : searching ? 560 : 460) * ratio)
    height: searching ? Math.min(parent.height - 32 * ratio, 420 * ratio) : headerHeight + (selecting ? visibleRows * rowHeight + inset : rowHeight + inset) + footerHeight
    x: Math.round(anchored ? Math.max(margin, Math.min(anchor.x - 16 * ratio, parent.width - width - margin)) : (parent.width - width) / 2)
    y: Math.round(!anchored ? Math.max(16 * ratio, (parent.height - height) * 0.32) : below ? anchor.y + anchor.height + 4 * ratio : Math.max(margin, anchor.y - height - 4 * ratio)) - (1 - reveal) * 8 * ratio
    opacity: reveal
    visible: reveal > 0

    // Each prompt starts on its first choice, with what Neovim proposed in the field.
    // Read from the prompt itself: a binding that depends on it may not have been read again
    // when it changes.
    onPromptChanged: {
        const kind = prompt.kind ?? "";

        current = 0;
        query = "";
        search.queryField.text = "";
        if (kind === "input") {
            field.text = prompt.initial ?? "";
            field.input.selectAll();
        }

        keysAwaited = kind.length > 0;
        takeKeys();
    }

    // An item takes the keys only while it shows: a prompt that comes while the last one fades
    // takes them as it shows.
    property bool keysAwaited: false

    onRevealChanged: takeKeys()

    // The query takes the keys of a long list, the field those of a text, the list the others.
    function takeKeys() {
        const kind = prompt.kind ?? "";

        if (!keysAwaited || kind.length === 0 || reveal <= 0) {
            return;
        }

        const taker = kind === "select" && (prompt.choices ?? []).length > keyed ? search.queryField : kind === "input" ? field.input : root;

        // An item that does not show yet takes them on a later step of the reveal.
        taker.forceActiveFocus();
        keysAwaited = !taker.activeFocus;
    }

    Behavior on reveal {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    // The letters of `query` in `text`, each at its first place after the one before, case
    // aside, as runs of the text; null when they are not all there.
    function matchRuns(text, query) {
        const runs = [];
        let next = 0;

        for (let at = 0; at < text.length; ++at) {
            const matched = next < query.length && text[at].toLowerCase() === query[next].toLowerCase();
            const last = runs[runs.length - 1];

            next += matched ? 1 : 0;
            if (last !== undefined && last.bold === matched) {
                last.text += text[at];
            } else {
                runs.push({text: text[at], colorRole: matched ? "accent" : "text", bold: matched});
            }
        }

        return next === query.length ? runs : null;
    }

    Keys.onPressed: event => {
        if (!root.shown || root.searching) {
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

    // A long list: the window's picker, its query searching the choices.
    PickerPanel {
        id: search
        anchors.fill: parent
        visible: root.searching
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        fieldName: "editorSelectSearch"
        searchName: "Search the choices"
        glyph: "\ueb85"
        label: [(root.prompt.title ?? "").replace(/[:\s]+$/, ""), root.prompt.origin ?? ""].filter(part => part.length > 0).join(" · ")
        rows: root.found.map(entry => ({runs: entry.runs, identity: String(entry.index)}))
        current: root.current
        countText: root.found.length + " of " + root.choices.length
        emptyText: "Nothing found"
        hints: [{keys: ["↑", "↓"], word: "Navigate"}, {keys: ["esc"], word: "Cancel"}]
        trailing: ({keys: ["↵"], word: "Choose"})
        onSearched: text => {
            root.query = text;
            root.current = 0;
        }
        onRowPointed: index => root.current = index
        onRowActivated: index => root.answered(true, root.found[index].index, "")
        onKeyPressed: event => {
            if (event.key === Qt.Key_Escape) {
                if (!search.queryField.cancelComposition()) {
                    root.answered(false, 0, "");
                }
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.found.length > 0) {
                    root.answered(true, root.found[root.current].index, "");
                }
            } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
                root.current = (root.current + 1) % Math.max(1, root.found.length);
            } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
                root.current = (root.current + root.found.length - 1) % Math.max(1, root.found.length);
            } else {
                return;
            }

            event.accepted = true;
        }
    }

    // What is asked: a choice among items, or a text to type.
    ChromeIcon {
        id: asking
        visible: !root.searching
        x: 16 * root.ratio
        y: Math.round((root.headerHeight - height) / 2)
        width: Math.round(root.typography.body * 1.15)
        height: width
        glyph: root.selecting ? "\ueb85" : "\uea73"
        pixelSize: width
        color: root.colors.accent
    }

    // Who asks, at the end of the title's row.
    ChromeText {
        id: origin
        x: root.width - width - 16 * root.ratio
        width: implicitWidth
        height: root.headerHeight
        visible: !root.searching && text.length > 0
        text: root.prompt.origin ?? ""
        pixelSize: root.typography.small
        color: Qt.alpha(root.colors.text, 0.45)
    }

    ChromeText {
        x: asking.x + asking.width + 8 * root.ratio
        width: (origin.visible ? origin.x - 12 * root.ratio : root.width - 16 * root.ratio) - x
        height: root.headerHeight
        visible: !root.searching
        text: (root.prompt.title ?? "").replace(/[:\s]+$/, "") || (root.selecting ? "Select" : "Input")
        pixelSize: root.typography.body
        emphasized: true
        color: root.colors.text
    }

    Rectangle {
        y: root.headerHeight - height
        width: root.width
        height: Math.max(1, root.ratio) / Screen.devicePixelRatio
        visible: !root.searching
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    Item {
        x: root.inset
        y: root.headerHeight + root.inset / 2
        width: root.width - 2 * root.inset
        height: root.visibleRows * root.rowHeight
        visible: root.selecting && !root.searching
        clip: true

        Repeater {
            model: root.selecting && !root.searching ? root.visibleRows : 0

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

    // The text asked for, in the design system's field: what Neovim proposed is selected, and
    // the field takes the composition of an input method as the window's fields do.
    PromptField {
        id: field
        x: root.inset
        y: root.headerHeight + root.inset / 2
        width: root.width - 2 * root.inset
        height: root.rowHeight
        visible: root.typing
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        inputName: "editorInputField"
        onSubmitted: root.answered(true, 0, field.text)
        onCancelled: root.answered(false, 0, "")
    }

    KeyHintBar {
        visible: !root.searching
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
