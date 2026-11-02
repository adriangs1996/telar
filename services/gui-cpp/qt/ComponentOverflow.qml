pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

Item {
    id: root

    required property var controller
    required property var colors
    required property var typography
    property var entries: []
    property int maximumCount: 0
    property real ratio: 1
    property bool initialized: false
    readonly property real margin: 8 * ratio
    readonly property real gap: 6 * ratio
    readonly property real panelWidth: 300 * ratio
    readonly property real panelPadding: 14 * ratio
    readonly property real headerHeight: 28 * ratio
    readonly property real closeSide: 22 * ratio
    readonly property real rowHeight: 26 * ratio
    readonly property real chipPadding: 5 * ratio
    readonly property real chipHeight: 16 * ratio
    implicitWidth: measure.implicitWidth + 2 * chipPadding
    visible: entries.length > 0 && width > 0

    Component.onCompleted: initialized = true
    onVisibleChanged: {
        if (initialized && !visible) {
            overflowPopup.close();
        }
    }

    AbstractButton {
        id: chip
        objectName: "componentOverflow"
        anchors.centerIn: parent
        width: parent.width
        height: Math.min(parent.height, root.chipHeight)
        hoverEnabled: true
        Accessible.name: "Show " + root.entries.length + " hidden components"
        contentItem: Text {
            text: "+" + root.entries.length
            color: chip.hovered || chip.activeFocus || overflowPopup.visible ? root.colors.text : root.colors.subtext0
            font.family: "IBM Plex Sans"
            font.pixelSize: root.typography.small
            textFormat: Text.PlainText
            renderType: Text.NativeRendering
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: NativeRoundedRectangle {
            color: chip.hovered || chip.activeFocus || overflowPopup.visible ? root.colors.surface1 : root.colors.surface0
            radius: 4 * root.ratio
        }
        Keys.onEscapePressed: event => {
            chip.focus = false;
            event.accepted = false;
        }
        onClicked: overflowPopup.open()
    }

    Text {
        id: measure
        visible: false
        text: "+" + "9".repeat(Math.max(1, root.maximumCount).toString().length)
        font.family: "IBM Plex Sans"
        font.pixelSize: root.typography.small
        textFormat: Text.PlainText
        renderType: Text.NativeRendering
    }

    Popup {
        id: overflowPopup
        parent: root
        x: root.width - width
        y: -height - root.gap
        width: Math.max(0, Math.min(root.panelWidth, (root.Window.window?.width ?? root.panelWidth) - 2 * root.margin))
        height: Math.max(0, Math.min((root.Window.window?.height ?? 640) - 2 * root.margin, 2 * padding + root.headerHeight + root.gap + rows.implicitHeight))
        padding: root.panelPadding
        margins: root.margin
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: DialogSurface { colors: root.colors; ratio: root.ratio }

        Connections {
            target: overflowPopup.visible ? root.controller : null
            function onComponentsChanged() {
                if (root.controller.componentPanel.open ?? false) {
                    overflowPopup.close();
                }
            }
        }

        contentItem: Item {
            ChromeText {
                width: Math.max(0, parent.width - root.closeSide)
                height: root.headerHeight
                text: "More"
                color: root.colors.text
                pixelSize: root.typography.body ?? root.typography.small
                emphasized: true
            }
            ChromeButton {
                x: parent.width - width
                y: (root.headerHeight - height) / 2
                width: root.closeSide
                height: width
                colors: root.colors
                text: "×"
                pixelSize: root.typography.body ?? root.typography.small
                cornerRadius: 5 * root.ratio
                Accessible.name: "Close hidden components"
                onClicked: overflowPopup.close()
            }
            Flickable {
                id: body
                y: root.headerHeight + root.gap
                width: parent.width
                height: Math.max(0, parent.height - y)
                contentHeight: rows.implicitHeight
                clip: true
                Column {
                    id: rows
                    width: parent.width
                    Repeater {
                        model: overflowPopup.visible ? root.entries : []
                        delegate: ComponentBranch {
                            required property var modelData
                            width: rows.width
                            height: root.rowHeight
                            rowHeight: root.rowHeight
                            controller: root.controller
                            surface: modelData.surface
                            roots: [modelData.index]
                            colors: root.colors
                            typography: root.typography
                            ratio: root.ratio
                            horizontal: false
                            fit: false
                        }
                    }
                }
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }
}
