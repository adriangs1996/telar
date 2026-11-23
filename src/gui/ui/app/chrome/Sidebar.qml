import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

NativeRoundedRectangle {
    id: root

    required property var colors
    required property var typography
    required property var regions
    required property var agentModel
    required property real preferredWidth
    property SidebarController controller: null
    property ActivityController activity: null
    // The machine list's controller, and the active machine: its label, and whether one needs
    // attention.
    property MachineChromeController machineChrome: null
    property var machineContext: ({})
    property real ratio: 1
    property real textScale: 1
    property bool expanded: true
    // The files on their way between two machines: each with its name, its route, how much of
    // it arrived and how fast.
    property var transfers: []
    signal transferCancelled(int id)
    signal agentSelected(string key)
    signal agentPeekRequested(string key)
    signal sidebarResized(real requestedWidth)
    // A click on an element a mod drew in an agent card.
    signal elementActivated(string slot, string key, string revision, int element)

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
        readonly property bool collapsed: root.controller?.machineListCollapsed ?? false
        readonly property bool attention: root.machineContext.attention ?? false
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
            if (root.controller) root.controller.toggleMachineList();
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
            text: Math.max(0, (root.controller?.machineCount ?? 1) - 1)
            color: root.colors.subtext0
            pixelSize: root.typography.small
            elide: Text.ElideNone
        }
    }

    MachineChrome {
        objectName: "sidebarMachineList"
        controller: root.machineChrome
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
            text: root.activity?.agentCount ?? activityList.count
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
        // The transfers stand under the agents while there are some.
        height: Math.max(0, root.regions.activity.height - transfersPart.height)
        model: root.expanded ? root.agentModel : null
        hoverIdentity: root.activity?.hovered ?? ""
        semanticHover: typeof root.activity?.hover === "function"
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
        onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
        onHovered: (key, card) => {
            if (activityList.semanticHover) {
                root.activity.hover(key, card);
            }
        }
    }

    Item {
        id: transfersPart
        objectName: "sidebarTransfers"
        readonly property real headerHeight: root.regions.activityHeader.height
        readonly property real rowHeight: Math.round(38 * root.unit)
        x: root.regions.activity.x
        y: root.regions.activity.y + root.regions.activity.height - height
        width: root.regions.activity.width
        height: visible ? headerHeight + root.transfers.length * rowHeight + root.headerInset : 0
        visible: root.expanded && root.transfers.length > 0

        Rectangle {
            x: root.headerInset
            width: Math.max(0, parent.width - 2 * root.headerInset)
            height: 1 / Screen.devicePixelRatio
            color: Qt.alpha(root.colors.text, ChromeStyle.outlineAlpha)
        }

        ChromeText {
            x: root.textInset
            width: Math.max(0, parent.width - x - root.headerInset)
            height: transfersPart.headerHeight
            text: "TRANSFERS"
            color: root.colors.text
            pixelSize: root.typography.small
            emphasized: true
        }

        ChromeText {
            objectName: "transferCount"
            x: parent.width - width - root.headerInset
            width: implicitWidth
            height: transfersPart.headerHeight
            text: root.transfers.length + ((root.transfers[root.transfers.length - 1]?.more ?? 0) > 0 ? "+" : "")
            color: root.colors.subtext0
            pixelSize: root.typography.small
            elide: Text.ElideNone
        }

        Repeater {
            model: root.transfers

            Item {
                id: transfer
                required property var modelData
                required property int index
                readonly property bool running: !(modelData.ended ?? false)
                objectName: "sidebarTransfer"
                y: transfersPart.headerHeight + index * transfersPart.rowHeight
                width: transfersPart.width
                height: transfersPart.rowHeight

                ChromeText {
                    id: transferName
                    x: root.textInset
                    width: Math.max(0, cancel.x - x - 4 * root.unit)
                    height: Math.round(parent.height * 0.42)
                    text: transfer.modelData.name ?? ""
                    color: (transfer.modelData.failed ?? false) ? root.colors.red : root.colors.text
                    pixelSize: root.typography.small
                }

                // From where to where, and how much of it arrived, or how it ended.
                ChromeText {
                    x: root.textInset
                    y: transferName.height
                    width: Math.max(0, parent.width - x - root.headerInset)
                    height: transferName.height
                    text: (transfer.modelData.route ?? "") + " · " + (transfer.running ? (transfer.modelData.progress ?? "") + ((transfer.modelData.rate ?? "").length > 0 ? " · " + transfer.modelData.rate : "") : (transfer.modelData.phase ?? ""))
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                }

                Rectangle {
                    x: root.textInset
                    y: 2 * transferName.height + Math.round(1 * root.unit)
                    width: Math.max(0, parent.width - x - root.headerInset)
                    height: Math.max(1, Math.round(2 * root.unit))
                    radius: height / 2
                    color: root.colors.surface0
                    visible: transfer.running

                    Rectangle {
                        width: Math.round(parent.width * Math.min(1, transfer.modelData.share ?? 0))
                        height: parent.height
                        radius: parent.radius
                        color: root.colors.accent
                    }
                }

                AbstractButton {
                    id: cancel
                    objectName: "sidebarTransferCancel"
                    x: parent.width - width - root.headerInset
                    width: Math.round(16 * root.unit)
                    height: transferName.height
                    visible: transfer.running
                    hoverEnabled: true
                    focusPolicy: Qt.TabFocus
                    padding: 0
                    background: null
                    Accessible.role: Accessible.Button
                    Accessible.name: "Cancel the transfer of " + (transfer.modelData.name ?? "")
                    onClicked: root.transferCancelled(transfer.modelData.id)
                    contentItem: ChromeText {
                        text: "×"
                        color: cancel.hovered ? root.colors.red : root.colors.subtext0
                        pixelSize: root.typography.small
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideNone
                    }

                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
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
            if (root.controller) root.controller.fit();
        }
    }
}
