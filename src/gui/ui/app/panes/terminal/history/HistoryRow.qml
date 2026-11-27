pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

HistoryRowLayout {
    id: root
    objectName: "historyRow"

    required property var record
    required property var colors
    required property var typography
    required property real rowHeight
    property real ratio: 1
    property bool selected: false
    property bool expanded: false
    property real open: expanded ? 1 : 0
    property real highlight: selected ? 1 : 0
    readonly property bool cardVisible: open > 0
    property bool grouped: true
    property bool showCwd: true
    property bool interactive: true
    property HistoryController controller: null
    property string revision: ""
    property alias regions: root.layout
    readonly property var lineRegions: lineLayout
    readonly property var geometryRegions: geometryLayout
    property string commandText: record.command
    property real viewportHeight: 0
    property bool commandLoaded: true
    property string inspectionKey: "Ctrl+O"
    property bool macStyle: false
    property bool paneOpen: false
    // What the configuration shows beside the command, and how the time reads.
    property bool showDuration: true
    property bool showExit: true
    // The machine it ran on, when the page holds runs of more than one.
    property bool showHost: false
    property bool relativeTime: false
    // Marked to be used with the other commands marked.
    property bool marked: false
    // The digit Alt runs this row with, 0 for none.
    property int quickKey: 0
    // How long the command ran and how it failed: a command that succeeded, or still runs, shows
    // no exit.
    readonly property string detailText: {
        const parts = [];
        if (root.showHost && (root.record.host ?? "").length > 0) {
            parts.push(root.record.host);
        }
        if (root.showDuration && !root.record.running && root.record.measured === true) {
            parts.push(root.record.duration);
        }
        if (root.showExit && root.record.exitCode !== undefined && root.record.exitCode !== 0) {
            parts.push("exit " + root.record.exitCode);
        }
        return parts.join(" · ");
    }
    // What the search read in the output, shown where the directory is.
    readonly property bool excerpted: (record.excerpt ?? "").length > 0
    implicitHeight: cardVisible ? geometryRegions.cardHeight : rowHeight
    signal activated(string revision)
    signal actionTriggered(string action)

    measurements: ({
        ratio: root.ratio,
        rowHeight: root.rowHeight,
        commandText: root.commandText,
        cellWidth: root.typography.grid.cellWidth,
        cellHeight: root.typography.grid.cellHeight,
        smallPixels: root.typography.small,
        viewportHeight: root.viewportHeight,
        cwd: root.excerpted ? excerptRuns.implicitWidth : cwd.implicitWidth,
        time: timestamp.implicitWidth,
        detail: detail.implicitWidth,
        hasDetail: root.detailText.length > 0,
        agent: root.record.author === "agent",
        showCwd: root.showCwd || root.excerpted,
        hasCwd: root.excerpted || root.record.cwd.length > 0,
        hasTime: timestamp.text.length > 0,
        expanded: root.cardVisible,
        open: root.open
    })

    Accessible.role: Accessible.ListItem
    Accessible.name: record.command
    Accessible.description: record.truncated ? "Capture truncated; cannot paste" : record.cwd
    Accessible.selected: selected

    NativeRoundedRectangle {
        id: background
        objectName: "historyRowBackground"
        x: root.geometryRegions.frame.x
        y: root.geometryRegions.frame.y
        width: root.geometryRegions.frame.width
        height: root.geometryRegions.frame.height
        radius: root.geometryRegions.radius
        color: Qt.alpha(root.colors.surface0, root.highlight > 0 ? root.highlight : ((root.controller ? (root.controller.hoveredRow === root.historyIndex && root.controller.hoveredRowRevision === root.revision) : pointer.containsMouse) ? root.geometryRegions.hoverAlpha : 0))
    }

    NativeRoundedRectangle {
        anchors.fill: background
        radius: root.geometryRegions.radius
        color: Qt.alpha(root.colors.accent, root.geometryRegions.selectionTintAlpha * root.highlight)
        visible: root.highlight > 0
    }

    NativeRoundedRectangle {
        anchors.fill: background
        radius: root.geometryRegions.radius
        color: "transparent"
        borderColor: Qt.alpha(root.colors.accent, root.geometryRegions.selectionRingAlpha * root.highlight)
        borderWidth: root.geometryRegions.stroke
        visible: root.highlight > 0
    }

    Item {
        id: frameClip
        z: 1
        x: root.geometryRegions.frame.x
        y: root.geometryRegions.frame.y
        width: root.geometryRegions.frame.width
        height: root.geometryRegions.frame.height
        clip: true

        Item {
            x: -frameClip.x
            y: -frameClip.y
            width: root.width
            height: root.height
            // A run a raw listing shows around a match, which does not match itself.
            opacity: root.record.neighbour === true && !root.selected ? 0.5 : 1

            // The mark of a command marked to be used with the others, over its status.
            NativeRoundedRectangle {
                objectName: "historyMarked"
                x: root.geometryRegions.status.x - 4 * root.ratio
                y: root.geometryRegions.frame.y + 4 * root.ratio
                width: 3 * root.ratio
                height: Math.max(0, root.geometryRegions.frame.height - 8 * root.ratio)
                radius: width / 2
                color: root.colors.accent
                visible: root.marked
            }

            CellText {
                objectName: "historyQuickKey"
                x: root.geometryRegions.status.x - root.typography.grid.cellWidth
                y: root.geometryRegions.status.y
                width: root.typography.grid.cellWidth
                height: root.geometryRegions.status.height
                text: root.quickKey > 0 ? String(root.quickKey) : ""
                color: root.colors.overlay1
                grid: root.typography.grid
                visible: root.quickKey > 0 && !root.marked
                Accessible.ignored: true
            }

            CellText {
                objectName: "historyStatus"
                x: root.geometryRegions.status.x
                y: root.geometryRegions.status.y
                width: root.geometryRegions.status.width
                height: root.geometryRegions.status.height
                text: root.record.statusGlyph
                color: root.colors[root.record.statusColor]
                grid: root.typography.grid
            }

            Repeater {
                model: root.lineRegions.length
                delegate: Item {
                    id: line
                    required property int index
                    readonly property var value: root.lineRegions[index]
                    width: root.width
                    height: root.height

                    CellText {
                        objectName: "historyRowCommand"
                        x: line.value.bounds.x
                        y: line.value.bounds.y
                        width: line.value.bounds.width
                        height: line.value.bounds.height
                        text: line.value.text
                        color: root.colors.text
                        grid: root.typography.grid
                        clip: true
                        // The card draws its lines in the shell's colours instead.
                        opacity: (line.value.runs ?? []).length > 0 ? 0 : 1
                    }

                    Item {
                        x: line.value.bounds.x
                        y: line.value.bounds.y
                        width: line.value.bounds.width
                        height: line.value.bounds.height
                        clip: true
                        visible: (line.value.runs ?? []).length > 0

                        Repeater {
                            model: line.value.runs ?? []
                            delegate: CellText {
                                objectName: "historySyntax"
                                required property var modelData
                                x: modelData.bounds.x - line.value.bounds.x
                                width: modelData.bounds.width
                                height: modelData.bounds.height
                                text: modelData.text
                                color: root.colors[modelData.role] ?? root.colors[modelData.fallback] ?? root.colors.text
                                grid: root.typography.grid
                                Accessible.ignored: true
                            }
                        }
                    }

                    CellText {
                        objectName: "historyContinuation"
                        x: line.value.markerBounds.x
                        y: line.value.markerBounds.y
                        width: line.value.markerBounds.width
                        height: line.value.markerBounds.height
                        text: line.value.marker
                        color: root.colors.subtext0
                        grid: root.typography.grid
                        visible: text.length > 0
                        Accessible.ignored: true
                    }

                    HistoryMatchModel {
                        id: matches
                        records: line.value.matches
                    }

                    Repeater {
                        model: matches.model
                        delegate: CellText {
                            objectName: "historyMatch"
                            required property int index
                            required property var record
                            visible: index < matches.activeCount
                            x: record.bounds.x
                            y: record.bounds.y
                            width: record.bounds.width
                            height: record.bounds.height
                            text: record.text
                            color: root.colors.accent
                            grid: root.typography.grid
                            bold: true
                            Accessible.ignored: true
                        }
                    }
                }
            }

            Item {
                objectName: "historyProvider"
                x: root.geometryRegions.provider.x
                y: root.geometryRegions.provider.y
                width: root.geometryRegions.provider.width
                height: root.geometryRegions.provider.height
                visible: width > 0

                ProviderMark {
                    anchors.fill: parent
                    provider: root.record.providerMark
                    color: root.colors.text
                    ratio: root.ratio
                    visible: provider !== 0
                }

                NativeRoundedRectangle {
                    anchors.fill: parent
                    color: root.colors.surface1
                    radius: root.geometryRegions.providerRadius
                    visible: root.record.providerMark === 0
                }

                ChromeText {
                    anchors.fill: parent
                    text: root.record.providerLetter
                    color: root.colors.text
                    emphasized: true
                    horizontalAlignment: Text.AlignHCenter
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                    visible: root.record.providerMark === 0
                }
            }

            ChromeText {
                id: cwd
                objectName: "historyDirectory"
                x: root.geometryRegions.cwd.x
                y: root.geometryRegions.cwd.y
                width: root.geometryRegions.cwd.width
                height: root.geometryRegions.cwd.height
                text: root.record.compactCwd
                color: root.colors.subtext0
                opacity: root.geometryRegions.cwdAlpha
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: width > 0 && !root.excerpted
            }

            Row {
                id: excerptRuns
                objectName: "historyExcerpt"
                x: root.geometryRegions.cwd.x
                y: root.geometryRegions.cwd.y
                width: root.geometryRegions.cwd.width
                height: root.geometryRegions.cwd.height
                clip: true
                visible: width > 0 && root.excerpted

                Repeater {
                    model: root.excerpted && root.controller ? root.controller.excerpt(root.record.excerpt, root.record.excerptRanges ?? []) : []
                    delegate: ChromeText {
                        required property var modelData
                        height: excerptRuns.height
                        text: modelData.text
                        color: modelData.marked ? root.colors.accent : root.colors.subtext0
                        emphasized: modelData.marked
                        pixelSize: root.typography.small
                        elide: Text.ElideNone
                    }
                }
            }

            ChromeText {
                id: detail
                objectName: "historyDetail"
                x: root.geometryRegions.detail.x
                y: root.geometryRegions.detail.y
                width: root.geometryRegions.detail.width
                height: root.geometryRegions.detail.height
                text: root.detailText
                color: root.record.failed ? root.colors.red : root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: width > 0
            }

            ChromeText {
                id: timestamp
                objectName: "historyTimestamp"
                x: root.geometryRegions.time.x
                y: root.geometryRegions.time.y
                width: root.geometryRegions.time.width
                height: root.geometryRegions.time.height
                text: root.relativeTime ? root.record.age : (root.grouped ? root.record.clock : root.record.date)
                color: root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: width > 0
            }

            Loader {
                x: root.geometryRegions.meta.x
                y: root.geometryRegions.meta.y
                width: root.geometryRegions.meta.width
                height: root.geometryRegions.meta.height
                active: root.cardVisible
                sourceComponent: HistoryMeta {
                    record: root.record
                    colors: root.colors
                    pixelSize: root.typography.small
                    ratio: root.ratio
                    selected: root.selected
                    paneOpen: root.paneOpen
                    interactive: root.interactive
                    controller: root.controller
                    historyIndex: root.historyIndex
                    revision: root.revision
                    commandLoaded: root.commandLoaded
                    showDirectory: root.showCwd
                    macStyle: root.macStyle
                    more: root.geometryRegions.more
                    onActionTriggered: action => root.actionTriggered(action)
                }
            }
        }
    }

    ActionPointer {
        id: pointer
        anchors.fill: background
        enabled: root.interactive
        identity: root.revision
        onActivated: root.activated(root.revision)
    }
}
