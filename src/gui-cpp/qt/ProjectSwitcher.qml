pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

Item {
    id: root

    required property var model
    required property var colors
    required property var typography
    property real ratio: 1
    property int selectedIndex: -1
    readonly property real side: 28 * ratio
    readonly property real spacing: 4 * ratio
    readonly property real stride: side + spacing
    readonly property bool overflowing: preferredWidth > width
    readonly property int visibleCount: Math.max(0, Math.floor((width + spacing - (overflowing ? stride : 0)) / stride))
    readonly property real preferredWidth: Math.max(0, projects.count * stride - spacing)
    signal selected(string key)
    signal overflowRequested()

    implicitWidth: preferredWidth
    implicitHeight: side
    Accessible.role: Accessible.PageTabList
    Accessible.name: "Projects"

    ListView {
        id: projects
        objectName: "projectSwitcherList"
        width: Math.max(0, Math.min(count, root.visibleCount) * root.stride - root.spacing)
        height: root.side
        y: (root.height - height) / 2
        orientation: ListView.Horizontal
        spacing: root.spacing
        model: root.model
        currentIndex: root.selectedIndex
        interactive: false
        clip: true
        visible: width > 0
        highlightMoveDuration: 180
        highlightResizeDuration: 0
        highlightRangeMode: ListView.ApplyRange
        preferredHighlightBegin: 0
        preferredHighlightEnd: width
        highlight: NativeRoundedRectangle {
            objectName: "projectSelection"
            radius: ChromeStyle.controlRadius * root.ratio
            color: Qt.alpha(root.colors.text, ChromeStyle.selectionAlpha)
            borderColor: root.colors.text
            borderAlpha: ChromeStyle.outlineAlpha
            borderWidth: 1 / Screen.devicePixelRatio
        }

        delegate: ChromeButton {
            id: project
            objectName: "projectSwitcherMark"
            required property var record
            readonly property color hue: root.colors[record.markHue ?? "mauve"]
            width: root.side
            height: root.side
            colors: root.colors
            pixelSize: root.typography.body
            cornerRadius: ChromeStyle.controlRadius * root.ratio
            onClicked: root.selected(record.key)
            contentItem: ChromeText {
                text: project.record.initial || "?"
                pixelSize: root.typography.body
                color: project.hue
                emphasized: true
                opacity: project.record.selected || project.hovered || project.visualFocus ? 1 : 0.6
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideNone
            }

            NativeRoundedRectangle {
                objectName: "projectAttention"
                x: parent.width - width - 2 * root.ratio
                y: 2 * root.ratio
                width: 4 * root.ratio
                height: width
                radius: width / 2
                color: root.colors[project.record.attentionColor ?? "yellow"]
                visible: (project.record.attention ?? "").length > 0
            }

            ToolTip {
                id: tip
                visible: project.hovered
                delay: 500
                text: project.record.name + "\n" + (project.record.path ?? "")
                contentItem: Text {
                    text: tip.text
                    textFormat: Text.PlainText
                    color: root.colors.text
                    font.pixelSize: root.typography.small
                }
                background: NativeRoundedRectangle {
                    radius: ChromeStyle.controlRadius * root.ratio
                    color: root.colors.panel_bg
                    borderColor: root.colors.text
                    borderAlpha: ChromeStyle.outlineAlpha
                    borderWidth: 1 / Screen.devicePixelRatio
                }
            }

            Accessible.role: Accessible.PageTab
            Accessible.name: record.name + " " + (record.path ?? "")
            Accessible.selected: record.selected
        }
    }

    ChromeButton {
        objectName: "projectSwitcherOverflow"
        anchors.right: parent.right
        y: (root.height - height) / 2
        width: Math.min(root.side, root.width)
        height: root.side
        visible: root.overflowing && width > 0
        colors: root.colors
        pixelSize: root.typography.small
        cornerRadius: ChromeStyle.controlRadius * root.ratio
        text: "+" + Math.max(0, projects.count - root.visibleCount)
        Accessible.name: "Show all projects"
        onClicked: root.overflowRequested()
    }
}
