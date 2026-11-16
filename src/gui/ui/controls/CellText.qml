pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property string text
    required property var grid
    required property color color
    property bool bold: false

    implicitWidth: ink.implicitWidth
    implicitHeight: ink.implicitHeight

    NativeCellText {
        id: ink

        anchors.fill: parent
        text: root.text
        grid: root.grid
        color: root.color
        bold: root.bold
        visible: available
    }

    Loader {
        anchors.fill: parent
        active: !ink.available
        sourceComponent: Text {
            text: root.text
            color: root.color
            font.family: root.grid.family || "Telar Forma"
            font.styleName: root.grid.style ?? ""
            font.pixelSize: root.grid.pixelHeight
            font.bold: root.bold
            textFormat: Text.PlainText
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering
            clip: true
        }
    }

    Accessible.role: Accessible.StaticText
    Accessible.name: text
}
