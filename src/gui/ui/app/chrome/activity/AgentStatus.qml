pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// An agent's state and how long it has held it, right-aligned: narrow cards drop the clock, then the word.
// A process has no state of its own: it idles at its shell or runs a program, for that long.
NativeAgentStatus {
    id: root

    required property var colors
    required property var typography

    readonly property bool process: record.process ?? false
    readonly property bool idle: process && (record.dim ?? false)
    readonly property string word: !process ? (record.statusWord ?? "") : (record.statusWord ?? "").length > 0 ? record.statusWord : idle ? "idle" : "running"
    readonly property string full: process && (record.statusWord ?? "").length === 0 ? word + " " + statusText : statusText
    readonly property bool fullFits: fullMeasure.implicitWidth <= width
    readonly property bool wordFits: wordMeasure.implicitWidth <= width
    readonly property string label: fullFits ? full : wordFits ? word : ""
    readonly property real usedWidth: Math.min(width, fullFits ? fullMeasure.implicitWidth : wordFits ? wordMeasure.implicitWidth : 0)

    NativeChromeText {
        id: fullMeasure
        text: root.full
        pixelSize: root.typography.small
        visible: false
    }

    NativeChromeText {
        id: wordMeasure
        text: root.word
        pixelSize: root.typography.small
        visible: false
    }

    ChromeText {
        objectName: "agentStatusLabel"
        x: root.width - root.usedWidth
        width: root.usedWidth
        height: root.height
        text: root.label
        // A state at rest names its age in the secondary text's ink: the overlay roles are too
        // faint to read at this size.
        color: root.process ? (root.idle || !(root.record.enabled ?? true) ? root.colors.subtext0 : root.colors.green) : root.record.statusColor === "overlay1" || root.record.statusColor === "overlay0" ? root.colors.subtext0 : root.colors[root.record.statusColor]
        pixelSize: root.typography.small
        elide: Text.ElideNone
        visible: root.usedWidth > 0
    }
}
