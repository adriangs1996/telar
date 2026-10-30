pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "historyHint"

    required property var label
    required property var geometry
    required property var style
    required property var colors
    required property real pixelSize
    property bool actionable: true
    property bool usePresentedHover: false
    property bool presentedHover: false
    property string activationIdentity: ""
    readonly property real keyAdvance: keyText.implicitWidth
    readonly property real wordAdvance: wordText.implicitWidth
    signal activated()
    signal measurementsChanged()

    clip: true
    Accessible.role: actionable ? Accessible.Button : Accessible.StaticText
    Accessible.name: label.word
    Accessible.onPressAction: {
        if (root.enabled && root.actionable) {
            root.activated();
        }
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        color: root.enabled && root.actionable && (root.usePresentedHover ? root.presentedHover : pointer.containsMouse) ? root.colors.surface1 : "transparent"
        radius: root.style.radius
    }

    NativeRoundedRectangle {
        x: root.geometry.keycap.x
        y: root.geometry.keycap.y
        width: root.geometry.keycap.width
        height: root.geometry.keycap.height
        color: "transparent"
        borderColor: Qt.alpha(root.colors.text, root.style.keyRingAlpha)
        borderWidth: root.style.ringWidth
        radius: root.style.radius
    }

    ChromeText {
        id: keyText
        objectName: "historyHintKey"
        x: root.geometry.keyText.x
        y: root.geometry.keyText.y
        width: root.geometry.keyText.width
        height: root.geometry.keyText.height
        text: root.label.key
        color: root.colors.text
        opacity: root.style.keyTextAlpha
        pixelSize: root.pixelSize
        elide: Text.ElideNone
        onImplicitWidthChanged: root.measurementsChanged()
    }

    ChromeText {
        id: wordText
        objectName: "historyHintWord"
        x: root.geometry.word.x
        y: root.geometry.word.y
        width: root.geometry.word.width
        height: root.geometry.word.height
        text: root.label.word
        color: root.colors.subtext0
        pixelSize: root.pixelSize
        elide: Text.ElideNone
        onImplicitWidthChanged: root.measurementsChanged()
    }

    ActionPointer {
        id: pointer
        anchors.fill: parent
        enabled: root.actionable
        identity: root.activationIdentity
        onActivated: root.activated()
    }
}
