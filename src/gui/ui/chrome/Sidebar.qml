import QtQuick
import QtQuick.Controls
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

    // One design pixel beside the chrome text, which the cards and rows are sized in.
    readonly property real unit: regions.cards?.ratio ?? ratio
    readonly property real headerInset: regions.cards?.padding ?? 8 * unit
    readonly property real markColumn: regions.cards?.markColumn ?? 24 * unit
    readonly property real textInset: regions.cards?.textInset ?? 38 * unit
    readonly property real iconSide: Math.round(14 * unit)
    readonly property real sectionGap: regions.sectionGap ?? 0
    readonly property real resizeWidth: 6 * ratio

    color: colors.sidebarBackground
    replaceBackground: true
    clip: true

    // The machines other than the active one; the top bar names the active one.
    AbstractButton {
        id: machinesHeader
        objectName: "sidebarMachinesHeader"
        readonly property bool collapsed: root.controller?.sidebar?.machineListCollapsed ?? false
        readonly property bool attention: root.controller?.machineContext?.attention ?? false
        x: root.regions.machinesHeader?.x ?? 0
        y: root.regions.machinesHeader?.y ?? 0
        width: root.regions.machinesHeader?.width ?? 0
        height: root.regions.machinesHeader?.height ?? 0
        visible: root.expanded && height > 0
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        padding: 0
        contentItem: null
        background: null
        Accessible.role: Accessible.Button
        Accessible.name: "Machines, " + machineCount.text + (collapsed ? ", collapsed" : ", expanded") + (collapsed && attention ? ", one needs attention" : "")
        onClicked: {
            if (root.controller) root.controller.sidebar.toggleMachineList();
        }

        HoverHandler { cursorShape: Qt.PointingHandCursor }

        ProviderMark {
            objectName: "machinesIcon"
            x: root.headerInset + (root.markColumn - width) / 2
            y: (parent.height - height) / 2
            width: root.iconSide
            height: root.iconSide
            symbol: "server"
            color: root.colors.subtext0
        }

        ChromeText {
            id: machinesTitle
            x: root.textInset
            width: implicitWidth
            height: parent.height
            text: "MACHINES"
            color: root.colors.text
            pixelSize: root.typography.small
            emphasized: true
            elide: Text.ElideNone
        }

        // The chevron follows the label, so the count keeps the column the cards' ages use.
        ProviderMark {
            id: chevron
            objectName: "machinesChevron"
            x: machinesTitle.x + machinesTitle.width + 4 * root.unit
            y: (parent.height - height) / 2
            width: Math.round(12 * root.unit)
            height: width
            symbol: machinesHeader.collapsed ? "chevron-right" : "chevron-down"
            color: root.colors.subtext0
        }

        NativeRoundedRectangle {
            objectName: "machinesAttention"
            x: chevron.x + chevron.width + 6 * root.unit
            y: (parent.height - height) / 2
            width: 6 * root.unit
            height: width
            radius: width / 2
            color: root.colors.yellow
            visible: machinesHeader.collapsed && machinesHeader.attention
        }

        ChromeText {
            id: machineCount
            x: parent.width - width - root.headerInset
            width: implicitWidth
            height: parent.height
            text: Math.max(0, (root.controller?.sidebar?.machineCount ?? 1) - 1)
            color: root.colors.subtext0
            pixelSize: root.typography.small
            elide: Text.ElideNone
        }
    }

    MachineChrome {
        objectName: "sidebarMachineList"
        controller: root.controller?.machineChrome ?? null
        segment: false
        x: root.regions.machines?.x ?? 0
        y: root.regions.machines?.y ?? 0
        width: root.regions.machines?.width ?? 0
        height: root.regions.machines?.height ?? 0
        colors: root.colors
        typography: root.typography
        visible: root.expanded && shown && height > 0
    }

    // The line between the machines and the agents, in the middle of the gap that parts them.
    Rectangle {
        objectName: "sidebarSectionSeparator"
        x: root.regions.activityHeader.x + root.headerInset
        y: Math.round(root.regions.activityHeader.y - root.sectionGap / 2)
        width: Math.max(0, root.regions.activityHeader.width - 2 * root.headerInset)
        height: 1 / Screen.devicePixelRatio
        color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
        visible: machinesHeader.visible && root.sectionGap > 0
    }

    Item {
        x: root.regions.activityHeader.x
        y: root.regions.activityHeader.y
        width: root.regions.activityHeader.width
        height: root.regions.activityHeader.height
        visible: root.expanded && height > 0

        ProviderMark {
            objectName: "activityIcon"
            x: root.headerInset + (root.markColumn - width) / 2
            y: (parent.height - height) / 2
            width: root.iconSide
            height: root.iconSide
            symbol: "bot"
            color: root.colors.subtext0
        }

        ChromeText {
            id: activityTitle
            x: root.textInset
            width: Math.max(0, parent.width - x - root.headerInset)
            height: parent.height
            text: "AGENTS"
            color: root.colors.text
            pixelSize: root.typography.small
            emphasized: true
        }

        ChromeText {
            objectName: "activityCount"
            x: parent.width - width - root.headerInset
            width: implicitWidth
            height: parent.height
            text: root.controller?.activity?.agentCount ?? activityList.count
            color: root.colors.subtext0
            pixelSize: root.typography.small
            elide: Text.ElideNone
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
        hoverIdentity: root.controller?.activity?.hovered ?? ""
        semanticHover: typeof root.controller?.activity?.hover === "function"
        colors: root.colors
        typography: root.typography
        geometry: root.regions.cards
        headerHeight: root.regions.activityHeader.height
        sectionGap: root.sectionGap
        ratio: root.unit
        textScale: root.textScale
        visible: root.expanded
        onSelected: key => root.agentSelected(key)
        onPeekRequested: key => root.agentPeekRequested(key)
        onElementActivated: (slot, key, revision, element) => root.controller?.activateElement(slot, key, revision, element)
        onHovered: (key, card) => {
            if (activityList.semanticHover) {
                root.controller.activity.hover(key, card);
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
        onDoubleClicked: {
            if (root.controller) root.controller.sidebar.fit();
        }
    }
}
