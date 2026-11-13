pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root

    property bool interactive: true
    signal activated

    // Qt keeps an active Tab target eligible until focus leaves it.
    activeFocusOnTab: root.interactive || root.activeFocus
    Keys.enabled: root.interactive || root.activeFocus
    Keys.onPressed: event => {
        if (event.key !== Qt.Key_Space && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) {
            return;
        }

        if ((event.modifiers & ~Qt.KeypadModifier) !== Qt.NoModifier) {
            return;
        }

        event.accepted = true;
        if (root.interactive && !event.isAutoRepeat) {
            root.activated();
        }
    }
    Keys.onEscapePressed: event => {
        root.focus = false;
        event.accepted = false;
    }
    Keys.onReleased: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            event.accepted = true;
        }
    }
}
