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
    signal closed(int index)
    signal added()

    height: shown ? 30 * ratio : 0
    visible: shown
    clip: true

    Row {
        id: strip
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

                // The room of the mark that closes it is kept, so the names do not move.
                width: Math.min(label.implicitWidth + 42 * root.ratio, 240 * root.ratio)
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
                    x: 12 * root.ratio
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    width: Math.min(implicitWidth, parent.width - 38 * root.ratio)
                    text: tab.modelData.name.length > 0 ? tab.modelData.name : "[No Name]"
                    color: tab.current ? root.colors.text : Qt.alpha(root.colors.text, 0.6)
                    font.pixelSize: root.typography.small
                    textFormat: Text.PlainText
                    elide: Text.ElideMiddle
                }

                // Changes that were not written, where the mark that closes it would be.
                Rectangle {
                    x: parent.width - width - 13 * root.ratio
                    y: Math.round((parent.height - height) / 2)
                    width: 6 * root.ratio
                    height: width
                    radius: width / 2
                    color: root.colors.yellow
                    visible: (tab.modelData.modified ?? false) && !hover.hovered
                }

                // Closes the tab page: shown on the one in use and on the one pointed at.
                Text {
                    x: parent.width - width - 10 * root.ratio
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: "\u00d7"
                    color: closing.hovered ? root.colors.text : Qt.alpha(root.colors.text, 0.45)
                    font.pixelSize: root.typography.small
                    visible: hover.hovered || (tab.current && !(tab.modelData.modified ?? false))

                    HoverHandler {
                        id: closing
                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: root.closed(tab.index + 1)
                    }
                }
            }
        }
    }

    // Another tab page.
    Text {
        x: strip.x + strip.width + 8 * root.ratio
        width: 22 * root.ratio
        height: parent.height
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "+"
        color: adding.hovered ? root.colors.text : Qt.alpha(root.colors.text, 0.5)
        font.pixelSize: root.typography.body
        visible: root.shown

        HoverHandler {
            id: adding
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onTapped: root.added()
        }
    }

    Rectangle {
        y: parent.height - height
        width: parent.width
        height: Math.max(1, root.ratio) / Screen.devicePixelRatio
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }
}
