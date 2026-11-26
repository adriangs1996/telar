pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

MachineChromeLayout {
    id: root

    required property var colors
    property var typography: ({})
    // The row the arrows of the roster's menu move to, -1 for none.
    property int selection: -1
    // A row of the list was chosen; the menu that holds the list closes on it.
    signal chosen()

    // The list's status line reads on its surface, the menu's or the sidebar's, under the
    // selection's fill too.
    readonly property color listSurface: roster ? colors.panel_bg : colors.sidebarBackground
    readonly property color listGround: Qt.tint(Qt.rgba(listSurface.r, listSurface.g, listSurface.b, 1), style.activeBackground ?? "transparent")
    readonly property color secondary: ChromeStyle.legible(colors.subtext0, listGround, 4.5)

    function move(delta) {
        if (listRows.count > 0) selection = Math.max(0, Math.min(listRows.count - 1, selection + delta));
    }

    // The roster starts on the machine the window shows.
    function selectCurrent() {
        selection = -1;
        for (let index = 0; index < listRows.count; ++index) {
            if (listRows.itemAt(index)?.current) selection = index;
        }
    }

    function chooseSelection() {
        const row = listRows.itemAt(selection);
        if (!row || !row.enabled) return;

        root.activate(row.record.key);
        root.chosen();
    }

    visible: shown
    clip: true

    Repeater {
        id: listRows
        model: !root.inlineFacts && !root.segment ? root.items : []

        delegate: AbstractButton {
            id: row
            objectName: "machineListRow"
            required property var record
            required property int index

            x: record.bounds.x
            y: record.bounds.y
            width: record.bounds.width
            height: record.bounds.height
            enabled: record.enabled
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            padding: 0
            contentItem: null
            // The roster marks the machine the window shows; the sidebar's list never holds it.
            readonly property bool current: record.active ?? false
            // The rows can arrive after the menu opens: the roster then starts on this one.
            Component.onCompleted: if (current && root.selection < 0) root.selection = index
            background: NativeRoundedRectangle {
                color: row.index === root.selection ? root.style.activeBackground : row.hovered || row.visualFocus ? root.style.hoverBackground : "transparent"
                radius: root.style.rowRadius
                borderColor: root.colors.accent
                borderAlpha: ChromeStyle.focusAlpha
                borderWidth: row.visualFocus ? 1 / Screen.devicePixelRatio : 0
            }
            onClicked: {
                root.activate(record.key);
                root.chosen();
            }

            ProviderMark {
                objectName: "machineCurrentMark"
                x: row.record.markBounds.x - row.record.bounds.x
                y: row.record.markBounds.y - row.record.bounds.y
                width: row.record.markBounds.width
                height: row.record.markBounds.height
                symbol: "check"
                color: root.colors.chromeText
                visible: row.current && width > 0
            }

            HoverHandler { cursorShape: Qt.PointingHandCursor }

            // The machine's initial in its neutral disc, as the bar's switch draws it; the dot of
            // its link sits at the corner.
            MachineAvatar {
                id: avatar
                objectName: "machineAvatar"
                x: row.record.avatarBounds.x - row.record.bounds.x
                y: row.record.avatarBounds.y - row.record.bounds.y
                width: row.record.avatarBounds.width
                height: row.record.avatarBounds.height
                colors: root.colors
                ink: row.record.ink
                initial: row.record.initial
                initialName: "machineInitial"
                pixelSize: root.style.smallSize
                opacity: row.enabled ? 1 : 0.5
            }

            NativeRoundedRectangle {
                objectName: "machineLinkDot"
                x: row.record.dotBounds.x - row.record.bounds.x
                y: row.record.dotBounds.y - row.record.bounds.y
                width: row.record.dotBounds.width
                height: row.record.dotBounds.height
                radius: Math.max(width, height)
                color: row.enabled ? root.colors.green : root.colors.overlay1
                borderColor: root.colors.sidebarBackground
                borderAlpha: 1
                borderWidth: Math.max(1, Math.round(width / 5))
            }

            ChromeText {
                objectName: "machineListLabel"
                x: row.record.labelBounds.x - row.record.bounds.x
                y: row.record.labelBounds.y - row.record.bounds.y
                width: row.record.labelBounds.width
                height: row.record.labelBounds.height
                text: row.record.text
                color: row.enabled ? root.colors.chromeText : root.colors.overlay1
                pixelSize: root.style.pixelSize
                emphasized: true
                Accessible.ignored: true
            }

            ChromeText {
                objectName: "machineListStatus"
                x: row.record.statusBounds.x - row.record.bounds.x
                y: row.record.statusBounds.y - row.record.bounds.y
                width: row.record.statusBounds.width
                height: row.record.statusBounds.height
                text: row.record.status
                color: row.record.attention ? root.style.attention : root.secondary
                pixelSize: root.style.smallSize
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
