pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// One shape for every agent, in a worktree or not: the title row names it and says its state, the
// second row says what matters in that state on the left and where it works on the right.
ActivityFrame {
    id: root

    required property var typography
    // Mod content for this card and its pieces, by slot name.
    readonly property var elements: record.elements ?? ({})
    readonly property bool drawn: elements.agent_card !== undefined
    readonly property var builtins: ({agent_mark: markPiece, agent_title: titlePiece, agent_project: projectPiece, agent_status: statusPiece})
    readonly property real rowWidth: Math.max(0, width - geometry.textInset - geometry.padding)
    // The title takes what the state, and a process's ports, leave of its row.
    readonly property real titleWidth: Math.max(0, rowWidth - (status.visible ? status.usedWidth + (status.usedWidth > 0 ? geometry.gap : 0) : rowWidth / 2 + geometry.gap) - portChip.reserved)
    readonly property real contextRoom: rowWidth * (record.contextShare ?? 1)
    // A click on an element a mod drew in a card; the window runs it.
    signal elementActivated(string slot, string key, string revision, int element)

    implicitHeight: geometry.agentHeight

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

    // A process card's listening ports, before its state.
    NativeRoundedRectangle {
        id: portChip
        objectName: "processPorts"
        readonly property bool shown: !root.drawn && (root.record.ports ?? "").length > 0
        readonly property real reserved: shown ? width + root.geometry.gap : 0
        x: root.geometry.textInset + root.rowWidth - (status.visible ? status.usedWidth + root.geometry.gap : root.rowWidth / 2) - width
        y: root.geometry.padding + (root.geometry.agentTitleRow - height) / 2
        width: portLabel.implicitWidth + 8 * root.ratio
        height: Math.round(root.geometry.agentTitleRow * 0.8)
        radius: height / 2
        color: Qt.alpha(root.colors.green, 0.16)
        visible: shown

        ChromeText {
            id: portLabel
            anchors.centerIn: parent
            width: implicitWidth
            height: parent.height
            text: root.record.ports ?? ""
            color: root.colors.green
            pixelSize: root.typography.small
            elide: Text.ElideNone
        }
    }

    ChromeText {
        objectName: "agentTitleLabel"
        x: root.geometry.textInset
        y: root.geometry.padding
        width: root.titleWidth
        height: root.geometry.agentTitleRow
        visible: !root.drawn && root.elements.agent_title === undefined
        text: root.record.title
        color: root.record.dim ? root.colors.overlay1 : root.colors.chromeText
        pixelSize: root.typography.body
        emphasized: true
    }

    Item {
        id: detailRow
        x: root.geometry.textInset
        y: root.geometry.agentDetailY
        width: root.rowWidth
        height: root.geometry.agentDetailRow
        visible: !root.drawn

        // What the agent asks, why it failed, the plan step or event it works on, or its last answer.
        Item {
            id: signalRow
            width: Math.max(0, detailRow.width - (context.width > 0 ? context.width + root.geometry.gap : 0))
            height: detailRow.height

            ChromeText {
                id: planCount
                objectName: "agentPlanCount"
                width: visible ? Math.min(signalRow.width, Math.ceil(implicitWidth)) : 0
                height: signalRow.height
                text: root.record.planDone + "/" + root.record.planTotal
                color: root.colors.teal
                pixelSize: root.typography.small
                elide: Text.ElideNone
                visible: root.record.showPlan
            }

            ChromeText {
                objectName: "agentSignal"
                x: planCount.visible ? planCount.width + root.geometry.projectLabelGap : 0
                width: Math.max(0, signalRow.width - x)
                height: signalRow.height
                text: root.record.signal
                color: root.colors[root.record.signalColor]
                pixelSize: root.typography.small
            }
        }

        // Where the agent works: its worktree's facts, which give way one by one (commits ahead, the
        // branch, the files, the command's outcome) while the row runs short, or its project when
        // it has no worktree or its worktree has nothing to tell.
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
            x: detailRow.width - width
            width: Math.min(root.contextRoom, factual ? facts.implicitWidth : Math.ceil(project.implicitWidth))
            height: detailRow.height
            visible: root.elements.agent_project === undefined
            clip: true

            function piece(text, natural) {
                return text.length > 0 ? Math.ceil(natural) : 0;
            }

            function fits(widths) {
                const shown = widths.filter(width => width > 0);

                return shown.reduce((total, width) => total + width, 0) + context.space * Math.max(0, shown.length - 1) <= root.contextRoom;
            }

            ChromeText {
                id: project
                objectName: "agentProjectLabel"
                width: parent.width
                height: parent.height
                text: root.record.project
                color: root.colors.overlay1
                pixelSize: root.typography.small
                visible: !context.factual
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
                    color: root.colors.overlay1
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
                        color: root.colors.overlay1
                    }

                    ChromeText {
                        id: branchLabel
                        objectName: "agentFactsBranchLabel"
                        x: root.geometry.projectSide + root.geometry.projectLabelGap
                        width: Math.ceil(implicitWidth)
                        height: parent.height
                        text: root.record.taskBranch ?? ""
                        color: root.colors.overlay1
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
                    color: root.colors.overlay1
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
                    color: root.colors.overlay1
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
                    color: root.colors.overlay1
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                    visible: context.commandWidth > 0 && context.showsCommand
                }
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
        visible: !root.drawn && root.record.showPlan

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
            {slot: "agent_project", x: detailRow.x + detailRow.width - root.contextRoom, y: detailRow.y, width: root.contextRoom, height: detailRow.height},
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

    Accessible.name: [record.title, record.ports ?? "", status.statusText, record.signal, context.factual ? [record.machine, record.taskBranch, record.diffAdded, record.diffRemoved, record.diffFiles, record.commitsAhead, record.commandResult].join(" ") : record.project].filter(part => part.length > 0).join(" ")
}
