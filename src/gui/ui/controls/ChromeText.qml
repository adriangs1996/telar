pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property real pixelSize
    property bool emphasized: false
    property bool caption: false
    property string text
    property color color: "black"
    property int elide: Text.ElideRight
    property int horizontalAlignment: Text.AlignLeft
    property bool wholePixelCentering: false
    property int verticalAlignment: Text.AlignVCenter
    property real fadeWidth: 0
    readonly property bool directRendering: glyphs.available && verticalAlignment === Text.AlignVCenter
    readonly property Text fallbackText: fallback.item as Text

    implicitWidth: glyphs.supported ? glyphs.implicitWidth : (fallbackText?.implicitWidth ?? 0)
    implicitHeight: glyphs.supported ? glyphs.implicitHeight : (fallbackText?.implicitHeight ?? 0)
    baselineOffset: glyphs.supported ? glyphs.baselineOffset : (fallbackText?.baselineOffset ?? 0)
    clip: !directRendering

    Accessible.role: Accessible.StaticText
    Accessible.name: text

    NativeChromeText {
        id: glyphs
        anchors.fill: parent
        text: root.text
        pixelSize: root.pixelSize
        color: root.color
        fadeWidth: root.fadeWidth
        emphasized: root.emphasized
        caption: root.caption
        elide: root.elide
        horizontalAlignment: root.horizontalAlignment
        wholePixelCentering: root.wholePixelCentering
        visible: root.directRendering
    }

    Loader {
        id: fallback
        anchors.fill: parent
        active: !root.directRendering
        layer.enabled: root.fadeWidth > 0 && GraphicsInfo.api !== GraphicsInfo.Software && GraphicsInfo.api !== GraphicsInfo.Unknown
        layer.effect: ShaderEffect {
            property variant source
            property real fadeStart: Math.max(0, 1 - root.fadeWidth / Math.max(1, root.width))
            fragmentShader: "qrc:/telar/shaders/tab_caption.frag.qsb"
        }
        sourceComponent: Text {
            text: root.text
            color: root.color
            font.family: "IBM Plex Sans"
            font.pixelSize: root.pixelSize
            font.weight: root.emphasized ? Font.DemiBold : Font.Normal
            textFormat: Text.PlainText
            verticalAlignment: root.verticalAlignment
            horizontalAlignment: root.horizontalAlignment
            elide: width > 0 ? root.elide : Text.ElideNone
            renderType: Text.NativeRendering
            Accessible.ignored: true
        }
    }
}
