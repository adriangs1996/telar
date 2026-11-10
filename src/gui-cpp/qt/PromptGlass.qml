import QtQuick
import QtQuick.Effects

// The glass skin: the terminal behind the island, blurred. Loaded only for that skin, since
// it is the one that pays for a texture of the pane and a blur pass on every change behind it.
Item {
    id: root

    property Item backdrop: null
    property Item island: null
    property real radius: 0

    ShaderEffectSource {
        id: capture
        sourceItem: root.backdrop
        sourceRect: root.backdrop && root.island ? root.island.mapToItem(root.backdrop, 0, 0, root.island.width, root.island.height) : Qt.rect(0, 0, 0, 0)
        live: true
        visible: false
    }

    Rectangle {
        id: mask
        anchors.fill: parent
        radius: root.radius
        visible: false
        layer.enabled: true
    }

    MultiEffect {
        anchors.fill: parent
        source: capture
        blurEnabled: true
        blur: 1
        blurMax: 32
        saturation: 0.2
        maskEnabled: true
        maskSource: mask
    }
}
