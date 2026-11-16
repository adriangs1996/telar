pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

Item {
    id: root

    required property var record
    required property var colors
    required property var typography
    property var samples: []
    property bool battery: false
    property real ratio: 1

    readonly property real partGap: 5 * ratio
    readonly property real density: Screen.devicePixelRatio
    readonly property real iconSizeRatio: 0.85
    readonly property real iconSide: Math.round(typography.small * density * iconSizeRatio) / density
    readonly property real markWidth: battery ? batteryShape.implicitWidth : iconSide
    readonly property real sparkWidth: samples.length > 0 ? spark.implicitWidth + partGap : 0
    readonly property color ink: colors[record.ink]
    readonly property color mark: colors[record.mark]

    implicitWidth: record.available ? markWidth + partGap + sparkWidth + value.implicitWidth : 0

    ChromeIcon {
        width: root.iconSide
        height: parent.height
        glyph: root.record.glyph
        color: root.colors.subtext0
        pixelSize: root.typography.small
        primaryFamily: root.typography.primaryFamily ?? ""
        primaryStyle: root.typography.primaryStyle ?? ""
        visible: !root.battery && root.record.available
    }

    BarBattery {
        id: batteryShape

        width: implicitWidth
        height: parent.height
        ratio: root.ratio
        percent: root.record.percent
        outlineColor: root.mark
        fillColor: root.ink
        visible: root.battery && root.record.available
    }

    BarSparkline {
        id: spark

        x: root.markWidth + root.partGap
        width: implicitWidth
        height: parent.height
        ratio: root.ratio
        samples: root.samples
        color: root.mark
        trackColor: root.colors.surface1
    }

    ChromeText {
        id: value
        objectName: "barMetricValue"

        x: root.markWidth + root.partGap + root.sparkWidth
        width: implicitWidth
        height: parent.height
        text: root.record.text
        color: root.record.ink === "text" ? root.colors.chromeText : root.ink
        pixelSize: root.typography.small
        elide: Text.ElideNone
    }

    Accessible.role: Accessible.StaticText
    Accessible.name: record.text
}
