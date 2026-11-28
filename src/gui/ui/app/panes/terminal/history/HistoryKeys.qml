import QtQuick
import Telar.Gui

// The history search's keys, shared by the dialog and the prompt line: they move through the
// rows, cycle the filters and act on the selected command. Rows run newest first, from the
// bottom in the dialog and from the top under the prompt line.
QtObject {
    id: root

    required property HistoryController controller
    // The platform's Control and Command modifiers, as event modifier masks.
    required property int controlModifier
    required property int superModifier
    // The field the query is typed in, for Ctrl+C to copy its selection.
    property var queryField: null
    // Pages the inspector's output while it shows: function(older).
    property var pageInspector: null
    // The rows run newest first from the top, so down goes to older ones.
    property bool downward: false
    readonly property var state: root.controller.state
    // Escape or Control+H outside the inspector: the window closes the search.
    signal cancelled()

    // Moves `delta` rows, positive to older commands, across pages. The controller keeps the
    // moves made while rows load for the rows that replace them.
    function moveSelection(delta) {
        root.controller.move(delta);
    }

    function cycleScope() {
        const scopes = ["global", "workspace", "cwd", "pane", "session"];
        const next = (scopes.indexOf(root.state.scope) + 1) % scopes.length;
        root.controller.setFilters({scope: scopes[next]});
    }

    function cycleAuthor() {
        const authors = ["human", "agent", "all"];
        const next = (authors.indexOf(root.state.author) + 1) % authors.length;
        root.controller.setFilters({author: authors[next]});
    }

    function cycleFilter(event) {
        // Tab completes a filter's name the last word begins, `ex` to `exit:`, before it cycles.
        const backward = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) !== 0;
        if (!backward && root.queryField) {
            const completed = root.controller.completeFilter(root.queryField.text);
            if (completed.length > 0) {
                root.queryField.text = completed;
                root.queryField.cursorPosition = completed.length;
                root.controller.search(completed);
                return;
            }
        }

        if (backward) {
            root.cycleAuthor();
        } else {
            root.cycleScope();
        }
    }

    function cancel() {
        if (root.state.inspecting) {
            root.controller.execute(HistoryController.Action.inspect);
        } else {
            root.cancelled();
        }
    }

    // Enter uses the selected command; Alt visits the pane it ran in, Shift does the other of
    // running or editing it.
    function submit(event) {
        if ((event.modifiers & Qt.AltModifier) !== 0) {
            root.controller.execute(HistoryController.Action.visit);
        } else {
            root.controller.use(root.state.selection, (event.modifiers & Qt.ShiftModifier) !== 0);
        }
    }

    function page(older) {
        if (root.state.inspecting && root.pageInspector) {
            root.pageInspector(older);
        } else {
            root.controller.execute(older ? HistoryController.Action.older : HistoryController.Action.newer);
        }
    }

    // Whether `event` was one of the search's commands, which it then ran.
    function handle(event) {
        if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
            // The inspector's output pages as the dialog's does, whichever way the rows run.
            const up = event.key === Qt.Key_PageUp;
            root.page(root.state.inspecting || !root.downward ? up : !up);
            return true;
        }

        const control = (event.modifiers & root.controlModifier) !== 0;
        const command = (event.modifiers & root.superModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const alt = (event.modifiers & Qt.AltModifier) !== 0;
        // Backspace in an empty search takes the last chip back.
        if (event.key === Qt.Key_Backspace && !control && !command && !alt && root.queryField && root.queryField.text.length === 0 && (root.state.chips ?? []).length > 0) {
            root.controller.removeChip(-1);
            return true;
        }

        // Alt and a digit run that row of the page, newest first, as atuin's quick select does;
        // with Shift, that pin. Shift reports a digit as the sign above it.
        const shifted = [Qt.Key_Exclam, Qt.Key_At, Qt.Key_NumberSign, Qt.Key_Dollar, Qt.Key_Percent, Qt.Key_AsciiCircum, Qt.Key_Ampersand, Qt.Key_Asterisk, Qt.Key_ParenLeft];
        const digit = event.key >= Qt.Key_1 && event.key <= Qt.Key_9 ? event.key - Qt.Key_0 : shifted.indexOf(event.key) + 1;
        if (alt && !control && !command && digit > 0) {
            if (shift) {
                root.controller.usePin(digit - 1);
            } else {
                root.controller.quickUse(digit - 1);
            }
            return true;
        }

        // Alt+S orders by rank or by time, Alt+U searches what the commands printed, Alt+R shows
        // the runs around each match and Alt+M steps how the query matches (fuzzy, substring,
        // prefix, regex); each shows as a chip. Control+S stays the newer match.
        if (alt && !control && !command && (event.key === Qt.Key_S || event.key === Qt.Key_U || event.key === Qt.Key_R || event.key === Qt.Key_M)) {
            const names = {[Qt.Key_S]: "sort", [Qt.Key_U]: "output", [Qt.Key_R]: "raw", [Qt.Key_M]: "mode"};
            root.controller.toggle(names[event.key]);
            return true;
        }

        // Alt+P pins the command to the top of the panel, or unpins it.
        if (alt && !control && !command && event.key === Qt.Key_P) {
            root.controller.execute(HistoryController.Action.pin);
            return true;
        }

        // Alt+D changes the shell to the command's directory; Alt+O opens a pane there.
        if (alt && !control && !command && (event.key === Qt.Key_D || event.key === Qt.Key_O)) {
            root.controller.execute(event.key === Qt.Key_D ? HistoryController.Action.enter : HistoryController.Action.open);
            return true;
        }

        // Control+Space, or Shift+Space, marks the command to be used with the others marked.
        if (event.key === Qt.Key_Space && (control || shift) && !command && !alt) {
            root.controller.execute(HistoryController.Action.mark);
            return true;
        }

        // Undo takes the last delete back while its notice shows.
        if (event.key === Qt.Key_Z && (command || (control && !shift)) && root.state.hidden) {
            root.controller.execute(HistoryController.Action.undo);
            return true;
        }
        // Deleting takes Command+Backspace, or Control with Shift and D: Control+D alone is the
        // shell's delete-forward, which must not delete a command from the history.
        if ((command && event.key === Qt.Key_Backspace) || (control && shift && event.key === Qt.Key_D)) {
            root.controller.execute(HistoryController.Action.erase);
            return true;
        }

        // Copying takes Command+C, or Control with Shift and C as terminals copy; Control+C
        // alone cancels, as it cancels the shell's own search.
        if ((command || (control && shift)) && event.key === Qt.Key_C) {
            if (root.queryField && root.queryField.selectionStart !== root.queryField.selectionEnd) {
                root.queryField.copy();
            } else {
                root.controller.execute(HistoryController.Action.copy);
            }

            return true;
        }

        if (!control || (event.modifiers & Qt.AltModifier) !== 0) {
            return false;
        }

        switch (event.key) {
        case Qt.Key_C:
        case Qt.Key_G:
            root.cancel();
            return true;
        // Control+R again goes to an older match and Control+S to a newer one, as the shell's own
        // search steps, whichever way the rows run.
        case Qt.Key_R:
            root.moveSelection(1);
            return true;
        case Qt.Key_S:
            root.moveSelection(-1);
            return true;
        case Qt.Key_O:
            root.controller.execute(HistoryController.Action.inspect);
            return true;
        case Qt.Key_H:
            if (command || (event.modifiers & Qt.ShiftModifier) !== 0) {
                return false;
            }

            root.cancel();
            return true;
        case Qt.Key_L:
            if (command || (event.modifiers & Qt.ShiftModifier) !== 0) {
                return false;
            }

            root.controller.use(root.state.selection);
            return true;
        case Qt.Key_J:
            root.moveSelection(root.downward ? 1 : -1);
            return true;
        case Qt.Key_K:
            root.moveSelection(root.downward ? -1 : 1);
            return true;
        default:
            return false;
        }
    }
}
