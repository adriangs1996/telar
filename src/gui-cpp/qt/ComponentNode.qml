pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

KeyboardAction {
    id: root

    required property var controller
    required property var surface
    required property var node
    required property var colors
    required property var typography
    property real ratio: 1
    property real rowHeight: 28 * ratio
    property bool compact: false
    property bool barGroup: false
    property var fittedLevels: ({})
    readonly property real gap: 6 * ratio
    readonly property int maximumBlockLines: 8
    readonly property real iconSide: (node.kind === "callout" ? 18 : node.kind === "group" ? 14 : 16) * ratio
    readonly property real trackWidth: 24 * ratio
    readonly property real meterGap: 5 * ratio
    readonly property bool block: ["heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"].indexOf(node.kind) >= 0
    readonly property bool hasIcon: node.glyph.length > 0 || node.providerMark !== 0 || node.telarMark
    readonly property bool hasTooltip: (surface.nodes ?? []).some(child => child.parent === node.index && child.tooltip)
    readonly property real compactWidthDelta: node.kind === "meter" ? trackWidth + meterGap : 0
    readonly property real focusRadius: 4 * ratio
    readonly property string activationIdentity: surface.identity + ":" + surface.generation + ":" + surface.source + ":" + node.index + ":" + node.actionIdentity
    readonly property real unreducedWidth: node.kind === "group" ? (visual.item?.unreducedWidth ?? 0) : implicitWidth + (compact ? compactWidthDelta : 0)
    readonly property var fitNodes: [{
        index: node.index, parent: node.parent, priority: node.priority,
        group: node.kind === "group", meter: node.kind === "meter",
        width: node.kind === "group" ? (visual.item?.chromeWidth ?? 0) : unreducedWidth,
        compactDelta: compactWidthDelta,
        childGap: visual.item?.childGap, leadingGap: visual.item?.leadingGap,
    }].concat(node.kind === "group" ? (visual.item?.fitNodes ?? []) : [])

    implicitWidth: visual.item?.implicitWidth ?? 0
    implicitHeight: visual.item?.implicitHeight ?? rowHeight
    opacity: node.faint ? 0.6 : 1
    interactive: node.clickable && node.kind !== "button"
    onActivated: root.activate()

    function activate() {
        controller.activateComponent(surface.source, node.index, surface.generation, surface.revision, mapToItem(null, width / 2, 0));
    }

    // A bar yields its tooltips to an open panel or pick; a panel's own nodes yield only to a pick.
    // Called from the hover-guarded binding so that only the hovered node tracks these projections.
    function tooltipCovered() {
        if (controller.componentPick.open ?? false) {
            return true;
        }

        return !(surface.open ?? false) && (controller.componentPanel.open ?? false);
    }

    Accessible.role: node.clickable ? Accessible.Button : Accessible.StaticText
    Accessible.name: node.accessibleName ?? node.text
    Accessible.onPressAction: if (node.clickable) activate()

    Loader {
        id: visual
        width: root.width
        height: root.height
        sourceComponent: {
            switch (root.node.kind) {
            case "group": return root.surface.kind === "metrics" ? builtinMetrics : group;
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

    Loader {
        anchors.fill: parent
        active: root.interactive && root.activeFocus
        sourceComponent: NativeRoundedRectangle {
            objectName: "componentKeyboardFocus"
            color: "transparent"
            borderColor: root.colors.accent
            borderWidth: 1 / Screen.devicePixelRatio
            radius: root.focusRadius
        }
    }

    ActionPointer {
        anchors.fill: parent
        enabled: root.node.clickable && root.node.kind !== "button"
        identity: root.activationIdentity
        hoverEnabled: false
        onCaptureStarted: root.forceActiveFocus(Qt.MouseFocusReason)
        onActivated: root.activate()
    }

    HoverHandler { id: hover }

    Popup {
        id: tooltipPopup
        objectName: "componentTooltip"
        parent: root
        visible: hover.hovered && root.hasTooltip && (root.surface.error ?? "").length === 0 && !root.tooltipCovered()
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
                monochrome: telarMark
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
                objectName: "componentStyledText"
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
                maximumLineCount: root.block ? root.maximumBlockLines : 1
                elide: Text.ElideRight
                visible: parent.styled
            }
        }
    }

    Component {
        id: builtinMetrics
        MetricsGroup {
            metrics: root.controller.hostMetrics
            nodes: root.surface.nodes ?? []
            fittedLevels: root.fittedLevels
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            implicitHeight: root.rowHeight
        }
    }

    Component {
        id: group
        Item {
            readonly property real padding: root.barGroup ? root.gap : 0
            readonly property real childGap: root.gap
            readonly property real leadingGap: root.barGroup ? childGap : 0
            readonly property real markWidth: root.hasIcon ? root.iconSide + childGap : 0
            readonly property real chromeWidth: root.barGroup ? 2 * padding + (root.hasIcon ? root.iconSide : -childGap) : markWidth
            readonly property real childWidth: childrenTree.implicitWidth
            readonly property real fullChildWidth: childrenTree.item?.fullWidth ?? 0
            readonly property real unreducedWidth: chromeWidth + fullChildWidth + (fullChildWidth > 0 ? leadingGap : 0)
            readonly property var fitNodes: childrenTree.item?.fitNodes ?? []
            implicitWidth: chromeWidth + childWidth + (childWidth > 0 ? leadingGap : 0)
            implicitHeight: root.rowHeight
            Loader {
                x: parent.padding
                width: root.iconSide
                height: parent.height
                active: root.hasIcon
                sourceComponent: icon
            }
            ComponentBranch {
                id: childrenTree
                x: parent.padding + parent.markWidth
                width: implicitWidth
                height: parent.height
                controller: root.controller
                surface: root.surface
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.rowHeight
                gap: root.gap
                parentIndex: root.node.index
                horizontal: true
                fit: false
                fittedLevels: root.fittedLevels
            }
        }
    }

    Component {
        id: meter
        Item {
            readonly property bool panel: root.node.kind === "meter_row"
            readonly property real lineHeight: 18 * root.ratio
            readonly property real detailHeight: 16 * root.ratio
            readonly property real detailedHeight: 36 * root.ratio
            readonly property real columnGap: 14 * root.ratio
            readonly property real numberWidth: 40 * root.ratio
            readonly property real labelShare: 0.38
            readonly property real labelWidth: Math.round(width * labelShare)
            readonly property real track: !panel && !root.compact ? root.trackWidth : 0
            readonly property real labelGap: !panel && root.node.text.length > 0 ? root.meterGap : 0
            implicitWidth: meterLabel.implicitWidth + (panel ? 0 : labelGap + meterValue.implicitWidth + (track > 0 ? root.meterGap + track : 0))
            implicitHeight: panel ? (root.node.detail.length > 0 ? detailedHeight : lineHeight) : root.rowHeight
            ChromeText {
                id: meterLabel
                objectName: "componentMeterLabel"
                width: parent.panel ? parent.labelWidth : implicitWidth
                height: parent.panel ? parent.lineHeight : parent.height
                text: root.node.text
                color: parent.panel ? root.colors.text : root.colors.subtext0
                pixelSize: parent.panel ? root.typography.body : root.typography.small
                emphasized: !parent.panel
                elide: Text.ElideNone
            }
            ChromeText {
                objectName: "componentMeterDetail"
                y: parent.lineHeight
                width: parent.labelWidth
                height: parent.detailHeight
                text: root.node.detail
                visible: parent.panel && text.length > 0
                color: root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
            }
            ChromeText {
                id: meterValue
                objectName: "componentMeterValue"
                x: parent.panel ? parent.width - width : meterTrack.x + meterTrack.width + (parent.track > 0 ? root.meterGap : 0)
                width: parent.panel ? Math.min(parent.width, parent.numberWidth) : implicitWidth
                height: parent.height
                text: !parent.panel && root.node.detail.length > 0 ? root.node.detail : Math.round(root.node.value * 100) + "%"
                color: root.node.ink
                pixelSize: parent.panel ? root.typography.body : root.typography.small
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideNone
            }
            Item {
                // An id named "track" shadows the numeric property used to measure the meter.
                id: meterTrack
                objectName: "componentMeterTrack"
                x: parent.panel ? parent.labelWidth + parent.columnGap : meterLabel.width + parent.labelGap
                y: Math.round((parent.height - height) / 2)
                width: parent.panel ? Math.max(0, parent.width - parent.numberWidth - parent.columnGap - x) : parent.track
                height: (parent.panel ? 4 : 3) * root.ratio
                visible: parent.panel || parent.track > 0
                NativeRoundedRectangle {
                    anchors.fill: parent
                    color: root.colors.surface1
                    radius: parent.height / 2
                }
                NativeRoundedRectangle {
                    width: parent.width * root.node.value
                    height: parent.height
                    color: root.node.ink
                    radius: parent.height / 2
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
            id: history
            readonly property int maximumSamples: 9
            readonly property var shownSamples: root.node.samples.slice(-maximumSamples)
            spacing: root.ratio
            Repeater {
                model: history.shownSamples
                delegate: Item {
                    objectName: "componentSparklineSample"
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
            inlineFacts: true
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
                identity: root.activationIdentity
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
        Item {
            id: card
            readonly property real padding: 12 * root.ratio
            readonly property real titleHeight: 18 * root.ratio
            readonly property real detailHeight: 16 * root.ratio
            readonly property real markWidth: root.hasIcon ? root.iconSide + padding : 0
            readonly property var actionNode: (root.surface.nodes ?? []).find(child => child.parent === root.node.index && child.kind === "button" && !child.tooltip) ?? null
            readonly property real actionWidth: actionNode !== null ? calloutButton.width + padding : 0
            implicitHeight: 52 * root.ratio

            NativeRoundedRectangle {
                anchors.fill: parent
                color: root.colors.panel_bg
                borderColor: root.colors.surface1
                borderWidth: root.ratio
                radius: 8 * root.ratio
            }
            Loader {
                x: card.padding
                anchors.verticalCenter: parent.verticalCenter
                width: root.iconSide
                height: root.rowHeight
                active: root.hasIcon
                sourceComponent: icon
            }
            Column {
                x: card.padding + card.markWidth
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - 2 * card.padding - card.markWidth - card.actionWidth)
                ChromeText {
                    width: parent.width
                    height: card.titleHeight
                    text: root.node.text
                    color: root.colors.text
                    pixelSize: root.typography.body
                    elide: Text.ElideNone
                }
                ChromeText {
                    width: parent.width
                    height: visible ? card.detailHeight : 0
                    visible: root.node.detail.length > 0
                    text: root.node.detail
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                }
            }
            ComponentBranch {
                id: calloutButton
                anchors.right: parent.right
                anchors.rightMargin: card.padding
                anchors.verticalCenter: parent.verticalCenter
                width: implicitWidth
                height: root.rowHeight
                active: card.actionNode !== null
                controller: root.controller
                surface: root.surface
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                rowHeight: root.rowHeight
                parentIndex: root.node.index
                roots: card.actionNode !== null ? [card.actionNode.index] : []
                fit: false
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
