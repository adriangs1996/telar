import QtQuick
import Telar.Gui

// A chrome button that shows an icon glyph instead of a word.
ChromeButton {
    id: root

    required property string glyph

    text: ""
    contentItem: ChromeIcon {
        glyph: root.glyph
        pixelSize: root.pixelSize
        color: root.pointerHovered || root.visualFocus ? root.colors.text : root.colors.subtext0
        opacity: root.enabled ? 1 : 0.45
    }
}
