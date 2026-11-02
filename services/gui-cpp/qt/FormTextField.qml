pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

NativeFormField {
    id: root

    required property var colors
    property string placeholderText: ""
    property string placeholderPrefix: ""
    readonly property var regions: layout
    readonly property real placeholderAlpha: 0.7
    readonly property real prefixPlaceholderAlpha: 0.55

    clip: true
    Accessible.role: Accessible.EditableText
    Accessible.name: placeholderText

    Rectangle {
        x: root.regions.selection.x
        y: root.regions.selection.y
        width: root.regions.selection.width
        height: root.regions.selection.height
        color: root.colors.surface1
    }

    CellText {
        x: root.regions.content.x
        y: root.regions.content.y
        width: root.regions.content.width
        height: root.regions.content.height
        text: root.regions.text ?? ""
        grid: root.regions.grid ?? ({})
        color: root.colors.text
        visible: root.regions.available && text.length > 0
    }

    ChromeText {
        x: root.regions.content.x
        y: root.regions.content.y
        width: root.regions.content.width
        height: root.regions.content.height
        text: root.placeholderText
        pixelSize: root.typography.body ?? 1
        color: Qt.alpha(root.colors.subtext0, root.placeholderAlpha)
        elide: Text.ElideNone
        visible: root.regions.available && root.regions.text === "" && !root.regions.composing
    }

    ChromeText {
        readonly property real prefixGap: 2 * (root.regions.grid?.cellWidth ?? 0)
        x: root.regions.content.x + prefixGap
        y: root.regions.content.y
        width: Math.max(0, root.regions.content.width - prefixGap)
        height: root.regions.content.height
        text: root.placeholderText
        pixelSize: root.typography.body ?? 1
        color: root.colors.text
        opacity: root.prefixPlaceholderAlpha
        elide: Text.ElideNone
        visible: root.regions.available && !root.regions.composing && root.placeholderPrefix.length > 0 && root.text === root.placeholderPrefix && root.regions.text === root.placeholderPrefix
    }

    Rectangle {
        x: root.regions.underline.x
        y: root.regions.underline.y
        width: root.regions.underline.width
        height: root.regions.underline.height
        color: root.colors.text
        visible: root.regions.composing
    }

    Rectangle {
        x: root.regions.caret.x
        y: root.regions.caret.y
        width: root.regions.caret.width
        height: root.regions.caret.height
        color: root.colors.text
        visible: root.formControl && root.activeFocus && root.regions.available
    }

    NativeRoundedRectangle {
        x: root.regions.caret.x
        y: root.regions.caret.y
        width: root.regions.caret.width
        height: root.regions.caret.height
        color: "transparent"
        borderColor: root.colors.accent
        borderWidth: 1 / Screen.devicePixelRatio
        radius: 0
        visible: !root.formControl && root.activeFocus && root.regions.available
    }
}
