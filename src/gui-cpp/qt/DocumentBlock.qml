import QtQuick
import Telar.Gui

// One block of a document (`telar render`) as DocumentView and InlineDocuments draw it: its
// quote bars, callout title and list marker, then its paragraph, heading, code, rule or table.
Item {
    id: block
    required property var modelData
    required property int index
    required property DocumentTheme theme
    // The NativeDocument the block comes from, which opens its links.
    required property var document
    // Where lines start, and how long they run at most.
    property real inset: 0
    property real measure: width

    readonly property bool first: index === 0
    readonly property real gap: first ? 0 : modelData.tight ? block.theme.bodySize * 0.25 : modelData.kind === "heading" ? block.theme.bodySize * (modelData.level <= 2 ? 1.6 : 1.1) : block.theme.bodySize * 0.8
    readonly property real lead: modelData.quote * block.theme.quoteStep + modelData.list * block.theme.indentStep
    readonly property real titleHeight: modelData.opensCallout ? title.implicitHeight + block.theme.bodySize * 0.3 : 0

    height: gap + block.titleHeight + content.height

    Repeater {
        model: block.modelData.quote
        Rectangle {
            required property int index
            x: block.inset + index * block.theme.quoteStep
            y: block.first || block.modelData.opensCallout && index === block.modelData.quote - 1 ? block.gap : 0
            width: Math.max(2, 3 * block.theme.ratio)
            height: block.height - y
            radius: width / 2
            color: index === block.modelData.quote - 1 && block.modelData.callout ? block.theme.calloutColor(block.modelData.callout) : block.theme.colorOf("border", "#5b6078")
        }
    }

    Text {
        id: title
        visible: block.modelData.opensCallout
        x: block.inset + block.modelData.quote * block.theme.quoteStep
        y: block.gap
        text: block.modelData.calloutTitle
        color: block.theme.calloutColor(block.modelData.callout)
        font.family: block.theme.bodyFamily
        font.pixelSize: block.theme.bodySize
        font.weight: Font.DemiBold
    }

    Text {
        visible: block.modelData.marker.length > 0
        x: block.inset + block.lead - width - block.theme.bodySize * 0.45
        y: block.gap + block.titleHeight + (block.modelData.kind === "heading" ? (content.height - implicitHeight) / 2 : 0)
        text: block.modelData.marker
        color: block.theme.colorOf("muted", "#a5adcb")
        font.family: block.theme.bodyFamily
        font.pixelSize: block.theme.bodySize
    }

    Loader {
        id: content
        x: block.inset + block.lead
        y: block.gap + block.titleHeight
        width: Math.max(block.theme.bodySize * 4, block.measure - block.lead)
        sourceComponent: {
            switch (block.modelData.kind) {
            case "heading":
            case "paragraph": return prose;
            case "code":
            case "html": return verbatim;
            case "rule": return rule;
            case "table": return table;
            }
            return null;
        }

        Component {
            id: prose
            Text {
                width: content.width
                wrapMode: Text.Wrap
                textFormat: Text.RichText
                text: block.modelData.html
                color: block.theme.colorOf("foreground", "#cad3f5")
                linkColor: block.theme.colorOf("accent", "#8aadf4")
                font.family: block.theme.bodyFamily
                font.pixelSize: block.modelData.kind === "heading" ? block.theme.headingSize(block.modelData.level) : block.theme.bodySize
                font.weight: block.modelData.kind === "heading" ? Font.DemiBold : Font.Normal
                lineHeight: block.modelData.kind === "heading" ? 1.15 : 1.35
                onLinkActivated: link => block.document.openLink(link)

                HoverHandler {
                    cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                }

                Rectangle {
                    visible: block.modelData.kind === "heading" && block.modelData.level <= 2
                    anchors.top: parent.bottom
                    anchors.topMargin: block.theme.bodySize * 0.35
                    width: parent.width
                    height: 1
                    color: block.theme.colorOf("border", "#5b6078")
                }
            }
        }

        Component {
            id: verbatim
            Rectangle {
                readonly property real labelHeight: label.visible ? label.implicitHeight + block.theme.bodySize * 0.2 : 0
                width: content.width
                height: code.implicitHeight + labelHeight + block.theme.bodySize * 1.2
                radius: block.theme.bodySize * 0.4
                color: block.theme.colorOf("surface", "#363a4f")

                Text {
                    id: label
                    visible: block.modelData.info.length > 0
                    x: block.theme.bodySize * 0.8
                    y: block.theme.bodySize * 0.5
                    text: block.modelData.info
                    textFormat: Text.PlainText
                    color: block.theme.colorOf("muted", "#a5adcb")
                    font.family: block.theme.bodyFamily
                    font.pixelSize: block.theme.bodySize * 0.8
                }

                Text {
                    id: code
                    x: block.theme.bodySize * 0.8
                    y: block.theme.bodySize * 0.6 + parent.labelHeight
                    width: parent.width - block.theme.bodySize * 1.6
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                    text: block.modelData.text
                    color: block.modelData.kind === "html" ? block.theme.colorOf("muted", "#a5adcb") : block.theme.colorOf("foreground", "#cad3f5")
                    font.family: block.theme.monoFamily
                    font.pixelSize: block.theme.bodySize * 0.9
                }
            }
        }

        Component {
            id: rule
            Item {
                width: content.width
                height: block.theme.bodySize * 0.8
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: Math.max(1, block.theme.ratio)
                    color: block.theme.colorOf("border", "#5b6078")
                }
            }
        }

        Component {
            id: table
            Rectangle {
                id: frame
                width: content.width
                height: rows.height
                radius: block.theme.bodySize * 0.3
                color: "transparent"
                border.width: 1
                border.color: block.theme.colorOf("border", "#5b6078")
                readonly property real cellWidth: width / Math.max(1, block.modelData.columns)

                Column {
                    id: rows
                    width: parent.width

                    Repeater {
                        model: block.modelData.rows
                        Rectangle {
                            id: row
                            required property var modelData
                            required property int index
                            width: rows.width
                            height: cells.height
                            color: index === 0 ? block.theme.colorOf("surface", "#363a4f") : "transparent"

                            Row {
                                id: cells
                                Repeater {
                                    model: row.modelData
                                    Item {
                                        required property var modelData
                                        width: frame.cellWidth
                                        height: cell.implicitHeight + block.theme.bodySize * 0.8
                                        Text {
                                            id: cell
                                            x: block.theme.bodySize * 0.6
                                            y: block.theme.bodySize * 0.4
                                            width: parent.width - block.theme.bodySize * 1.2
                                            wrapMode: Text.Wrap
                                            textFormat: Text.RichText
                                            text: row.index === 0 ? "<b>" + modelData.html + "</b>" : modelData.html
                                            horizontalAlignment: modelData.align === "right" ? Text.AlignRight : modelData.align === "center" ? Text.AlignHCenter : Text.AlignLeft
                                            color: block.theme.colorOf("foreground", "#cad3f5")
                                            linkColor: block.theme.colorOf("accent", "#8aadf4")
                                            font.family: block.theme.bodyFamily
                                            font.pixelSize: block.theme.bodySize * 0.95
                                            onLinkActivated: link => block.document.openLink(link)
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                visible: row.index > 0
                                width: parent.width
                                height: 1
                                color: block.theme.colorOf("border", "#5b6078")
                            }
                        }
                    }
                }
            }
        }
    }
}
