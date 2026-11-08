pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var colors
    required property var typography
    property real ratio: 1
    property real density: 1
    property bool inspecting: false
    property bool replacing: false
    readonly property real rowsOpacity: loading.rowsOpacity
    property alias fieldHost: fieldArea

    readonly property real leadingInset: 16 * ratio
    readonly property real iconWidth: 18 * ratio
    readonly property real fieldGap: 10 * ratio
    readonly property real trailingInset: 14 * ratio
    readonly property real closeWidth: Math.min(38 * ratio, width / 4)
    readonly property real closeHeight: Math.min(22 * ratio, height)
    readonly property real fieldPadding: Math.min(12 * ratio, fieldArea.width / 4)
    readonly property real closeRingAlpha: 0.6
    readonly property real closeHoverRadius: 7 * ratio

    signal cancelled()

    Rectangle {
        width: parent.width
        height: 1 / root.density
        color: root.colors.surface1
    }

    HistoryLoadingLayout {
        id: loading
        objectName: "historyLoading"
        anchors.fill: parent
        waiting: root.replacing
        ratio: root.ratio
        clip: true

        Rectangle {
            objectName: "historyLoadingLine"
            x: loading.line.x
            y: loading.line.y
            width: loading.line.width
            height: loading.line.height
            visible: loading.cueVisible
            color: root.colors.accent
        }
    }

    ChromeIcon {
        x: root.leadingInset
        width: root.iconWidth
        height: parent.height
        glyph: "\uf002"
        pixelSize: root.typography.body
        color: root.colors.subtext0
        primaryFamily: root.typography.primaryFamily
        primaryStyle: root.typography.primaryStyle
    }

    ChromeButton {
        id: close
        objectName: "historyClose"
        x: root.width - root.trailingInset - width
        y: Math.floor((root.height - height) / 2 * root.density) / root.density
        width: root.closeWidth
        height: root.closeHeight
        text: "esc"
        colors: root.colors
        pixelSize: root.typography.body
        cornerRadius: 4 * root.ratio
        focusPolicy: Qt.NoFocus
        Accessible.name: root.inspecting ? "Back to history" : "Close history"
        contentItem: ChromeText {
            text: close.text
            color: root.colors.text
            pixelSize: close.pixelSize
            horizontalAlignment: Text.AlignHCenter
        }
        background: Item {
            NativeRoundedRectangle {
                anchors.fill: parent
                color: close.hovered || close.down ? root.colors.surface1 : "transparent"
                radius: root.closeHoverRadius
            }

            NativeRoundedRectangle {
                anchors.fill: parent
                color: "transparent"
                radius: close.cornerRadius
                borderWidth: root.ratio
                borderColor: Qt.alpha(root.colors.overlay0, root.closeRingAlpha)
            }
        }
        onClicked: root.cancelled()
    }

    Item {
        id: fieldArea
        objectName: "historySearchHost"
        x: root.leadingInset + root.iconWidth + root.fieldGap
        width: Math.max(0, close.x - root.fieldGap - x)
        height: parent.height
    }
}
