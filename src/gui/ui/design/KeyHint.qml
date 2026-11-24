pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// One shortcut an overlay's footer teaches: its keys, then the word for what they do.
Item {
    id: root
    objectName: "keyHint"

    required property var colors
    required property var typography
    required property var keys
    required property string word
    property real ratio: 1
    // The key of what Enter does: its caps are filled with the accent.
    property bool primary: false
    property bool actionable: false
    property string activationIdentity: ""
    readonly property real keyGap: 3 * ratio
    // A cap is as tall as a line of its label, centred in the footer, never its whole height.
    readonly property real capHeight: Math.min(height, Math.max(20 * ratio, typography.smallRow ?? 0))
    readonly property real wordGap: 6 * ratio
    readonly property real hoverInset: 4 * ratio
    signal activated()

    implicitWidth: keysRow.implicitWidth + wordGap + wordText.implicitWidth
    implicitHeight: typography.smallRow
    Accessible.role: actionable ? Accessible.Button : Accessible.StaticText
    Accessible.name: word
    Accessible.onPressAction: if (root.enabled && root.actionable)
        root.activated()

    NativeRoundedRectangle {
        x: -root.hoverInset
        y: (root.height - height) / 2
        width: root.width + 2 * root.hoverInset
        height: Math.min(root.height, root.typography.smallRow + 2 * root.hoverInset)
        radius: ChromeStyle.controlRadius * root.ratio
        color: Qt.alpha(root.colors.text, ChromeStyle.hoverAlpha)
        visible: root.actionable && root.enabled && pointer.containsMouse
    }

    Row {
        id: keysRow
        height: parent.height
        spacing: root.keyGap

        Repeater {
            model: root.keys
            delegate: PaletteKeycap {
                required property string modelData
                y: Math.round((keysRow.height - height) / 2)
                width: implicitWidth
                height: root.capHeight
                primary: root.primary
                colors: root.colors
                typography: root.typography
                text: modelData
                ratio: root.ratio
            }
        }
    }

    ChromeText {
        id: wordText
        x: keysRow.width + root.wordGap
        width: implicitWidth
        height: parent.height
        text: root.word
        color: root.colors.subtext0
        pixelSize: root.typography.small
        elide: Text.ElideNone
    }

    ActionPointer {
        id: pointer
        anchors.fill: parent
        enabled: root.actionable
        identity: root.activationIdentity
        onActivated: root.activated()
    }
}
