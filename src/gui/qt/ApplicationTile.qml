import QtQuick
import Telar.Gui

// An application's colored card: its mark, or its number while prefix input is pending.
NativeRoundedRectangle {
    id: root

    required property var mark
    required property var colors
    required property var typography
    property real ratio: 1
    property string number
    property string attentionColor

    readonly property color ink: mark.ink ?? root.colors.text
    color: attentionColor.length > 0 ? root.colors[attentionColor] : (mark.tile ?? root.colors.surface1)

    ApplicationMark {
        readonly property real side: Math.round(Math.min(parent.width, parent.height) * 0.72)
        anchors.centerIn: parent
        width: side
        height: side
        mark: root.mark
        colors: root.colors
        ink: root.ink
        monochrome: true
        ratio: root.ratio
        pixelSize: side
        primaryFamily: root.typography.primaryFamily ?? ""
        primaryStyle: root.typography.primaryStyle ?? ""
        visible: root.number.length === 0
    }

    ChromeText {
        objectName: "applicationNumber"
        anchors.fill: parent
        text: root.number
        pixelSize: Math.round(parent.height * 0.7)
        color: root.ink
        emphasized: true
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideNone
        visible: root.number.length > 0
    }
}
