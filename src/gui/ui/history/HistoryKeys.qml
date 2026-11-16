import QtQuick
import Telar.Gui

// The history search's keys, shared by the dialog and the prompt line: they move through the
// rows, cycle the filters and act on the selected command. Rows run newest first, from the
// bottom in the dialog and from the top under the prompt line.
QtObject {
    id: root

    required property var controller
    // The field the query is typed in, for Ctrl+C to copy its selection.
    property var queryField: null
    // Pages the inspector's output while it shows: function(older).
    property var pageInspector: null
    // The rows run newest first from the top, so down goes to older ones.
    property bool downward: false
    readonly property var state: root.controller.history.state
    readonly property bool actionable: !root.controller.history.loading && root.state.phase === "ready" && root.state.count > 0

    function moveSelection(delta) {
        if (!root.actionable) {
            return;
        }

        const selected = root.state.selection + delta;
        if (selected >= root.state.count && root.state.canOlder) {
            root.controller.history.execute(HistoryController.Action.older);
        } else if (selected < 0 && root.state.canNewer) {
            root.controller.history.execute(HistoryController.Action.newer);
        } else {
            root.controller.history.select(Math.max(0, Math.min(root.state.count - 1, selected)));
        }
    }

    function cycleScope() {
        const scopes = ["global", "workspace", "cwd", "pane"];
        const next = (scopes.indexOf(root.state.scope) + 1) % scopes.length;
        root.controller.history.setFilters({scope: scopes[next]});
    }

    function cycleAuthor() {
        const authors = ["human", "agent", "all"];
        const next = (authors.indexOf(root.state.author) + 1) % authors.length;
        root.controller.history.setFilters({author: authors[next]});
    }

    function cycleFilter(event) {
        if (event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) !== 0) {
            root.cycleAuthor();
        } else {
            root.cycleScope();
        }
    }

    function cancel() {
        if (root.state.inspecting) {
            root.controller.history.execute(HistoryController.Action.inspect);
        } else {
            root.controller.execute(WindowActions.Action.cancel);
        }
    }

    // Enter uses the selected command; Alt visits the pane it ran in, Shift does the other of
    // running or editing it.
    function submit(event) {
        if ((event.modifiers & Qt.AltModifier) !== 0) {
            root.controller.history.execute(HistoryController.Action.visit);
        } else if (!root.controller.history.loading) {
            root.controller.history.use(root.state.selection, (event.modifiers & Qt.ShiftModifier) !== 0);
        }
    }

    function page(older) {
        if (root.state.inspecting && root.pageInspector) {
            root.pageInspector(older);
        } else {
            root.controller.history.execute(older ? HistoryController.Action.older : HistoryController.Action.newer);
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

        const control = (event.modifiers & root.controller.controlModifier) !== 0;
        const command = (event.modifiers & root.controller.superModifier) !== 0;
        if (command && event.key === Qt.Key_Backspace) {
            root.controller.history.execute(HistoryController.Action.erase);
            return true;
        }

        if ((control || command) && event.key === Qt.Key_C) {
            if (root.queryField && root.queryField.selectionStart !== root.queryField.selectionEnd) {
                root.queryField.copy();
            } else {
                root.controller.history.execute(HistoryController.Action.copy);
            }

            return true;
        }

        if (!control || (event.modifiers & Qt.AltModifier) !== 0) {
            return false;
        }

        switch (event.key) {
        case Qt.Key_D:
            root.controller.history.execute(HistoryController.Action.erase);
            return true;
        case Qt.Key_O:
            root.controller.history.execute(HistoryController.Action.inspect);
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

            root.controller.history.use(root.state.selection);
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
