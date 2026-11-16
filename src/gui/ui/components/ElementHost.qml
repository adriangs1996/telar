pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// Draws one slot instance a mod rendered. `content` comes from a record's `elements` map;
// `builtins` names the QML pieces `ui.builtin` may place inside it.
Item {
    id: elementHost

    required property var content
    required property var colors
    required property var typography
    property real ratio: 1
    property var builtins: ({})
    readonly property var nodes: content?.nodes ?? []

    // A click on an element of `content`; the window runs its callback, action or link.
    signal elementActivated(string slot, string key, string revision, int element)

    implicitWidth: root.implicitWidth
    implicitHeight: root.implicitHeight

    function activate(element) {
        if (element) elementActivated(content.slot, content.key, content.revision, element.index);
    }

    ElementNode {
        id: root
        anchors.fill: parent
        host: elementHost
        element: elementHost.nodes.length > 0 ? elementHost.nodes[0] : null
    }
}
