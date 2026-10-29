import QtQuick
import Telar.Gui

Rectangle {
    id: root

    required property var colors
    required property var typography
    required property var regions
    required property var workspaceModel
    required property var agentModel
    required property real preferredWidth
    property var controller: null
    property real ratio: 1
    property real textScale: 1
    property bool expanded: true
    signal workspaceSelected(string key)
    signal agentSelected(string key)
    signal sidebarResized(real requestedWidth)

    readonly property real headerInset: 8 * ratio
    readonly property real separatorGap: 10 * ratio
    readonly property real resizeWidth: 6 * ratio
    readonly property real edgeWidth: regions.edgeWidth

    color: colors.panelBackground
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

    ChromeText {
        x: root.regions.projectsHeader.x + root.headerInset
        y: root.regions.projectsHeader.y
        width: Math.max(0, root.regions.projectsHeader.width - 2 * root.headerInset)
        height: root.regions.projectsHeader.height
        text: "projects"
        color: root.colors.text
        pixelSize: root.typography.body
        emphasized: true
        visible: root.expanded && height > 0
    }

    WorkspaceList {
        objectName: "workspaceList"
        x: root.regions.projects.x
        y: root.regions.projects.y
        width: root.regions.projects.width
        height: root.regions.projects.height
        model: root.expanded ? root.workspaceModel : null
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        rowHeight: root.regions.workspaceHeight
        visible: root.expanded
        onSelected: key => root.workspaceSelected(key)
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
            text: "activity"
            color: root.colors.text
            pixelSize: root.typography.body
            emphasized: true
        }

        Rectangle {
            x: Math.min(parent.width, activityTitle.x + activityTitle.implicitWidth + root.separatorGap)
            y: root.regions.activitySeparatorY
            width: Math.max(0, parent.width - root.headerInset - x)
            height: root.edgeWidth
            color: root.colors.surface1
        }
    }

    ActivityList {
        x: root.regions.activity.x
        y: root.regions.activity.y
        width: root.regions.activity.width
        height: root.regions.activity.height
        model: root.expanded ? root.agentModel : null
        colors: root.colors
        typography: root.typography
        geometry: root.regions.cards
        ratio: root.ratio
        textScale: root.textScale
        visible: root.expanded
        onSelected: key => root.agentSelected(key)
    }

    WorkspaceRail {
        anchors.fill: parent
        geometry: root.expanded ? ({}) : (root.regions.rail ?? {})
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        visible: !root.expanded
        onSelected: key => root.workspaceSelected(key)
    }

    Rectangle {
        anchors.right: parent.right
        height: parent.height
        width: root.edgeWidth
        color: root.colors.surface1
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
