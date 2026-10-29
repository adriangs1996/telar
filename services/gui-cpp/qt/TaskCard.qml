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
            Item {
                id: contextRow
                x: root.geometry.context.x
                y: root.geometry.context.y
                width: Math.max(0, parent.width - 2 * x)
                height: root.geometry.context.height

                AgentStatus {
                    id: status
                    objectName: "agentStatus"
                    width: parent.width
                    height: parent.height
                    record: root.record
                    colors: root.colors
                    typography: root.typography
                    geometry: root.geometry
                    pulseAlpha: root.pulseAlpha
                    running: root.animate
                }

                ChromeText {
                    objectName: "taskFacts"
                    width: Math.max(0, parent.width - status.usedWidth - root.geometry.gap)
                    height: parent.height
                    text: root.record.facts
                    color: root.colors.subtext0
                    pixelSize: root.typography.small
                }
            }

            ChromeText {
                objectName: "taskTitle"
                x: root.geometry.title.x
                y: root.geometry.title.y
                width: Math.max(0, parent.width - 2 * x)
                height: root.geometry.title.height
                text: root.record.title
                color: root.colors.text
                pixelSize: root.typography.title
                emphasized: true
            }

            Item {
                x: root.geometry.detail.x
                y: root.geometry.detail.y
                width: Math.max(0, parent.width - 2 * x)
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
            readonly property string rightText: !root.record.enabled ? root.record.machine + " · offline" : root.record.machine.length > 0 ? root.record.machine + " · " + clock.statusText : "\u2387 " + root.record.taskHandle + "  " + clock.statusText

            NativeAgentStatus {
                id: clock
                objectName: "agentStatus"
                x: root.geometry.context.x
                y: root.geometry.compactPadding
                width: Math.max(0, parent.width - 2 * x)
                height: root.geometry.title.height
                record: root.record
                displayMode: NativeAgentStatus.DisplayMode.compact
                running: root.animate

                NativeChromeText {
                    id: rightMeasure
                    text: compactBody.rightText
                    pixelSize: root.typography.small
                    visible: false
                }

                ChromeIcon {
                    objectName: "taskCompactGlyph"
                    width: root.geometry.projectSide
                    height: parent.height
                    glyph: root.record.compactGlyph
                    color: root.colors[root.record.statusColor]
                    pixelSize: root.typography.small
                    primaryFamily: root.typography.primaryFamily ?? ""
                    primaryStyle: root.typography.primaryStyle ?? ""
                    opacity: root.record.working ? (root.pulseAlpha ?? clock.animatedAlpha) : 1
                }

                ChromeText {
                    id: rightLabel
                    objectName: "taskCompactStatus"
                    x: parent.width - width
                    width: Math.min(parent.width / 2, rightMeasure.implicitWidth)
                    height: parent.height
                    text: compactBody.rightText
                    color: root.colors.overlay1
                    pixelSize: root.typography.small
                }

                ChromeText {
                    objectName: "taskCompactTitle"
                    x: root.geometry.projectSide + root.geometry.gap
                    width: Math.max(0, parent.width - rightLabel.width - root.geometry.gap - x)
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
