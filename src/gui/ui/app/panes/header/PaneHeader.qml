pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

PaneHeaderLayout {
    id: root

    required property var record
    required property var colors
    required property var typography
    property bool focused: false
    property bool prefixPending: false
    // What the pane's own view adds after its context: an editor's file and mode.
    property string detail: ""
    // Mod content for the header's pieces, by slot name.
    readonly property var elements: record.elements ?? ({})
    readonly property var builtins: ({pane_mark: markPiece, pane_program: programPiece, pane_context: contextPiece, pane_status: statusPiece, pane_progress: progressPiece})
    // A click on an element a mod drew in the header.
    signal elementActivated(string slot, string key, string revision, int element)
    // The agent's state is a dot on the pane's tile; a mod may still place the worded chip.
    readonly property string statusColor: record.agent?.statusColor ?? ""
    readonly property real tileWidth: elements.pane_mark ? markHost.implicitWidth : 18 * ratio
    readonly property real contextGap: 8 * ratio
    readonly property real programWidth: elements.pane_program ? programHost.implicitWidth : nameLabel.implicitWidth
    readonly property real contextWidth: elements.pane_context ? contextHost.implicitWidth : contextLabel.text.length > 0 ? contextLabel.implicitWidth : 0
    measurements: ({
        index: root.tileWidth,
        name: root.programWidth + (root.contextWidth > 0 ? root.contextGap + root.contextWidth : 0),
        chip: root.elements.pane_status ? statusHost.implicitWidth : 0,
        paused: root.record.imagesPaused ? pausedLabel.implicitWidth : 0,
        progress: root.elements.pane_progress ? progressHost.implicitWidth : progress.fullWidth,
        compactProgress: root.elements.pane_progress ? progressHost.implicitWidth : progress.compactWidth,
        needsAttention: root.record.needsAttention ?? false
    })

    ApplicationTile {
        objectName: "paneMark"
        x: root.indexBounds.x
        y: root.indexBounds.y + (root.indexBounds.height - height) / 2
        width: Math.min(root.tileWidth, root.indexBounds.width)
        height: 14 * root.ratio
        radius: ChromeStyle.smallRadius * root.ratio
        visible: root.tileWidth > 0 && !root.elements.pane_mark
        mark: root.record
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        number: root.prefixPending ? root.record.index : ""
        statusColor: root.statusColor
    }

    ChromeText {
        id: nameLabel
        objectName: "paneProgram"
        x: root.nameBounds.x
        y: root.nameBounds.y
        width: Math.min(root.nameBounds.width, implicitWidth)
        height: root.nameBounds.height
        visible: !root.elements.pane_program
        text: root.record.program
        pixelSize: root.typography.title
        color: root.focused ? root.colors.chromeText : root.colors.text
        emphasized: true
        elide: Text.ElideRight
    }

    ChromeText {
        id: contextLabel
        objectName: "paneContext"
        x: root.nameBounds.x + Math.min(root.nameBounds.width, root.programWidth) + root.contextGap
        y: root.nameBounds.y
        width: Math.max(0, root.nameBounds.x + root.nameBounds.width - x)
        height: root.nameBounds.height
        // The tab of a pane that is alone in it already shows the pane's directory.
        readonly property string place: (root.record.aloneInTab ?? false) && (root.record.contextIsDirectory ?? false) ? "" : (root.record.context ?? "")
        text: [root.record.remote ?? "", place, root.record.git ?? "", root.detail].filter(part => part.length > 0).join("   ")
        pixelSize: root.typography.small
        color: root.colors.subtext0
        visible: !root.elements.pane_context && width >= 4 * root.typography.body && text.length > 0
        elide: Text.ElideRight
    }

    ChromeText {
        id: pausedLabel
        objectName: "paneImagesPaused"
        x: root.pausedBounds.x
        y: root.pausedBounds.y
        width: root.pausedBounds.width
        height: root.pausedBounds.height
        text: "images paused"
        pixelSize: root.typography.body
        color: root.colors.yellow
        elide: Text.ElideNone
        visible: root.pausedBounds.width > 0
    }

    PaneProgress {
        id: progress
        objectName: "paneProgress"
        x: root.progressBounds.x
        y: root.progressBounds.y
        width: root.progressBounds.width
        height: root.progressBounds.height
        ratio: root.ratio
        record: root.record
        colors: root.colors
        typography: root.typography
        geometry: root.style
        compact: root.compactProgress
        visible: root.progressBounds.width > 0 && !root.elements.pane_progress
    }

    // A mod piece takes the default piece's bounds; the layout measured it above.
    component Piece: ElementHost {
        required property string slot
        content: root.elements[slot] ?? null
        visible: content !== null
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
        builtins: root.builtins
    }

    Piece {
        id: markHost
        slot: "pane_mark"
        x: root.indexBounds.x
        y: root.indexBounds.y
        width: root.indexBounds.width
        height: root.indexBounds.height
    }

    Piece {
        id: programHost
        slot: "pane_program"
        x: root.nameBounds.x
        y: root.nameBounds.y
        width: Math.min(root.nameBounds.width, implicitWidth)
        height: root.nameBounds.height
    }

    Piece {
        id: contextHost
        slot: "pane_context"
        x: contextLabel.x
        y: root.nameBounds.y
        width: contextLabel.width
        height: root.nameBounds.height
    }

    Piece {
        id: statusHost
        slot: "pane_status"
        x: root.chipBounds.x
        y: root.chipBounds.y
        width: root.chipBounds.width
        height: root.chipBounds.height
    }

    Piece {
        id: progressHost
        slot: "pane_progress"
        x: root.progressBounds.x
        y: root.progressBounds.y
        width: root.progressBounds.width
        height: root.progressBounds.height
    }

    Component {
        id: markPiece
        ApplicationTile {
            implicitWidth: 18 * root.ratio
            implicitHeight: 14 * root.ratio
            radius: ChromeStyle.smallRadius * root.ratio
            mark: root.record
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            statusColor: root.statusColor
        }
    }

    Component {
        id: programPiece
        ChromeText {
            text: root.record.program
            pixelSize: root.typography.title
            color: root.focused ? root.colors.chromeText : root.colors.text
            emphasized: true
        }
    }

    Component {
        id: contextPiece
        ChromeText {
            text: root.record.context ?? ""
            pixelSize: root.typography.small
            color: root.colors.subtext0
        }
    }

    Component {
        id: statusPiece
        PaneStatusChip {
            record: root.record.agent ?? ({})
            colors: root.colors
            typography: root.typography
            geometry: root.style
            needsAttention: root.record.needsAttention ?? false
        }
    }

    Component {
        id: progressPiece
        PaneProgress {
            implicitWidth: fullWidth
            ratio: root.ratio
            record: root.record
            colors: root.colors
            typography: root.typography
            geometry: root.style
        }
    }
}
