pragma ComponentBehavior: Bound

import QtQuick

// Draws one slot instance a mod rendered. `content` comes from a record's `elements` map;
// `builtins` names the QML pieces `ui.builtin` may place inside it.
Item {
    id: elementHost

    required property var content
    required property var colors
    required property var typography
    property real ratio: 1
    property var controller: null
    property var builtins: ({})
    readonly property var nodes: content?.nodes ?? []

    implicitWidth: root.implicitWidth
    implicitHeight: root.implicitHeight

    function activate(element) {
        if (controller && element) controller.activateElement(content.slot, content.key, content.revision, element.index);
    }

    ElementNode {
        id: root
        anchors.fill: parent
        host: elementHost
        element: elementHost.nodes.length > 0 ? elementHost.nodes[0] : null
    }
}
