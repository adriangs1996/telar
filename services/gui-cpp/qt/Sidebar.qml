import QtQuick
import Telar.Gui

NativeRoundedRectangle {
    id: root

    required property var colors
    required property var typography
    required property var regions
    required property var agentModel
    required property real preferredWidth
    property var controller: null
    property real ratio: 1
    property real textScale: 1
    property bool expanded: true
    signal agentSelected(string key)
    signal agentPeekRequested(string key)
    signal sidebarResized(real requestedWidth)

    readonly property real headerInset: 8 * ratio
    readonly property real resizeWidth: 6 * ratio
    readonly property real edgeWidth: regions.edgeWidth

    color: colors.sidebarBackground
    replaceBackground: true
    clip: true

    MachineChrome {
        objectName: "sidebarMachineSwitcher"
        controller: root.controller
        segment: false
        x: root.regions.machines?.x ?? 0
        y: root.regions.machines?.y ?? 0
        width: root.regions.machines?.width ?? 0
        height: root.regions.machines?.height ?? 0
        colors: root.colors
        visible: root.expanded && shown
    }

    Item {
        x: root.regions.activityHeader.x
        y: root.regions.activityHeader.y
        width: root.regions.activityHeader.width
        height: root.regions.activityHeader.height
        visible: root.expanded && height > 0

        ChromeText {
            id: activityTitle
            x: root.headerInset
            width: Math.max(0, parent.width - x - root.headerInset)
            height: parent.height
            text: "Activity"
            color: root.colors.chromeText
            pixelSize: root.typography.body + root.ratio
            emphasized: true
        }

    }

    ActivityList {
        id: activityList
        objectName: "sidebarActivity"
        x: root.regions.activity.x
        y: root.regions.activity.y
        width: root.regions.activity.width
        height: root.regions.activity.height
        model: root.expanded ? root.agentModel : null
        hoverIdentity: root.controller?.activityHover ?? ""
        semanticHover: typeof root.controller?.hoverActivity === "function"
        colors: root.colors
        typography: root.typography
        geometry: root.regions.cards
        ratio: root.ratio
        textScale: root.textScale
        visible: root.expanded
        onSelected: key => root.agentSelected(key)
        onPeekRequested: key => root.agentPeekRequested(key)
        onHovered: (key, card) => {
            if (activityList.semanticHover) {
                root.controller.hoverActivity(key, card);
            }
        }
    }

    MouseArea {
        anchors.right: parent.right
        width: root.resizeWidth
        height: parent.height
        enabled: root.expanded
        cursorShape: Qt.SplitHCursor
        property real startX: 0
        property real startWidth: 0
        onPressed: mouse => {
            startX = mapToGlobal(mouse.x, mouse.y).x;
            startWidth = root.preferredWidth;
        }
        onPositionChanged: mouse => {
            if (pressed) {
                root.sidebarResized(startWidth + mapToGlobal(mouse.x, mouse.y).x - startX);
            }
        }
    }
}
