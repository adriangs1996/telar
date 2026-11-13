pragma ComponentBehavior: Bound

import QtQuick

Item {
    id: root
    objectName: "runtimeLinkStatus"

    required property var controller
    readonly property var state: controller.runtimeLinkState
    readonly property var regions: controller.runtimeLinkGeometry
    readonly property var typography: controller.windowGeometry.typography
    readonly property var colors: controller.colors

    x: regions.bounds.x
    y: regions.bounds.y
    width: regions.bounds.width
    height: regions.bounds.height
    visible: state.visible && width > 0 && height > 0

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(root.colors.background.r, root.colors.background.g, root.colors.background.b, 1)
        opacity: root.state.dimAlpha
    }

    ChromeText {
        objectName: "runtimeLinkHeadline"
        x: root.regions.headline.x + (root.regions.headline.width - width) / 2
        y: root.regions.headline.y
        width: Math.min(implicitWidth, root.regions.headline.width)
        height: root.regions.headline.height
        pixelSize: root.typography.title
        emphasized: true
        text: root.state.headline
        color: root.colors.text
        elide: Text.ElideNone
    }

    ChromeText {
        objectName: "runtimeLinkDetail"
        x: root.regions.detail.x + (root.regions.detail.width - width) / 2
        y: root.regions.detail.y
        width: Math.min(implicitWidth, root.regions.detail.width)
        height: root.regions.detail.height
        visible: root.state.hasDetail
        pixelSize: root.typography.body
        text: root.state.detail
        color: root.colors.subtext0
        elide: Text.ElideNone
    }
}
