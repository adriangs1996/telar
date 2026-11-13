pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

MachineChromeLayout {
    id: root

    required property var colors
    property var typography: ({})

    visible: shown
    clip: true

    Repeater {
        model: !root.inlineFacts && !root.segment ? root.items : []

        delegate: AbstractButton {
            id: row
            objectName: "machineListRow"
            required property var record

            x: record.bounds.x
            y: record.bounds.y
            width: record.bounds.width
            height: record.bounds.height
            enabled: record.enabled
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            padding: 0
            contentItem: null
            background: NativeRoundedRectangle {
                color: row.hovered || row.visualFocus ? root.style.hoverBackground : "transparent"
                radius: root.style.rowRadius
                borderColor: root.colors.accent
                borderAlpha: ChromeStyle.focusAlpha
                borderWidth: row.visualFocus ? 1 / Screen.devicePixelRatio : 0
            }
            onClicked: root.activate(record.key)

            HoverHandler { cursorShape: Qt.PointingHandCursor }

            NativeRoundedRectangle {
                x: row.record.discBounds.x - row.record.bounds.x
                y: row.record.discBounds.y - row.record.bounds.y
                width: row.record.discBounds.width
                height: row.record.discBounds.height
                radius: Math.max(width, height)
                color: row.record.ink.a > 0 ? row.record.ink : root.colors.accent
            }

            ChromeText {
                objectName: "machineListLabel"
                x: row.record.labelBounds.x - row.record.bounds.x
                width: row.record.labelBounds.width
                height: row.height
                text: row.record.text
                color: row.enabled ? root.colors.text : root.colors.overlay1
                pixelSize: root.style.pixelSize
                Accessible.ignored: true
            }

            Item {
                objectName: "machineAgentStack"
                x: row.record.stackBounds.x - row.record.bounds.x
                width: row.record.stackBounds.width
                height: row.height
                visible: width > 0

                Repeater {
                    model: row.record.cards
                    delegate: ApplicationTile {
                        required property var modelData
                        x: modelData.x
                        y: (row.height - height) / 2 + modelData.y
                        z: modelData.layer
                        width: root.style.tileWidth
                        height: root.style.tileHeight
                        rotation: modelData.rotation
                        scale: modelData.scale
                        radius: root.style.tileRadius
                        mark: modelData
                        attentionColor: modelData.attentionColor
                        colors: root.colors
                        typography: root.typography
                        borderColor: "#0a0810"
                        borderAlpha: 0.72
                        borderWidth: 1
                    }
                }
            }

            Accessible.name: record.accessible
            Accessible.role: Accessible.Button
        }
    }

    Repeater {
        model: root.segment ? root.items : []

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
                borderColor: control.visualFocus ? root.colors.accent : root.colors.text
                borderAlpha: control.visualFocus ? ChromeStyle.focusAlpha : ChromeStyle.outlineAlpha
                borderWidth: control.record.active || control.visualFocus ? 1 / Screen.devicePixelRatio : 0
            }
            onClicked: root.activate(record.key)

            ChromeText {
                x: control.record.labelBounds.x - control.record.bounds.x
                y: control.record.labelBounds.y - control.record.bounds.y
                width: control.record.labelBounds.width
                height: control.record.labelBounds.height
                text: control.record.text
                color: control.record.active ? root.style.activeText : root.colors.text
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

    Repeater {
        model: root.inlineFacts ? root.items : []
        delegate: Item {
            id: fact
            objectName: "machineInlineFact"
            required property var record
            x: record.bounds.x
            y: record.bounds.y
            width: record.bounds.width
            height: record.bounds.height
            Accessible.role: Accessible.StaticText
            Accessible.name: record.accessible

            ChromeText {
                x: fact.record.glyphBounds.x - fact.record.bounds.x
                width: fact.record.glyphBounds.width
                height: parent.height
                text: fact.record.glyph
                color: fact.record.ink
                pixelSize: root.style.pixelSize
                elide: Text.ElideNone
                Accessible.ignored: true
            }
            ChromeText {
                x: fact.record.labelBounds.x - fact.record.bounds.x
                width: fact.record.labelBounds.width
                height: parent.height
                text: fact.record.text
                color: root.colors.text
                emphasized: fact.record.bold
                pixelSize: root.style.pixelSize
                elide: Text.ElideNone
                Accessible.ignored: true
            }
            ChromeText {
                x: fact.record.cpuBounds.x - fact.record.bounds.x
                width: fact.record.cpuBounds.width
                height: parent.height
                text: fact.record.cpu
                color: root.colors.text
                pixelSize: root.style.pixelSize
                elide: Text.ElideNone
                Accessible.ignored: true
            }
        }
    }

}
