pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

NativeAgentStatus {
    id: root

    required property var colors
    required property var typography
    required property var geometry
    property var pulseAlpha: undefined

    readonly property real glyphWidth: record.statusGlyph.length > 0 ? geometry.statusSide : 0
    readonly property real glyphSpace: glyphWidth > 0 ? glyphWidth + geometry.statusGap : 0
    readonly property bool fullFits: glyphSpace + fullMeasure.implicitWidth <= width
    readonly property bool wordFits: glyphSpace + wordMeasure.implicitWidth <= width
    readonly property string label: fullFits ? statusText : wordFits ? record.statusWord : ""
    readonly property real labelWidth: fullFits ? fullMeasure.implicitWidth : wordFits ? wordMeasure.implicitWidth : 0
    readonly property real usedWidth: Math.min(width, glyphWidth + labelWidth + (glyphWidth > 0 && labelWidth > 0 ? geometry.statusGap : 0))
    readonly property color ink: colors[record.statusColor]

    NativeChromeText {
        id: fullMeasure
        text: root.statusText
        pixelSize: root.typography.small
        visible: false
    }

    NativeChromeText {
        id: wordMeasure
        text: root.record.statusWord
        pixelSize: root.typography.small
        visible: false
    }

    ChromeIcon {
        objectName: "agentStatusGlyph"
        x: root.width - root.usedWidth
        width: Math.min(root.usedWidth, root.glyphWidth)
        height: root.height
        glyph: root.record.statusGlyph
        primaryFamily: root.typography.primaryFamily ?? ""
        primaryStyle: root.typography.primaryStyle ?? ""
        color: root.ink
        pixelSize: root.typography.title
        opacity: root.record.working ? (root.pulseAlpha ?? root.animatedAlpha) : 1
        visible: root.glyphWidth > 0
    }

    ChromeText {
        objectName: "agentStatusLabel"
        x: root.width - root.labelWidth
        width: root.labelWidth
        height: root.height
        text: root.label
        color: root.ink
        pixelSize: root.typography.small
        elide: Text.ElideNone
        visible: root.labelWidth > 0
    }
}
