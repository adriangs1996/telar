import QtQuick
import Telar.Gui

Item {
    id: root

    required property var mark
    required property var colors
    required property real pixelSize
    property real ratio: 1
    property bool dimmed: false
    property string primaryFamily
    property string primaryStyle

    readonly property int provider: mark.providerMark ?? 0
    readonly property real dimmedAlpha: providerInk.dimmedAlpha

    ProviderMark {
        id: providerInk
        objectName: "applicationProviderMark"
        anchors.fill: parent
        provider: root.provider
        color: root.colors.text
        ratio: root.ratio
        opacity: root.dimmed ? root.dimmedAlpha : 1
        visible: root.provider !== 0
    }

    ChromeIcon {
        objectName: "applicationGlyph"
        anchors.fill: parent
        glyph: root.mark.glyph ?? "\uea85"
        primaryFamily: root.primaryFamily
        primaryStyle: root.primaryStyle
        color: root.dimmed ? root.colors.overlay1 : root.colors.subtext0
        pixelSize: root.pixelSize
        visible: root.provider === 0
    }
}
