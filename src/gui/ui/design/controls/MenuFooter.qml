pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The end of a chrome menu: a rule, then the action that adds to what the menu lists. Its plus
// stands in the column of the rows' marks and its words in the column of their names, so it
// reads as one more row and not as a hint.
Item {
    id: root

    required property var colors
    required property var typography
    property real ratio: 1
    property string text
    // The rows' columns, in this item's coordinates: the center of their marks, where their
    // names start.
    readonly property real implicitMarkCenter: Math.round((ChromeStyle.menuRowPadding + ChromeStyle.menuMark / 2) * ratio)
    readonly property real implicitTextX: Math.round((ChromeStyle.menuRowPadding + ChromeStyle.menuMark + ChromeStyle.menuGap) * ratio)
    property real markCenter: implicitMarkCenter
    property real textX: implicitTextX
    readonly property real gap: Math.round(6 * ratio)
    readonly property real actionHeight: Math.round(32 * ratio)
    readonly property real hairline: 1 / Screen.devicePixelRatio
    readonly property real plusSide: Math.round(14 * ratio)
    signal triggered()

    implicitHeight: hairline + gap + actionHeight

    Rectangle {
        objectName: "menuFooterRule"
        width: root.width
        height: root.hairline
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
    }

    ChromeButton {
        id: action
        objectName: "menuFooterAction"
        y: root.hairline + root.gap
        width: root.width
        height: root.actionHeight
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: ChromeStyle.surfaceRadius * root.ratio
        focusPolicy: Qt.NoFocus
        Accessible.name: root.text
        onClicked: root.triggered()
        contentItem: Item {
            ProviderMark {
                objectName: "menuFooterPlus"
                x: root.markCenter - width / 2
                y: (parent.height - height) / 2
                width: root.plusSide
                height: width
                symbol: "plus"
                color: ChromeStyle.legible(root.colors.subtext0, Qt.tint(root.colors.panel_bg, Qt.alpha(root.colors.chromeText, ChromeStyle.hoverAlpha)), 3)
            }

            ChromeText {
                x: root.textX
                width: Math.max(0, parent.width - x - root.gap)
                height: parent.height
                text: root.text
                color: root.colors.chromeText
                pixelSize: root.typography.body
            }
        }
    }
}
