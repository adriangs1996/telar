pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

ActivityFrame {
    id: root

    required property var typography

    Loader {
        id: body
        anchors.fill: parent
        sourceComponent: root.record.compact ? compactCard : fullCard
    }

    Component {
        id: fullCard

        Item {
            id: fullBody
            // Title first, then the facts, then the activity: the rows keep the card's height.
            readonly property real factsY: root.geometry.context.y + root.geometry.title.height + (root.geometry.detail.y - root.geometry.title.y - root.geometry.title.height)
            readonly property real textWidth: Math.max(0, width - root.textX - root.geometry.context.x)

            NativeAgentStatus {
                id: status
                objectName: "agentStatus"
                x: root.geometry.context.x
                y: root.geometry.context.y
                width: Math.max(0, parent.width - 2 * x)
                height: root.geometry.title.height
                record: root.record
                running: root.animate

                NativeChromeText {
                    id: statusMeasure
                    text: status.statusText
                    pixelSize: root.typography.small
                    visible: false
                }

                ChromeIcon {
                    objectName: "taskStatusGlyph"
                    width: root.glyphColumn
                    height: parent.height
                    glyph: root.record.compactGlyph
                    color: root.colors[root.record.statusColor]
                    pixelSize: root.typography.small
                    primaryFamily: root.typography.primaryFamily ?? ""
                    primaryStyle: root.typography.primaryStyle ?? ""
                    opacity: root.record.working ? (root.pulseAlpha ?? status.animatedAlpha) : 1
                }

                ChromeText {
                    id: statusLabel
                    objectName: "taskStatus"
                    x: parent.width - width
                    width: Math.min(parent.width / 2, Math.ceil(statusMeasure.implicitWidth))
                    height: parent.height
                    text: status.statusText
                    color: root.colors[root.record.statusColor]
                    pixelSize: root.typography.small
                }

                // Lighter than the agent's title above it: body size in the regular face.
                ChromeText {
                    objectName: "taskTitle"
                    x: root.glyphColumn + root.geometry.gap
                    width: Math.max(0, parent.width - x - statusLabel.width - root.geometry.gap)
                    height: parent.height
                    text: root.record.title
                    color: root.record.dim ? root.colors.overlay1 : root.colors.text
                    pixelSize: root.typography.body
                }
            }

            Item {
                id: factsRow
                objectName: "taskFacts"
                readonly property real iconSide: root.geometry.projectSide
                readonly property real pieceGap: root.geometry.projectLabelGap
                readonly property real diffWidth: added.visible ? root.geometry.gap + added.width + pieceGap + removed.width : 0
                readonly property real tailWidth: tail.visible ? (added.visible ? pieceGap : root.geometry.gap) + Math.ceil(tail.implicitWidth) : 0
                x: root.textX
                y: fullBody.factsY
                width: fullBody.textWidth
                height: root.geometry.context.height
                clip: true

                ChromeText {
                    id: lead
                    objectName: "taskFactsLead"
                    width: text.length > 0 ? Math.min(Math.ceil(implicitWidth), parent.width / 2) : 0
                    height: parent.height
                    text: root.record.factsLead
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    visible: width > 0
                }

                ProviderMark {
                    id: branch
                    objectName: "taskBranchIcon"
                    x: lead.width
                    y: (parent.height - height) / 2
                    width: factsRow.iconSide
                    height: factsRow.iconSide
                    symbol: "git-branch"
                    color: root.colors.subtext0
                }

                // The branch gives way first; the diff and what follows it keep their room.
                ChromeText {
                    id: handle
                    objectName: "taskHandle"
                    x: branch.x + branch.width + factsRow.pieceGap
                    width: Math.max(0, Math.min(Math.ceil(implicitWidth), parent.width - x - factsRow.diffWidth - factsRow.tailWidth))
                    height: parent.height
                    text: root.record.taskHandle
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                }

                ChromeText {
                    id: added
                    objectName: "taskAdded"
                    x: handle.x + handle.width + root.geometry.gap
                    width: Math.ceil(implicitWidth)
                    height: parent.height
                    text: root.record.diffAdded
                    color: root.colors.green
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                    visible: text.length > 0
                }

                ChromeText {
                    id: removed
                    objectName: "taskRemoved"
                    x: added.x + added.width + factsRow.pieceGap
                    width: Math.ceil(implicitWidth)
                    height: parent.height
                    text: root.record.diffRemoved
                    color: root.colors.red
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                    visible: added.visible
                }

                ChromeText {
                    id: tail
                    objectName: "taskFactsTail"
                    x: added.visible ? removed.x + removed.width + factsRow.pieceGap : handle.x + handle.width + root.geometry.gap
                    width: Math.max(0, parent.width - x)
                    height: parent.height
                    text: root.record.factsTail
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                    visible: text.length > 0
                }
            }

            Item {
                x: root.textX
                y: root.geometry.detail.y
                width: fullBody.textWidth
                height: root.geometry.detail.height

                TaskPlan {
                    id: plan
                    objectName: "taskPlan"
                    width: implicitWidth
                    height: parent.height
                    record: root.record
                    colors: root.colors
                    typography: root.typography
                    geometry: root.geometry
                    visible: root.record.showPlan
                }

                ChromeText {
                    objectName: "taskActivity"
                    x: plan.visible ? plan.width : 0
                    width: Math.max(0, parent.width - x)
                    height: parent.height
                    text: root.record.activity
                    color: root.colors[root.record.activityColor]
                    pixelSize: root.typography.small
                }
            }
        }
    }

    Component {
        id: compactCard

        Item {
            id: compactBody
            // Where the task runs: its machine when it is another one, otherwise its branch.
            readonly property bool branched: root.record.machine.length === 0
            readonly property string place: branched ? root.record.taskHandle : root.record.machine
            readonly property string state: root.record.enabled ? clock.statusText : "offline"

            NativeAgentStatus {
                id: clock
                objectName: "agentStatus"
                // The title takes the room it needs first and the place what is left; the state is never cut.
                readonly property real titleX: root.glyphColumn + root.geometry.gap
                readonly property real room: Math.max(0, width - titleX - stateLabel.width - root.geometry.gap)
                readonly property real titleWidth: Math.min(Math.ceil(titleMeasure.implicitWidth), room)
                readonly property real iconWidth: compactBody.branched ? root.geometry.projectSide + root.geometry.projectLabelGap : 0
                readonly property real placeRoom: room - titleWidth - root.geometry.gap - iconWidth
                readonly property bool placed: compactBody.place.length > 0 && placeRoom >= root.geometry.minimumProjectLabel
                readonly property real placeWidth: placed ? Math.min(Math.ceil(placeMeasure.implicitWidth), placeRoom) : 0
                x: root.geometry.context.x
                y: root.geometry.compactPadding
                width: Math.max(0, parent.width - 2 * x)
                height: root.geometry.title.height
                record: root.record
                displayMode: NativeAgentStatus.DisplayMode.compact
                running: root.animate

                NativeChromeText {
                    id: stateMeasure
                    text: compactBody.state
                    pixelSize: root.typography.small
                    visible: false
                }

                NativeChromeText {
                    id: titleMeasure
                    text: root.record.title
                    pixelSize: root.typography.body
                    visible: false
                }

                NativeChromeText {
                    id: placeMeasure
                    text: compactBody.place
                    pixelSize: root.typography.small
                    visible: false
                }

                ChromeIcon {
                    objectName: "taskCompactGlyph"
                    width: root.glyphColumn
                    height: parent.height
                    glyph: root.record.compactGlyph
                    color: root.colors[root.record.statusColor]
                    pixelSize: root.typography.small
                    primaryFamily: root.typography.primaryFamily ?? ""
                    primaryStyle: root.typography.primaryStyle ?? ""
                    opacity: root.record.working ? (root.pulseAlpha ?? clock.animatedAlpha) : 1
                }

                ChromeText {
                    id: stateLabel
                    objectName: "taskCompactStatus"
                    x: parent.width - width
                    width: Math.min(parent.width, Math.ceil(stateMeasure.implicitWidth))
                    height: parent.height
                    text: compactBody.state
                    color: root.colors.overlay1
                    pixelSize: root.typography.small
                    elide: Text.ElideNone
                }

                ChromeText {
                    id: placeLabel
                    objectName: "taskCompactPlace"
                    x: stateLabel.x - root.geometry.gap - width
                    width: clock.placeWidth
                    height: parent.height
                    text: compactBody.place
                    color: root.colors.overlay1
                    pixelSize: root.typography.small
                    visible: clock.placed
                }

                ProviderMark {
                    objectName: "taskCompactBranchIcon"
                    x: placeLabel.x - clock.iconWidth
                    y: (parent.height - height) / 2
                    width: root.geometry.projectSide
                    height: root.geometry.projectSide
                    symbol: "git-branch"
                    color: root.colors.overlay1
                    visible: clock.placed && compactBody.branched
                }

                ChromeText {
                    objectName: "taskCompactTitle"
                    x: clock.titleX
                    width: clock.placed ? clock.titleWidth : clock.room
                    height: parent.height
                    text: root.record.title
                    color: root.record.dim ? root.colors.overlay1 : root.colors.text
                    pixelSize: root.typography.body
                }
            }
        }
    }

    Accessible.name: record.title + " " + record.facts + " " + record.status + " " + record.activity
}
