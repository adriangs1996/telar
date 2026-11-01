pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

Item {
    id: root

    required property var controller
    required property var surface
    required property var node
    required property var colors
    required property var typography
    property real ratio: 1
    property real rowHeight: 28 * ratio
    property bool compact: false
    readonly property real gap: 6 * ratio
    readonly property real iconSide: 16 * ratio
    readonly property real trackWidth: 48 * ratio
    readonly property bool block: ["heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"].indexOf(node.kind) >= 0
    readonly property bool hasIcon: node.glyph.length > 0 || node.providerMark !== 0 || node.telarMark
    readonly property bool hasTooltip: (surface.nodes ?? []).some(child => child.parent === node.index && child.tooltip)
    readonly property real compactWidthDelta: node.kind === "meter" ? trackWidth + gap : 0
    readonly property real unreducedWidth: implicitWidth + (compact ? compactWidthDelta : 0)

    implicitWidth: visual.item?.implicitWidth ?? 0
    implicitHeight: visual.item?.implicitHeight ?? rowHeight
    opacity: node.faint ? 0.6 : 1

    function activate() {
        controller.activateComponent(surface.source, node.index, surface.generation, surface.revision, mapToItem(null, width / 2, 0));
    }

    Accessible.role: node.clickable ? Accessible.Button : Accessible.StaticText
    Accessible.name: node.text
    Accessible.onPressAction: if (node.clickable) activate()

    Loader {
        id: visual
        width: root.width
        height: root.height
        sourceComponent: {
            switch (root.node.kind) {
            case "group": return group;
            case "icon": case "mark": return icon;
            case "meter": case "meter_row": return meter;
            case "sparkline": return sparkline;
            case "metric": return metric;
            case "machines": return machines;
            case "kv": return keyValue;
            case "callout": return callout;
            case "actions": return actions;
            case "button": return button;
            case "divider": return divider;
            default: return label;
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.node.clickable && root.node.kind !== "button"
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activate()
    }

    HoverHandler { id: hover }

    Popup {
        id: tooltipPopup
        parent: root
        visible: hover.hovered && root.hasTooltip && (root.surface.error ?? "").length === 0
        y: -height - root.gap
        width: Math.min(420 * root.ratio, root.Window.window?.width ?? 420 * root.ratio)
        padding: 12 * root.ratio
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: DialogSurface { colors: root.colors; ratio: root.ratio }
        contentItem: ComponentBranch {
            active: tooltipPopup.visible
            controller: root.controller
            surface: root.surface
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            parentIndex: root.node.index
            tooltip: true
            horizontal: false
        }
    }

    Component {
        id: icon
        Item {
            implicitWidth: root.iconSide
            implicitHeight: root.rowHeight
            ProviderMark {
                anchors.centerIn: parent
                width: root.iconSide
                height: root.iconSide
                provider: root.node.providerMark
                telarMark: root.node.telarMark ?? false
                color: root.node.ink
                ratio: root.ratio
                visible: provider !== 0 || telarMark
            }
            ChromeIcon {
                anchors.fill: parent
                glyph: root.node.glyph
                color: root.node.ink
                pixelSize: root.typography.body
                primaryFamily: root.typography.primaryFamily ?? ""
                primaryStyle: root.typography.primaryStyle ?? ""
                visible: root.node.providerMark === 0 && !root.node.telarMark
            }
        }
    }

    Component {
        id: label
        Item {
            readonly property bool badge: root.node.kind === "badge"
            readonly property bool heading: root.node.kind === "heading"
            readonly property bool styled: root.node.italic || root.node.underline || root.node.strikethrough || root.block
            readonly property real padding: badge ? 6 * root.ratio : 0
            readonly property real markWidth: root.hasIcon ? root.iconSide + root.gap : 0
            implicitWidth: markWidth + Math.max(plain.implicitWidth, styledText.implicitWidth) + 2 * padding
            implicitHeight: root.block ? Math.max(root.rowHeight, styledText.implicitHeight) : root.rowHeight
            Rectangle {
                anchors.fill: parent
                radius: parent.badge ? 4 * root.ratio : 0
                color: root.node.background.a > 0 ? root.node.background : parent.badge ? root.colors.surface1 : "transparent"
            }
            Loader {
                width: root.iconSide
                height: parent.height
                active: root.hasIcon
                sourceComponent: icon
            }
            ChromeText {
                id: plain
                x: parent.markWidth + parent.padding
                width: Math.max(0, parent.width - x - parent.padding)
                height: parent.height
                text: parent.styled ? "" : root.node.text
                color: root.node.ink
                pixelSize: root.typography.small
                emphasized: root.node.bold
                elide: Text.ElideNone
                visible: !parent.styled
            }
            Text {
                id: styledText
                x: parent.markWidth + parent.padding
                width: Math.max(0, parent.width - x - parent.padding)
                text: parent.styled ? root.node.text : ""
                color: root.node.ink
                font.family: "IBM Plex Sans"
                font.pixelSize: parent.heading ? root.typography.body : root.typography.small
                font.weight: root.node.bold || parent.heading ? Font.DemiBold : Font.Normal
                font.italic: root.node.italic
                font.underline: root.node.underline
                font.strikeout: root.node.strikethrough
                textFormat: Text.PlainText
                renderType: Text.NativeRendering
                wrapMode: root.block ? Text.Wrap : Text.NoWrap
                maximumLineCount: root.block ? 3 : 1
                elide: Text.ElideRight
                visible: parent.styled
            }
        }
    }

    Component {
        id: group
        Item {
            readonly property real markWidth: root.hasIcon ? root.iconSide + root.gap : 0
            implicitWidth: markWidth + childrenTree.implicitWidth
            implicitHeight: root.rowHeight
            Loader {
                width: root.iconSide
                height: parent.height
                active: root.hasIcon
                sourceComponent: icon
            }
            ComponentBranch {
                id: childrenTree
                x: parent.markWidth
                width: implicitWidth
                height: parent.height
                controller: root.controller
                surface: root.surface
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.rowHeight
                parentIndex: root.node.index
                horizontal: true
                fit: false
            }
        }
    }

    Component {
        id: meter
        Item {
            readonly property bool panel: root.node.kind === "meter_row"
            readonly property real track: !panel && !root.compact ? root.trackWidth : 0
            implicitWidth: meterLabel.implicitWidth + (track > 0 ? root.gap + track : 0)
            implicitHeight: panel ? 44 * root.ratio : root.rowHeight
            ChromeText {
                id: meterLabel
                width: parent.panel ? parent.width : implicitWidth
                height: parent.panel ? root.rowHeight : parent.height
                text: root.node.text + (root.node.text.length > 0 ? " " : "") + (!parent.panel && root.node.detail.length > 0 ? root.node.detail : Math.round(root.node.value * 100) + "%")
                color: root.node.ink
                pixelSize: root.typography.small
                elide: Text.ElideNone
            }
            ChromeText {
                x: Math.max(0, parent.width - implicitWidth)
                width: implicitWidth
                height: root.rowHeight
                text: parent.panel ? root.node.detail : ""
                color: root.colors.subtext0
                pixelSize: root.typography.small
            }
            Item {
                id: track
                x: parent.panel ? 0 : meterLabel.width + root.gap
                y: parent.panel ? root.rowHeight + 3 * root.ratio : (parent.height - height) / 2
                width: parent.panel ? parent.width : parent.track
                height: 4 * root.ratio
                visible: parent.panel || parent.track > 0
                NativeRoundedRectangle {
                    anchors.fill: parent
                    color: root.colors.surface1
                    radius: 2 * root.ratio
                }
                NativeRoundedRectangle {
                    width: parent.width * root.node.value
                    height: parent.height
                    color: root.node.ink
                    radius: 2 * root.ratio
                }
                Rectangle {
                    x: Math.max(0, Math.min(parent.width - width, parent.width * (root.node.marker ?? 0)))
                    y: -2 * root.ratio
                    width: root.ratio
                    height: parent.height + 4 * root.ratio
                    color: root.colors.text
                    visible: root.node.marker !== undefined && root.node.marker !== null
                }
            }
        }
    }

    Component {
        id: sparkline
        Row {
            spacing: root.ratio
            Repeater {
                model: root.node.samples
                delegate: Item {
                    required property var modelData
                    width: 2 * root.ratio
                    height: root.rowHeight
                    NativeRoundedRectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 12 * root.ratio
                        radius: root.ratio / 2
                        color: root.colors.surface1
                    }
                    NativeRoundedRectangle {
                        y: (root.rowHeight + 12 * root.ratio) / 2 - height
                        width: parent.width
                        height: Math.max(root.ratio, 12 * root.ratio * parent.modelData / 100)
                        radius: root.ratio / 2
                        color: root.node.ink
                    }
                }
            }
        }
    }

    Component {
        id: metric
        BarMetric {
            readonly property var metrics: root.controller.hostMetrics
            record: metrics[["cpu", "memory", "battery"][root.node.metric]]
            samples: root.node.metric === 0 ? metrics.history : []
            battery: root.node.metric === 2
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            implicitHeight: root.rowHeight
        }
    }

    Component {
        id: machines
        MachineChrome {
            controller: root.controller
            colors: root.colors
            implicitWidth: preferredWidth
            implicitHeight: root.rowHeight
        }
    }

    Component {
        id: keyValue
        Item {
            implicitWidth: key.implicitWidth + value.implicitWidth + root.gap
            implicitHeight: root.rowHeight
            ChromeText {
                id: key
                width: Math.max(0, parent.width - value.width - root.gap)
                height: parent.height
                text: root.node.text
                color: root.colors.subtext0
                pixelSize: root.typography.small
            }
            ChromeText {
                id: value
                x: parent.width - width
                width: Math.min(implicitWidth, parent.width / 2)
                height: parent.height
                text: root.node.detail
                color: root.node.ink
                pixelSize: root.typography.small
                horizontalAlignment: Text.AlignRight
            }
        }
    }

    Component {
        id: actions
        Item {
            implicitWidth: buttons.implicitWidth
            implicitHeight: root.rowHeight
            ComponentBranch {
                id: buttons
                x: Math.max(0, parent.width - width)
                width: implicitWidth
                height: root.rowHeight
                controller: root.controller
                surface: root.surface
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.rowHeight
                parentIndex: root.node.index
                fit: false
            }
        }
    }

    Component {
        id: button
        Item {
            implicitWidth: control.textAdvance + 20 * root.ratio
            implicitHeight: root.rowHeight
            FormButton {
                id: control
                width: Math.min(parent.width, parent.implicitWidth)
                height: parent.height
                colors: root.colors
                pixelSize: root.typography.small
                radius: 5 * root.ratio
                disabledAlpha: 0.5
                pressedAlpha: 0.7
                text: root.node.text
                primary: root.node.primary
                labelColor: root.node.ink
                onActivated: root.activate()
            }
        }
    }

    Component {
        id: callout
        Column {
            spacing: root.gap
            Item {
                width: parent.width
                height: Math.max(root.hasIcon ? root.rowHeight : 0, calloutText.implicitHeight)
                Loader {
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.iconSide
                    height: root.rowHeight
                    active: root.hasIcon
                    sourceComponent: icon
                }
                Text {
                    id: calloutText
                    anchors.verticalCenter: parent.verticalCenter
                    x: root.hasIcon ? root.iconSide + root.gap : 0
                    width: Math.max(0, parent.width - x)
                    text: root.node.text + (root.node.detail.length > 0 ? "\n" + root.node.detail : "")
                    color: root.node.ink
                    font.family: "IBM Plex Sans"
                    font.pixelSize: root.typography.small
                    textFormat: Text.PlainText
                    renderType: Text.NativeRendering
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                }
            }
            ComponentBranch {
                id: calloutButton
                width: parent.width
                height: implicitHeight
                controller: root.controller
                surface: root.surface
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                parentIndex: root.node.index
                horizontal: false
            }
        }
    }

    Component {
        id: divider
        Rectangle {
            implicitWidth: root.ratio
            implicitHeight: root.ratio
            color: root.colors.surface1
        }
    }
}
