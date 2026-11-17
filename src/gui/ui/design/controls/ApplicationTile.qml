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
    // The palette role of the agent's state, drawn as a dot on the card's corner.
    property string statusColor
    // The dot's opacity, which a working agent pulses, and the ring that cuts it from the surface below.
    property real statusOpacity: 1
    property color statusRing: colors.paneBackground ?? colors.panel_bg
    // Recedes the card and its mark; the state dot keeps its strength.
    property bool dimmed: false

    readonly property color ink: mark.ink ?? root.colors.text
    readonly property real strength: dimmed ? 0.5 : 1
    color: Qt.alpha(attentionColor.length > 0 ? root.colors[attentionColor] : (mark.tile ?? root.colors.surface1), strength)

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
        opacity: root.strength
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

    NativeRoundedRectangle {
        objectName: "applicationStatus"
        readonly property real side: 7 * root.ratio
        x: parent.width - side + 3 * root.ratio
        y: -3 * root.ratio
        width: side
        height: side
        radius: side / 2
        color: root.statusColor.length > 0 ? root.colors[root.statusColor] : "transparent"
        borderColor: root.statusRing
        borderWidth: 1.5 * root.ratio
        opacity: root.statusOpacity
        visible: root.statusColor.length > 0
    }
}
