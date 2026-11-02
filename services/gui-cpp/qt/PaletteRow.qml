pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root
    objectName: "paletteRow"

    required property var record
    required property var colors
    required property var typography
    required property string revision
    property real ratio: 1
    property bool selected: false
    signal activated(string key, string revision)

    readonly property real horizontalInset: Math.min(10 * ratio, width / 8)
    readonly property real iconSide: Math.min(20 * ratio, width - horizontalInset * 2)
    readonly property real iconGap: 10 * ratio
    readonly property real hintGap: 12 * ratio
    readonly property real shortcutPadding: 10 * ratio
    readonly property real hintShare: 0.45
    readonly property real cornerRadius: 6 * ratio
    readonly property real selectionAlpha: 0.08
    readonly property real outlineAlpha: 0.2
    readonly property real detailAlpha: 0.65
    readonly property bool hasIcon: record.icon.length > 0
    readonly property real iconWidth: hasIcon ? Math.min(Math.max(0, width - horizontalInset * 2), iconSide + iconGap) : 0
    readonly property real bodyLeft: horizontalInset + iconWidth
    readonly property real bodyWidth: Math.max(0, width - horizontalInset * 2 - iconWidth)
    readonly property string hint: record.hint.length > 0 ? record.hint : record.detailBelow ? "" : record.secondary
    readonly property real hintWidth: hint.length > 0 ? Math.min(hintLabel.implicitWidth + (record.shortcut ? shortcutPadding : 0), bodyWidth * hintShare) : 0
    readonly property real labelWidth: Math.max(0, bodyWidth - hintWidth - (hint.length > 0 ? hintGap : 0))
    readonly property bool stacked: record.detailBelow && record.secondary.length > 0
    readonly property real upperTop: stacked ? Math.max(0, (height - typography.bodyRow - typography.smallRow) / 2) : 0
    readonly property real upperHeight: stacked ? Math.min(height, typography.bodyRow) : height

    clip: true
    Accessible.role: Accessible.ListItem
    Accessible.name: record.primary
    Accessible.description: record.secondary
    Accessible.selected: selected

    NativeRoundedRectangle {
        anchors.fill: parent
        radius: root.cornerRadius
        color: root.colors.surface0
        visible: root.selected
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        radius: root.cornerRadius
        color: Qt.alpha(root.colors.accent, root.selectionAlpha)
        visible: root.selected
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        radius: root.cornerRadius
        color: "transparent"
        borderWidth: root.ratio
        borderColor: Qt.alpha(root.colors.accent, root.outlineAlpha)
        visible: root.selected
    }

    ChromeIcon {
        x: root.horizontalInset
        y: (root.height - height) / 2
        width: root.iconSide
        height: Math.min(width, root.height)
        glyph: root.record.icon
        color: Qt.alpha(root.colors.text, root.detailAlpha)
        pixelSize: root.typography.body
        visible: root.hasIcon
    }

    ChromeText {
        x: root.bodyLeft
        y: root.upperTop
        width: root.labelWidth
        height: root.upperHeight
        text: root.record.primary
        pixelSize: root.typography.body
        color: root.colors.text
    }

    Loader {
        x: root.bodyLeft
        y: root.upperTop + root.upperHeight
        width: root.labelWidth
        height: Math.min(root.typography.smallRow, Math.max(0, root.height - y))
        active: root.stacked
        sourceComponent: ChromeText {
            anchors.fill: parent
            text: root.record.secondary
            pixelSize: root.typography.small
            color: Qt.alpha(root.colors.text, root.detailAlpha)
        }
    }

    ChromeText {
        id: hintLabel
        x: root.bodyLeft + root.bodyWidth - root.hintWidth
        width: root.hintWidth
        height: root.height
        text: root.hint
        pixelSize: root.typography.small
        color: root.colors.text
        opacity: root.detailAlpha
        visible: !root.record.shortcut
    }

    PaletteKeycap {
        x: hintLabel.x
        width: root.hintWidth
        height: root.height
        text: root.hint
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        visible: root.hint.length > 0 && root.record.shortcut
    }

    ActionPointer {
        anchors.fill: parent
        identity: root.revision + ":" + root.record.key
        onActivated: root.activated(root.record.key, root.revision)
    }
}
