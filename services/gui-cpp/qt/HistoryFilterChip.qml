pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property string text
    required property var geometry
    required property var style
    required property var colors
    required property real pixelSize
    property string valueText: ""
    property string activationIdentity: text
    property bool selected: false
    property bool danger: false
    readonly property real labelAdvance: label.implicitWidth
    readonly property real valueAdvance: value.implicitWidth
    signal activated()
    signal measurementsChanged()

    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: {
        if (root.enabled && root.visible) {
            root.activated();
        }
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        visible: root.selected || pointer.containsMouse
        color: root.colors.surface1
        radius: root.style.chipRadius
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        visible: root.danger && root.selected
        color: "transparent"
        borderColor: Qt.alpha(root.colors.red, root.style.dangerRingAlpha)
        borderWidth: root.style.ringWidth
        radius: root.style.chipRadius
    }

    ChromeText {
        id: label
        x: root.geometry.label.x
        y: root.geometry.label.y
        width: root.geometry.label.width
        height: root.geometry.label.height
        text: root.text
        pixelSize: root.pixelSize
        color: root.danger && root.selected ? root.colors.red : root.selected ? root.colors.text : root.colors.subtext0
        elide: Text.ElideNone
        onImplicitWidthChanged: root.measurementsChanged()
    }

    ChromeText {
        id: value
        objectName: "historyScopeValue"
        x: root.geometry.value.x
        y: root.geometry.value.y
        width: root.geometry.value.width
        height: root.geometry.value.height
        text: root.valueText
        pixelSize: root.pixelSize
        color: root.colors.accent
        elide: Text.ElideNone
        visible: text.length > 0
        onImplicitWidthChanged: root.measurementsChanged()
    }

    ActionPointer {
        id: pointer
        anchors.fill: parent
        identity: root.activationIdentity
        onActivated: root.activated()
    }
}
