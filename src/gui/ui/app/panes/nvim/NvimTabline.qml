pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// Neovim's tab pages as a strip of telar's own over the editor: the current one lit, a click
// to go to another, each with the icon of the type of the file it shows. It takes no room
// while Neovim has a single tab.
Item {
    id: root

    // The editor's tabs: currentTab, tabs [{handle, name, icon, iconTone, modified, diagnostics}].
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
                readonly property int diagnostics: modelData.diagnostics ?? 0
                readonly property real noted: diagnostics > 0 ? count.width + 8 * root.ratio : 0
                readonly property real iconSide: Math.round(root.typography.small * 1.2)

                width: Math.min(label.implicitWidth + iconSide + noted + 48 * root.ratio, 260 * root.ratio)
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

                ChromeIcon {
                    id: kind
                    x: 10 * root.ratio
                    y: Math.round((parent.height - height) / 2)
                    width: tab.iconSide
                    height: tab.iconSide
                    glyph: tab.modelData.icon ?? ""
                    pixelSize: tab.iconSide
                    color: root.colors[tab.modelData.iconTone ?? "subtext0"] ?? root.colors.subtext0
                    opacity: tab.current ? 1 : 0.7
                }

                Text {
                    id: label
                    x: kind.x + kind.width + 6 * root.ratio
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    width: Math.min(implicitWidth, parent.width - x - tab.noted - 26 * root.ratio)
                    text: tab.modelData.name.length > 0 ? tab.modelData.name : "[No Name]"
                    color: tab.current ? root.colors.text : Qt.alpha(root.colors.text, 0.6)
                    font.pixelSize: root.typography.small
                    textFormat: Text.PlainText
                    elide: Text.ElideMiddle
                }

                // The warnings and the errors of what it shows, after its name.
                Row {
                    id: count
                    x: label.x + label.width + 8 * root.ratio
                    height: parent.height
                    spacing: 3 * root.ratio
                    visible: tab.diagnostics > 0

                    ChromeIcon {
                        y: Math.round((parent.height - height) / 2)
                        width: Math.round(root.typography.small * 1.05)
                        height: width
                        glyph: "\uea6c"
                        pixelSize: width
                        color: root.colors.yellow
                    }

                    Text {
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                        text: tab.diagnostics
                        color: root.colors.yellow
                        font.pixelSize: root.typography.small
                    }
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
                ChromeIcon {
                    x: parent.width - width - 9 * root.ratio
                    y: Math.round((parent.height - height) / 2)
                    width: Math.round(root.typography.small * 0.85)
                    height: width
                    glyph: "\uea76"
                    pixelSize: width
                    color: closing.hovered ? root.colors.text : Qt.alpha(root.colors.text, 0.45)
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
    ChromeIcon {
        x: strip.x + strip.width + 10 * root.ratio
        y: Math.round((parent.height - height) / 2)
        width: Math.round(root.typography.small * 1.1)
        height: width
        glyph: "\uea60"
        pixelSize: width
        color: adding.hovered ? root.colors.text : Qt.alpha(root.colors.text, 0.5)
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
