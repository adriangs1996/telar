pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The footer every searchable overlay shares: a separator, then the shortcuts that apply now.
// A hint is {keys: [...], word, action}; one with an action can also be clicked.
Item {
    id: root
    objectName: "keyHintBar"

    required property var colors
    required property var typography
    property real ratio: 1
    property var hints: []
    // One hint or a list of them, shown at the right edge while they fit beside the hints. One
    // with `primary` has its keys in the accent.
    property var trailing: null
    readonly property var trailingHints: trailing === null ? [] : Array.isArray(trailing) ? trailing : [trailing]
    readonly property real inset: 16 * ratio
    readonly property real hintGap: 16 * ratio
    signal activated(string action)

    clip: true

    Rectangle {
        width: parent.width
        height: Math.min(root.ratio, parent.height)
        color: root.colors.surface1
    }

    Row {
        id: hintsRow
        x: root.inset
        height: parent.height
        spacing: root.hintGap

        Repeater {
            model: root.hints
            delegate: KeyHint {
                required property var modelData
                height: hintsRow.height
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                keys: modelData.keys
                word: modelData.word
                actionable: (modelData.action ?? "").length > 0
                activationIdentity: modelData.action ?? ""
                onActivated: root.activated(modelData.action)
            }
        }
    }

    Row {
        id: trailingRow
        x: root.width - root.inset - width
        height: parent.height
        spacing: root.hintGap
        visible: root.trailingHints.length > 0 && x >= hintsRow.x + hintsRow.width + root.hintGap

        Repeater {
            model: root.trailingHints
            delegate: KeyHint {
                required property var modelData
                height: trailingRow.height
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                keys: modelData.keys ?? []
                word: modelData.word ?? ""
                primary: modelData.primary ?? false
                actionable: (modelData.action ?? "").length > 0
                activationIdentity: modelData.action ?? ""
                onActivated: root.activated(modelData.action)
            }
        }
    }
}
