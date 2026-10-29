pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

MachineChromeLayout {
    id: root

    required property var colors

    visible: shown
    clip: true

    Repeater {
        model: root.items

        delegate: AbstractButton {
            id: control
            objectName: "machineChromeControl"
            required property var record

            x: record.bounds.x
            y: record.bounds.y
            width: record.bounds.width
            height: record.bounds.height
            enabled: record.enabled
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            padding: 0
            font.family: "IBM Plex Sans"
            font.pixelSize: root.style.pixelSize
            font.weight: record.bold ? Font.DemiBold : Font.Normal
            contentItem: null
            background: NativeRoundedRectangle {
                color: control.record.active ? root.style.activeBackground : control.hovered || control.visualFocus ? root.style.hoverBackground : "transparent"
                radius: control.record.radius
            }
            onClicked: root.activate(record.key)

            ChromeText {
                x: control.record.labelBounds.x - control.record.bounds.x
                y: control.record.labelBounds.y - control.record.bounds.y
                width: control.record.labelBounds.width
                height: control.record.labelBounds.height
                text: control.record.text
                color: control.record.active ? root.style.activeText : control.hovered || control.visualFocus ? root.colors.text : root.colors.subtext0
                emphasized: control.record.bold
                pixelSize: root.style.pixelSize
                elide: Text.ElideNone
                clip: true
                Accessible.ignored: true
            }

            NativeRoundedRectangle {
                x: control.record.discBounds.x - control.record.bounds.x
                y: control.record.discBounds.y - control.record.bounds.y
                width: control.record.discBounds.width
                height: control.record.discBounds.height
                radius: Math.max(width, height)
                color: control.record.ink
                visible: width > 0 && height > 0 && control.record.ink.a > 0
            }

            NativeRoundedRectangle {
                x: control.record.attentionBounds.x - control.record.bounds.x
                y: control.record.attentionBounds.y - control.record.bounds.y
                width: control.record.attentionBounds.width
                height: control.record.attentionBounds.height
                radius: Math.max(width, height)
                color: root.style.attention
                visible: width > 0 && height > 0
            }

            Accessible.name: record.accessible
            Accessible.role: Accessible.Button
        }
    }
}
