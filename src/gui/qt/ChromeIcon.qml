pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property string glyph
    required property color color
    required property real pixelSize
    property string primaryFamily
    property string primaryStyle
    readonly property bool directRendering: nativeIcon.available

    NativeChromeIcon {
        id: nativeIcon
        anchors.fill: parent
        glyph: root.glyph
        color: root.color
        pixelSize: root.pixelSize
        primaryFamily: root.primaryFamily
        primaryStyle: root.primaryStyle
        visible: root.directRendering
    }

    Loader {
        anchors.fill: parent
        active: !root.directRendering
        sourceComponent: Item {
            id: fallback

            readonly property real glyphSizeRatio: 0.85
            readonly property real oversampleScale: 2
            readonly property real targetSide: Math.min(width, height, Math.round(root.pixelSize * glyphSizeRatio))
            readonly property rect inkBounds: metrics.tightBoundingRect
            readonly property real glyphScale: inkBounds.width > 0 && inkBounds.height > 0 ? Math.min(targetSide / inkBounds.width, targetSide / inkBounds.height) : 1

            TextMetrics {
                id: metrics
                text: root.glyph
                font: ink.font
            }

            Text {
                id: ink
                x: (fallback.width - fallback.inkBounds.width * fallback.glyphScale) / 2 - fallback.inkBounds.x * fallback.glyphScale
                y: (fallback.height - fallback.inkBounds.height * fallback.glyphScale) / 2 - (baselineOffset + fallback.inkBounds.y) * fallback.glyphScale
                text: root.glyph
                color: root.color
                textFormat: Text.PlainText
                font.family: "Symbols Nerd Font Mono"
                font.pixelSize: Math.max(1, Math.round(root.pixelSize * fallback.oversampleScale))
                renderType: Text.NativeRendering
                transform: Scale {
                    xScale: fallback.glyphScale
                    yScale: fallback.glyphScale
                }
            }
        }
    }
}
