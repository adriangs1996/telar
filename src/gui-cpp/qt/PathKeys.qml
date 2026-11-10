import QtQuick
import Telar.Gui

// The path search's keys, shared by the dialog and the prompt line.
QtObject {
    id: root

    required property var controller

    // Enter inserts the path relative to the pane's directory; Alt or Shift, absolute.
    function submit(event) {
        root.controller.insertPath((event.modifiers & (Qt.AltModifier | Qt.ShiftModifier)) !== 0);
    }

    // Whether `event` was one of the search's Control commands, which it then ran.
    function handle(event) {
        if ((event.modifiers & root.controller.controlModifier) === 0 || (event.modifiers & Qt.AltModifier) !== 0) {
            return false;
        }

        switch (event.key) {
        case Qt.Key_J:
        case Qt.Key_K:
            root.controller.movePathSelection(event.key === Qt.Key_J ? 1 : -1);
            return true;
        case Qt.Key_H:
            root.controller.execute(GuiController.Action.cancel);
            return true;
        case Qt.Key_L:
            root.controller.insertPath(false);
            return true;
        default:
            return false;
        }
    }
}
