pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// Neovim's tab pages as a strip of telar's own over the editor: the current one lit, a click
// to go to another. It takes no room while Neovim has a single tab.
Item {
    id: root

    // The editor's tabs: currentTab, tabs [{handle, name}].
    required property var tabline
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var tabs: tabline.tabs ?? []
    readonly property bool shown: tabs.length > 1
    // A click on the tab at `index`, counted from one as Neovim counts its tab pages.
    signal chosen(int index)

    height: shown ? 30 * ratio : 0
    visible: shown
    clip: true

    Row {
        x: 6 * root.ratio
        height: parent.height
        spacing: 2 * root.ratio

        Repeater {
            model: root.tabs

            delegate: Item {
                id: tab

                required property var modelData
                required property int index
                readonly property bool current: modelData.handle === root.tabline.currentTab

                width: Math.min(label.implicitWidth + 24 * root.ratio, 220 * root.ratio)
                height: parent.height

                HoverHandler {
                    id: hover
                }

                TapHandler {
                    onTapped: root.chosen(tab.index + 1)
                }

                NativeRoundedRectangle {
                    y: 4 * root.ratio
                    width: parent.width
                    height: parent.height - 8 * root.ratio
                    radius: ChromeStyle.controlRadius * root.ratio
                    color: Qt.alpha(root.colors.text, tab.current ? ChromeStyle.selectionAlpha : hover.hovered ? ChromeStyle.hoverAlpha : 0)
                }

                Text {
                    id: label
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 16 * root.ratio)
                    text: tab.modelData.name.length > 0 ? tab.modelData.name : "[No Name]"
                    color: tab.current ? root.colors.text : Qt.alpha(root.colors.text, 0.6)
                    font.pixelSize: root.typography.small
                    textFormat: Text.PlainText
                    elide: Text.ElideMiddle
                }
            }
        }
    }

    Rectangle {
        y: parent.height - height
        width: parent.width
        height: Math.max(1, root.ratio) / Screen.devicePixelRatio
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }
}
