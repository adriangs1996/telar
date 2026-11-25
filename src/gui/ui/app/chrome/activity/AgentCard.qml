pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// One shape for every agent and process, whatever its state: the first row names it and says its
// state, the second says what happens there and the third where it runs.
ActivityFrame {
    id: root

    required property var typography
    // Mod content for this card and its pieces, by slot name.
    readonly property var elements: record.elements ?? ({})
    readonly property bool drawn: elements.agent_card !== undefined
    readonly property var builtins: ({agent_mark: markPiece, agent_title: titlePiece, agent_project: projectPiece, agent_status: statusPiece})
    readonly property bool process: record.process ?? false
    // An idle shell, an agent at rest or one telar cannot read: its mark and its title recede.
    readonly property bool resting: (record.dim ?? false) || (!process && (record.statusCode ?? 0) === 0)
    readonly property real rowWidth: Math.max(0, width - geometry.textInset - geometry.padding)
    // The title takes what the state leaves of its row.
    readonly property real titleWidth: Math.max(0, rowWidth - (status.visible ? status.usedWidth + (status.usedWidth > 0 ? geometry.gap : 0) : rowWidth / 2 + geometry.gap))
    // What happens in the pane: the agent's signal, or the command a process runs or ran last.
    readonly property string commandLine: record.commandLine ?? ""
    readonly property string happening: !process ? (record.signal ?? "") : commandLine.length > 0 ? commandLine : (record.dim ?? false) ? "No commands yet" : "No command"
    // Where it runs, most general first. A tab named after the card or its project says nothing.
    readonly property string tab: record.tab ?? ""
    readonly property string place: [record.project ?? "", tab === record.title || tab === record.project ? "" : tab, record.cwd ?? ""].filter(part => part.length > 0).join(" · ")
    // The terminal's face at the small size: a port reads as the terminal writes it.
    readonly property var cellGrid: typography.grid ?? null
    readonly property real cellScale: cellGrid ? typography.small / cellGrid.pixelHeight : 1
    readonly property var portGrid: cellGrid ? ({family: cellGrid.family, style: cellGrid.style, pixelHeight: typography.small, cellWidth: cellGrid.cellWidth * cellScale, cellHeight: geometry.agentDetailRow, baseline: (geometry.agentDetailRow - cellGrid.cellHeight * cellScale) / 2 + cellGrid.baseline * cellScale}) : null
    // A click on an element a mod drew in a card; the window runs it.
    signal elementActivated(string slot, string key, string revision, int element)

    implicitHeight: geometry.agentHeight

    // A word of the second row's outcome in the terminal's face, or the chrome's without one.
    component Address: Item {
        id: address

        required property string text
        required property color color

        implicitWidth: Math.ceil(root.portGrid !== null ? (cells.item?.implicitWidth ?? 0) : (plain.item?.implicitWidth ?? 0))
        width: implicitWidth
        height: root.geometry.agentDetailRow

        Loader {
            id: cells
            anchors.fill: parent
            active: root.portGrid !== null
            sourceComponent: CellText {
                text: address.text
                grid: root.portGrid
                color: address.color
            }
        }

        Loader {
            id: plain
            anchors.fill: parent
            active: root.portGrid === null
            sourceComponent: ChromeText {
                text: address.text
                color: address.color
                pixelSize: root.typography.small
                elide: Text.ElideNone
            }
        }
    }

    ApplicationTile {
        id: tile
        objectName: "agentProviderMark"
        x: root.geometry.padding + (root.geometry.markColumn - width) / 2
        y: root.geometry.padding + (root.geometry.agentTitleRow - height) / 2
        width: root.geometry.tileWidth
        height: root.geometry.tileHeight
        radius: ChromeStyle.smallRadius * root.ratio
        visible: !root.drawn && root.elements.agent_mark === undefined
        mark: root.record
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        dimmed: root.resting
    }

    // The agent's state on the tile's lower right corner: its glyph in its color, cut from the
    // sidebar. The working glyph pulses; an agent at rest has no badge.
    NativeRoundedRectangle {
        objectName: "agentStatusBadge"
        x: tile.x + tile.width - width * 0.6
        y: tile.y + tile.height - height * 0.6
        width: root.geometry.badgeSide
        height: width
        radius: width / 2
        color: root.colors.sidebarBackground
        visible: tile.visible && root.record.badge.length > 0

        ChromeIcon {
            objectName: "agentStatusBadgeGlyph"
            anchors.fill: parent
            glyph: root.record.badgeGlyph
            color: root.record.badge.length > 0 ? root.colors[root.record.badge] : "transparent"
            pixelSize: Math.round(parent.width * 0.9)
            primaryFamily: root.typography.primaryFamily ?? ""
            primaryStyle: root.typography.primaryStyle ?? ""
            opacity: root.record.working ? (root.pulseAlpha ?? status.animatedAlpha) : 1
        }
    }

    AgentStatus {
        id: status
        objectName: "agentStatus"
        x: root.geometry.textInset + root.rowWidth / 2
        y: root.geometry.padding
        width: root.rowWidth / 2
        height: root.geometry.agentTitleRow
        visible: !root.drawn && root.elements.agent_status === undefined
        record: root.record
        colors: root.colors
        typography: root.typography
        running: root.animate && visible
    }

    ChromeText {
        objectName: "agentTitleLabel"
        x: root.geometry.textInset
        y: root.geometry.padding
        width: root.titleWidth
        height: root.geometry.agentTitleRow
        visible: !root.drawn && root.elements.agent_title === undefined
        text: root.record.title
        color: root.resting ? root.colors.subtext0 : root.colors.chromeText
        pixelSize: root.typography.body
        emphasized: true
    }

    // The second row: what the agent asks, why it failed, the plan step or event it works on or its
    // last answer; for a process, its command. What that left closes the row on the right.
    Item {
        id: detailRow
        x: root.geometry.textInset
        y: root.geometry.agentDetailY
        width: root.rowWidth
        height: root.geometry.agentDetailRow
        visible: !root.drawn

        ChromeText {
            objectName: "agentSignal"
            width: Math.max(0, detailRow.width - (outcome.width > 0 ? outcome.width + root.geometry.gap : 0))
            height: detailRow.height
            text: root.happening
            color: root.process ? root.colors.subtext0 : root.colors[root.record.signalColor]
            pixelSize: root.typography.small
        }

        // A plan's count, the ports a program listens on, or how its last command ended.
        Row {
            id: outcome
            objectName: "agentOutcome"
            readonly property string ports: root.record.ports ?? ""
            readonly property bool finished: root.process && ports.length === 0 && (root.record.commandState ?? "") === "finished"
            readonly property bool coded: finished && root.record.exitCode !== undefined && root.record.exitCode !== null
            readonly property bool failed: coded && root.record.exitCode !== 0
            x: detailRow.width - width
            height: detailRow.height
            spacing: root.geometry.gap
            clip: true

            ChromeText {
                objectName: "agentPlanCount"
                width: Math.ceil(implicitWidth)
                height: outcome.height
                text: root.record.planDone + "/" + root.record.planTotal
                color: root.colors.teal
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: !root.process && (root.record.showPlan ?? false)
            }

            // Each port as the terminal writes it, `:3000`, the colon receding; `+2` counts the rest.
            Repeater {
                model: outcome.ports.length > 0 ? outcome.ports.split(" ") : []

                delegate: Row {
                    id: port
                    objectName: "processPort"
                    required property string modelData
                    readonly property bool listed: modelData.startsWith(":")
                    height: outcome.height

                    Address {
                        text: ":"
                        color: root.colors.subtext0
                        visible: port.listed
                    }

                    Address {
                        text: port.listed ? port.modelData.slice(1) : port.modelData
                        color: port.listed ? root.colors.chromeText : root.colors.subtext0
                    }
                }
            }

            ChromeIcon {
                objectName: "processResultGlyph"
                width: root.geometry.projectSide
                height: outcome.height
                glyph: outcome.failed ? "✕" : "✓"
                color: outcome.failed ? root.colors.red : root.colors.green
                pixelSize: root.geometry.projectSide
                primaryFamily: root.typography.primaryFamily ?? ""
                primaryStyle: root.typography.primaryStyle ?? ""
                visible: outcome.coded
            }

            ChromeText {
                objectName: "processResult"
                width: Math.ceil(implicitWidth)
                height: outcome.height
                text: outcome.failed ? String(root.record.exitCode) : (root.record.commandDuration ?? "")
                color: outcome.failed ? root.colors.red : outcome.coded ? root.colors.green : root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: outcome.finished && text.length > 0
            }
        }
    }

    // The third row: where it works. Its project, tab and directory with the branch at the end, or
    // a worktree's facts, which give way one by one (commits ahead, the branch, the files, the
    // command's outcome) while the row runs short.
    Item {
        id: context
        objectName: "agentContext"
        readonly property bool task: root.record.task ?? false
        readonly property real space: root.geometry.gap
        readonly property real machineWidth: task ? piece(machine.text, machine.implicitWidth) : 0
        readonly property real branchWidth: task && branchLabel.text.length > 0 ? root.geometry.projectSide + root.geometry.projectLabelGap + Math.ceil(branchLabel.implicitWidth) : 0
        readonly property real diffWidth: task && added.text.length > 0 ? Math.ceil(added.implicitWidth) + root.geometry.projectLabelGap + Math.ceil(removed.implicitWidth) : 0
        readonly property real filesWidth: task ? piece(files.text, files.implicitWidth) : 0
        readonly property real aheadWidth: task ? piece(ahead.text, ahead.implicitWidth) : 0
        readonly property real commandWidth: task ? piece(command.text, command.implicitWidth) : 0
        // A worktree on this machine, named after its branch and without changes, tells nothing.
        readonly property bool factual: machineWidth + branchWidth + diffWidth + filesWidth + aheadWidth + commandWidth > 0
        readonly property bool showsAhead: fits([machineWidth, branchWidth, diffWidth, filesWidth, aheadWidth, commandWidth])
        readonly property bool showsBranch: fits([machineWidth, branchWidth, diffWidth, filesWidth, commandWidth])
        readonly property bool showsFiles: fits([machineWidth, diffWidth, filesWidth, commandWidth])
        readonly property bool showsCommand: fits([machineWidth, diffWidth, commandWidth])
        x: root.geometry.textInset
        y: root.geometry.agentWhereY
        width: root.rowWidth
        height: root.geometry.agentDetailRow
        visible: !root.drawn && root.elements.agent_project === undefined
        clip: true

        function piece(text, natural) {
            return text.length > 0 ? Math.ceil(natural) : 0;
        }

        function fits(widths) {
            const shown = widths.filter(width => width > 0);

            return shown.reduce((total, width) => total + width, 0) + context.space * Math.max(0, shown.length - 1) <= context.width;
        }

        ChromeText {
            id: project
            objectName: "agentProjectLabel"
            width: Math.max(0, context.width - (revision.width > 0 ? revision.width + root.geometry.gap : 0))
            height: parent.height
            text: root.place
            color: root.colors.subtext0
            pixelSize: root.typography.small
            visible: !context.factual
        }

        // The branch of the directory, and a dot while it has changes.
        Item {
            id: revision
            objectName: "agentBranch"
            readonly property string name: root.record.branch ?? ""
            readonly property real dot: (root.record.dirty ?? false) ? Math.round(5 * root.ratio) : 0
            readonly property real natural: root.geometry.projectSide + root.geometry.projectLabelGap + Math.ceil(revisionLabel.implicitWidth) + (dot > 0 ? root.geometry.projectLabelGap + dot : 0)
            x: context.width - width
            width: name.length > 0 && !context.factual ? Math.min(natural, context.width * 0.45) : 0
            height: parent.height
            visible: width > 0
            clip: true

            ProviderMark {
                y: (parent.height - height) / 2
                width: root.geometry.projectSide
                height: root.geometry.projectSide
                symbol: "git-branch"
                color: root.colors.subtext0
            }

            ChromeText {
                id: revisionLabel
                objectName: "agentBranchLabel"
                x: root.geometry.projectSide + root.geometry.projectLabelGap
                width: Math.max(0, revision.width - x - (revision.dot > 0 ? root.geometry.projectLabelGap + revision.dot : 0))
                height: parent.height
                text: revision.name
                color: root.colors.subtext0
                pixelSize: root.typography.small
            }

            NativeRoundedRectangle {
                objectName: "agentBranchDirty"
                x: revision.width - width
                y: (parent.height - height) / 2
                width: revision.dot
                height: width
                radius: width / 2
                color: root.colors.subtext0
                visible: revision.dot > 0
            }
        }

        Row {
            id: facts
            objectName: "agentFacts"
            height: parent.height
            spacing: context.space
            visible: context.factual

            ChromeText {
                id: machine
                objectName: "agentFactsMachine"
                width: Math.ceil(implicitWidth)
                height: facts.height
                text: root.record.machine ?? ""
                color: root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: context.machineWidth > 0
            }

            Item {
                objectName: "agentFactsBranch"
                width: context.branchWidth
                height: facts.height
                visible: context.branchWidth > 0 && context.showsBranch

                ProviderMark {
                    objectName: "agentFactsBranchIcon"
                    y: (parent.height - height) / 2
                    width: root.geometry.projectSide
                    height: root.geometry.projectSide
                    symbol: "git-branch"
                    color: root.colors.subtext0
                }

                ChromeText {
                    id: branchLabel
                    objectName: "agentFactsBranchLabel"
                    x: root.geometry.projectSide + root.geometry.projectLabelGap
                    width: Math.ceil(implicitWidth)
                    height: parent.height
                    text: root.record.taskBranch ?? ""
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                }
            }

            Item {
                objectName: "agentFactsDiff"
                width: context.diffWidth
                height: facts.height
                visible: context.diffWidth > 0

                ChromeText {
                    id: added
                    objectName: "agentFactsAdded"
                    width: Math.ceil(implicitWidth)
                    height: parent.height
                    text: root.record.diffAdded ?? ""
                    color: root.colors.green
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                }

                ChromeText {
                    id: removed
                    objectName: "agentFactsRemoved"
                    x: added.width + root.geometry.projectLabelGap
                    width: Math.ceil(implicitWidth)
                    height: parent.height
                    text: root.record.diffRemoved ?? ""
                    color: root.colors.red
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                }
            }

            ChromeText {
                id: files
                objectName: "agentFactsFiles"
                width: Math.ceil(implicitWidth)
                height: facts.height
                text: root.record.diffFiles ?? ""
                color: root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: context.filesWidth > 0 && context.showsFiles
            }

            ChromeText {
                id: ahead
                objectName: "agentFactsAhead"
                width: Math.ceil(implicitWidth)
                height: facts.height
                text: root.record.commitsAhead ?? ""
                color: root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: context.aheadWidth > 0 && context.showsAhead
            }

            ChromeText {
                id: command
                objectName: "agentFactsCommand"
                width: Math.ceil(implicitWidth)
                height: facts.height
                text: root.record.commandResult ?? ""
                color: root.colors.subtext0
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: context.commandWidth > 0 && context.showsCommand
            }
        }
    }

    // The plan's progress, under the rows.
    NativeRoundedRectangle {
        objectName: "agentPlanBar"
        x: root.geometry.textInset
        y: root.height - (root.geometry.padding + height) / 2
        width: root.rowWidth
        height: root.geometry.planBarHeight
        radius: height / 2
        color: root.colors.surface1
        visible: !root.drawn && (root.record.showPlan ?? false)

        NativeRoundedRectangle {
            objectName: "agentPlanProgress"
            width: parent.width * Math.min(1, (root.record.planDone ?? 0) / Math.max(1, root.record.planTotal ?? 0))
            height: parent.height
            radius: parent.radius
            color: root.colors.teal
        }
    }

    // A mod piece takes the place of the default piece it names.
    Repeater {
        model: root.drawn ? [] : [
            {slot: "agent_mark", x: root.geometry.padding, y: root.geometry.padding, width: root.geometry.markColumn, height: root.geometry.agentTitleRow},
            {slot: "agent_title", x: root.geometry.textInset, y: root.geometry.padding, width: root.titleWidth, height: root.geometry.agentTitleRow},
            {slot: "agent_status", x: status.x, y: status.y, width: status.width, height: status.height},
            {slot: "agent_project", x: context.x, y: context.y, width: context.width, height: context.height},
        ].filter(piece => root.elements[piece.slot] !== undefined)

        delegate: ElementHost {
            required property var modelData
            x: modelData.x
            y: modelData.y
            width: modelData.width
            height: modelData.height
            content: root.elements[modelData.slot]
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
            onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
            builtins: root.builtins
        }
    }

    ElementHost {
        objectName: "agentCardElements"
        anchors.fill: parent
        visible: root.drawn
        content: root.elements.agent_card ?? null
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        onElementActivated: (slot, key, revision, element) => root.elementActivated(slot, key, revision, element)
        builtins: root.builtins
    }

    Component {
        id: markPiece
        ApplicationTile {
            implicitWidth: root.geometry.tileWidth
            implicitHeight: root.geometry.tileHeight
            radius: ChromeStyle.smallRadius * root.ratio
            mark: root.record
            colors: root.colors
            typography: root.typography
            ratio: root.ratio
        }
    }

    Component {
        id: titlePiece
        ChromeText {
            implicitHeight: root.geometry.agentTitleRow
            text: root.record.title
            color: root.colors.chromeText
            pixelSize: root.typography.body
            emphasized: true
        }
    }

    Component {
        id: projectPiece
        ChromeText {
            implicitHeight: root.geometry.agentDetailRow
            text: root.record.project
            color: root.colors.subtext0
            pixelSize: root.typography.small
        }
    }

    Component {
        id: statusPiece
        AgentStatus {
            // Its label shortens to fit, so it asks for half a card and takes what it gets.
            implicitWidth: root.geometry.width / 2
            implicitHeight: root.geometry.agentTitleRow
            record: root.record
            colors: root.colors
            typography: root.typography
            running: root.animate
        }
    }

    Accessible.name: [record.title, status.statusText, happening, record.ports ?? "", context.factual ? [record.machine, record.taskBranch, record.diffAdded, record.diffRemoved, record.diffFiles, record.commitsAhead, record.commandResult].join(" ") : [place, record.branch ?? ""].join(" ")].filter(part => part.length > 0).join(" ")
}
