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
    property bool grouped: true
    property bool showCwd: true
    property bool interactive: true
    property string revision: ""
    readonly property var regions: layout
    property string commandText: record.command
    property string query: ""
    property real viewportHeight: 0
    property bool commandLoaded: true
    property string inspectionKey: "Ctrl+O"
    property bool macStyle: false
    property bool paneOpen: false
    implicitHeight: expanded ? regions.cardHeight : rowHeight
    signal activated(string revision)
    signal actionTriggered(string action)

    measurements: ({
        ratio: root.ratio,
        rowHeight: root.rowHeight,
        commandText: root.commandText,
        query: root.query,
        cellWidth: root.typography.grid.cellWidth,
        cellHeight: root.typography.grid.cellHeight,
        smallPixels: root.typography.small,
        viewportHeight: root.viewportHeight,
        cwd: cwd.implicitWidth,
        time: timestamp.implicitWidth,
        agent: root.record.author === "agent",
        showCwd: root.showCwd,
        hasCwd: root.record.cwd.length > 0,
        hasTime: timestamp.text.length > 0,
        expanded: root.expanded
    })

    Accessible.role: Accessible.ListItem
    Accessible.name: record.command
    Accessible.description: record.truncated ? "Capture truncated; cannot paste" : record.cwd
    Accessible.selected: selected

    NativeRoundedRectangle {
        id: background
        objectName: "historyRowBackground"
        x: root.regions.frame.x
        y: root.regions.frame.y
        width: root.regions.frame.width
        height: root.regions.frame.height
        radius: root.regions.radius
        color: Qt.alpha(root.colors.surface0, root.selected ? 1 : (pointer.containsMouse ? root.regions.hoverAlpha : 0))
    }

    NativeRoundedRectangle {
        anchors.fill: background
        radius: root.regions.radius
        color: Qt.alpha(root.colors.accent, root.regions.selectionTintAlpha)
        visible: root.selected
    }

    NativeRoundedRectangle {
        anchors.fill: background
        radius: root.regions.radius
        color: "transparent"
        borderColor: Qt.alpha(root.colors.accent, root.regions.selectionRingAlpha)
        borderWidth: root.regions.stroke
        visible: root.selected
    }

    Item {
        id: frameClip
        z: 1
        x: root.regions.frame.x
        y: root.regions.frame.y
        width: root.regions.frame.width
        height: root.regions.frame.height
        clip: true

        Item {
            x: -frameClip.x
            y: -frameClip.y
            width: root.width
            height: root.height

            CellText {
                objectName: "historyStatus"
                x: root.regions.status.x
                y: root.regions.status.y
                width: root.regions.status.width
                height: root.regions.status.height
                text: root.record.statusGlyph
                color: root.colors[root.record.statusColor]
                grid: root.typography.grid
            }

            Repeater {
                model: root.regions.lines.length
                delegate: Item {
                    id: line
                    required property int index
                    readonly property var value: root.regions.lines[index]
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

                    Repeater {
                        model: line.value.matches
                        delegate: CellText {
                            objectName: "historyMatch"
                            required property var modelData
                            x: modelData.bounds.x
                            y: modelData.bounds.y
                            width: modelData.bounds.width
                            height: modelData.bounds.height
                            text: modelData.text
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
                x: root.regions.provider.x
                y: root.regions.provider.y
                width: root.regions.provider.width
                height: root.regions.provider.height
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
                    radius: root.regions.providerRadius
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
                x: root.regions.cwd.x
                y: root.regions.cwd.y
                width: root.regions.cwd.width
                height: root.regions.cwd.height
                text: root.record.compactCwd
                color: root.colors.subtext0
                opacity: root.regions.cwdAlpha
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: width > 0
            }

            ChromeText {
                id: timestamp
                objectName: "historyTimestamp"
                x: root.regions.time.x
                y: root.regions.time.y
                width: root.regions.time.width
                height: root.regions.time.height
                text: root.grouped ? root.record.clock : root.record.date
                color: root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: width > 0
            }

            Loader {
                x: root.regions.meta.x
                y: root.regions.meta.y
                width: root.regions.meta.width
                height: root.regions.meta.height
                active: root.expanded
                sourceComponent: HistoryMeta {
                    record: root.record
                    colors: root.colors
                    pixelSize: root.typography.small
                    ratio: root.ratio
                    selected: root.selected
                    paneOpen: root.paneOpen
                    interactive: root.interactive
                    commandLoaded: root.commandLoaded
                    showDirectory: root.showCwd
                    macStyle: root.macStyle
                    more: root.regions.more
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
