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
    // The typed filters, each {label, applied}, shown before the query.
    property var chips: []
    readonly property real rowsOpacity: loading.rowsOpacity
    property alias fieldHost: fieldArea

    readonly property real leadingInset: 16 * ratio
    readonly property real iconWidth: 18 * ratio
    readonly property real fieldGap: 10 * ratio
    readonly property real trailingInset: 14 * ratio
    readonly property real closeWidth: Math.min(38 * ratio, width / 4)
    readonly property real closeHeight: Math.min(22 * ratio, height)
    readonly property real closeRingAlpha: 0.6
    readonly property real closeHoverRadius: 7 * ratio

    signal cancelled()
    signal chipRemoved(int index)

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

    // A filter the runtime does not apply yet shows struck through: it is kept, and filters nothing.
    Row {
        id: chipRow
        objectName: "historyChips"
        x: root.leadingInset + root.iconWidth + root.fieldGap
        height: parent.height
        spacing: 4 * root.ratio

        Repeater {
            model: root.chips
            delegate: Item {
                id: chip
                objectName: "historyChip"
                required property int index
                required property var modelData
                readonly property string label: modelData.label
                width: chipText.implicitWidth + 12 * root.ratio
                height: chipRow.height

                NativeRoundedRectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: Math.min(parent.height, 22 * root.ratio)
                    radius: 4 * root.ratio
                    color: chip.modelData.applied ? Qt.alpha(root.colors.accent, 0.18) : root.colors.surface0
                }

                ChromeText {
                    id: chipText
                    anchors.centerIn: parent
                    text: chip.modelData.label
                    color: chip.modelData.applied ? root.colors.text : root.colors.overlay1
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                }

                Rectangle {
                    anchors.verticalCenter: chipText.verticalCenter
                    x: chipText.x
                    width: chipText.width
                    height: Math.max(1, root.ratio)
                    color: root.colors.overlay1
                    visible: !chip.modelData.applied
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.chipRemoved(chip.index)
                }

                Accessible.role: Accessible.Button
                Accessible.name: (chip.modelData.applied ? "Remove filter " : "Remove filter, not applied by this runtime, ") + chip.modelData.label
            }
        }
    }

    Item {
        id: fieldArea
        objectName: "historySearchHost"
        x: root.leadingInset + root.iconWidth + root.fieldGap + (root.chips.length > 0 ? chipRow.width + root.fieldGap : 0)
        width: Math.max(0, close.x - root.fieldGap - x)
        height: parent.height
    }
}
