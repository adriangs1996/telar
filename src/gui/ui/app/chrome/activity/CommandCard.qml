pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

ActivityFrame {
    id: root

    required property var typography

    ChromeText {
        objectName: "commandFacts"
        x: root.geometry.textInset
        y: root.geometry.context.y
        width: Math.max(0, root.width - x - root.geometry.context.x)
        height: root.geometry.context.height
        text: root.record.facts
        color: root.colors.subtext0
        pixelSize: root.typography.small
    }

    ChromeText {
        objectName: "commandTitle"
        x: root.geometry.textInset
        y: root.geometry.title.y
        width: Math.max(0, root.width - x - root.geometry.title.x)
        height: root.geometry.title.height
        text: root.record.title
        color: root.colors.text
        pixelSize: root.typography.title
    }

    ChromeText {
        objectName: "commandLabel"
        x: root.geometry.textInset
        y: root.geometry.detail.y
        width: Math.max(0, root.width - x - root.geometry.detail.x)
        height: root.geometry.detail.height
        text: root.record.detail
        color: root.colors.subtext0
        pixelSize: root.typography.small
    }

    Accessible.name: record.facts + " " + record.title + " " + record.detail
}
