pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var record
    required property var colors
    required property var geometry
    property real ratio: 1
    property var pulseAlpha: undefined
    property bool animate: true
    readonly property real outlinePhysicalWidth: 1
    readonly property real density: Screen.devicePixelRatio
    default property alias content: cardContent.data
    signal selected(string key)

    implicitWidth: geometry.width
    implicitHeight: record.compact ? geometry.compactHeight : geometry.height
    enabled: record.enabled ?? true

    NativeRoundedRectangle {
        objectName: "agentCardBackground"
        anchors.fill: parent
        radius: root.geometry.radius
        color: root.record.selected ? root.colors.surface0 : pointer.containsMouse ? root.colors.surface1 : "transparent"
        visible: root.record.selected || pointer.containsMouse
    }

    NativeRoundedRectangle {
        objectName: "agentCardOutline"
        anchors.fill: parent
        radius: root.geometry.radius
        borderWidth: root.outlinePhysicalWidth / root.density
        borderColor: root.colors.surface1
        visible: root.record.selected ?? false
    }

    Rectangle {
        objectName: "activityTreeGuide"
        x: -root.geometry.taskIndent / 2
        width: root.outlinePhysicalWidth / root.density
        height: root.height
        color: root.colors.surface1
        visible: (root.record.depth ?? 0) > 0
    }

    Item {
        id: cardContent
        anchors.fill: parent
    }

    MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.selected(root.record.key)
    }

    Accessible.role: Accessible.Button
    Accessible.onPressAction: root.selected(record.key)
}
