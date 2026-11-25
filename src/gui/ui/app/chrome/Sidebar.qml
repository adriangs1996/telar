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
        readonly property real lineHeight: Math.round(16 * root.unit)
        x: root.regions.activity.x
        y: root.regions.activity.y + root.regions.activity.height - height
        width: root.regions.activity.width
        height: visible ? headerHeight + transferCards.height + root.headerInset : 0
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

        // A card for each, as the design draws them: where it goes, its name, how much of it
        // arrived, and while it is on its way what stops it.
        Column {
            id: transferCards
            x: root.headerInset
            y: transfersPart.headerHeight
            width: Math.max(0, parent.width - 2 * root.headerInset)
            spacing: Math.round(6 * root.unit)

            Repeater {
                model: root.transfers

                delegate: NativeRoundedRectangle {
                    id: transfer
                    required property var modelData
                    required property int index
                    readonly property bool running: !(modelData.ended ?? false)
                    readonly property bool arrived: !running && (modelData.phase ?? "") === "arrived"
                    readonly property real pad: Math.round(8 * root.unit)
                    objectName: "sidebarTransfer"
                    width: transferCards.width
                    height: transferLines.height + 2 * Math.round(7 * root.unit)
                    radius: 6 * root.unit
                    color: root.colors.surface_dim
                    borderWidth: Math.max(1 / Screen.devicePixelRatio, Math.round(root.unit))
                    borderColor: running ? root.colors.blue : root.colors.surface1
                    borderAlpha: 1

                    Column {
                        id: transferLines
                        x: transfer.pad
                        y: Math.round(7 * root.unit)
                        width: parent.width - 2 * transfer.pad
                        spacing: Math.round(4 * root.unit)

                        // From where to where.
                        ChromeText {
                            width: parent.width
                            height: transfersPart.lineHeight
                            text: transfer.modelData.route ?? ""
                            color: root.colors.subtext0
                            pixelSize: root.typography.small
                        }

                        ChromeText {
                            width: parent.width
                            height: transfersPart.lineHeight
                            text: transfer.modelData.name ?? ""
                            color: (transfer.modelData.failed ?? false) ? root.colors.red : root.colors.text
                            pixelSize: root.typography.small
                        }

                        Rectangle {
                            width: parent.width
                            height: Math.max(1, Math.round(4 * root.unit))
                            radius: height / 2
                            color: root.colors.surface0

                            Rectangle {
                                width: Math.round(parent.width * (transfer.arrived ? 1 : transfer.running ? Math.min(1, transfer.modelData.share ?? 0) : 0))
                                height: parent.height
                                radius: parent.radius
                                color: transfer.arrived ? root.colors.green : root.colors.blue
                            }
                        }

                        // How much of it arrived and how fast, or how it ended.
                        ChromeText {
                            width: parent.width
                            height: transfersPart.lineHeight
                            text: transfer.running ? (transfer.modelData.progress ?? "") + ((transfer.modelData.rate ?? "").length > 0 ? " · " + transfer.modelData.rate : "") : (transfer.modelData.phase ?? "")
                            color: root.colors.subtext0
                            pixelSize: root.typography.small
                        }

                        AbstractButton {
                            id: cancel
                            objectName: "sidebarTransferCancel"
                            width: cancelLabel.implicitWidth + Math.round(14 * root.unit)
                            height: transfersPart.lineHeight
                            visible: transfer.running
                            hoverEnabled: true
                            focusPolicy: Qt.TabFocus
                            padding: 0
                            Accessible.role: Accessible.Button
                            Accessible.name: "Cancel the transfer of " + (transfer.modelData.name ?? "")
                            onClicked: root.transferCancelled(transfer.modelData.id)
                            background: NativeRoundedRectangle {
                                radius: 4 * root.unit
                                color: "transparent"
                                borderWidth: Math.max(1 / Screen.devicePixelRatio, Math.round(root.unit))
                                borderColor: cancel.hovered ? root.colors.red : root.colors.surface1
                                borderAlpha: 1
                            }
                            contentItem: ChromeText {
                                id: cancelLabel
                                text: "cancel"
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
