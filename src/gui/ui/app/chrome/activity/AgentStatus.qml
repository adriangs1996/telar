pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// An agent's state and how long it has held it, right-aligned: narrow cards drop the clock, then the word.
NativeAgentStatus {
    id: root

    required property var colors
    required property var typography

    readonly property bool fullFits: fullMeasure.implicitWidth <= width
    readonly property bool wordFits: wordMeasure.implicitWidth <= width
    readonly property string label: fullFits ? statusText : wordFits ? record.statusWord : ""
    readonly property real usedWidth: Math.min(width, fullFits ? fullMeasure.implicitWidth : wordFits ? wordMeasure.implicitWidth : 0)

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

    ChromeText {
        objectName: "agentStatusLabel"
        x: root.width - root.usedWidth
        width: root.usedWidth
        height: root.height
        text: root.label
        color: root.colors[root.record.statusColor]
        pixelSize: root.typography.small
        elide: Text.ElideNone
        visible: root.usedWidth > 0
    }
}
