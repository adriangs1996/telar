pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// An overlay's title line: the title, an optional note after it, and its buttons at the right.
Item {
    id: root

    required property var colors
    required property var typography
    property string title
    property string note
    property real ratio: 1
    default property alias actions: actionsRow.data
    readonly property real noteGap: 8 * ratio
    readonly property real textWidth: Math.max(0, actionsRow.x - (actionsRow.width > 0 ? noteGap : 0))

    ChromeText {
        id: titleText
        width: Math.min(implicitWidth, root.textWidth)
        height: parent.height
        text: root.title
        color: root.colors.text
        pixelSize: root.typography.body
        emphasized: true
    }

    ChromeText {
        x: titleText.width + root.noteGap
        width: Math.max(0, root.textWidth - x)
        height: parent.height
        text: root.note
        color: root.colors.subtext0
        pixelSize: root.typography.small
        visible: root.note.length > 0
    }

    Row {
        id: actionsRow
        x: root.width - width
        height: parent.height
        spacing: 2 * root.ratio
    }
}
