pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Telar.Gui

NotificationLayout {
    id: root

    required property var colors

    component NotificationButton: AbstractButton {
        signal activated

        hoverEnabled: true
        focusPolicy: Qt.StrongFocus
        padding: 0
        onPressed: activated()
        Keys.onReturnPressed: activated()
        Keys.onEnterPressed: activated()
    }

    Item {
        x: root.host.x
        y: root.host.y
        width: root.host.width
        height: root.host.height
        clip: true

        Repeater {
            model: root.cards

            Item {
                id: card
                objectName: "notificationCard"

                required property var record
                readonly property color accent: root.colors[record.accent]

                x: record.bounds.x - root.host.x
                y: record.bounds.y - root.host.y
                width: record.bounds.width
                height: record.bounds.height
                opacity: record.opacity

                Repeater {
                    model: card.record.shadows

                    NativeRoundedRectangle {
                        required property var modelData
                        x: modelData.bounds.x
                        y: modelData.bounds.y
                        width: modelData.bounds.width
                        height: modelData.bounds.height
                        radius: modelData.radius
                        color: Qt.rgba(0, 0, 0, root.style.shadowAlpha)
                    }
                }

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: root.style.radius
                    color: root.colors.surface0
                }

                NativeRoundedRectangle {
                    anchors.fill: parent
                    radius: root.style.radius
                    color: "transparent"
                    borderColor: Qt.alpha(root.colors.overlay0, root.style.borderAlpha)
                    borderWidth: root.style.borderWidth
                }

                NotificationButton {
                    id: bodyControl
                    objectName: "notificationBody"

                    anchors.fill: parent
                    enabled: card.record.enabled
                    background: null
                    contentItem: null
                    KeyNavigation.tab: closeControl
                    Accessible.name: card.record.accessible
                    onActivated: {
                        if (card.record.clickable) {
                            root.controller.activateNotification(card.record.key);
                        } else {
                            root.controller.dismissNotification(card.record.key);
                        }
                    }
                }

                NativeRoundedRectangle {
                    objectName: "notificationBodyFocus"
                    anchors.fill: parent
                    visible: bodyControl.activeFocus
                    radius: root.style.radius
                    color: "transparent"
                    borderColor: card.accent
                    borderWidth: root.style.focusBorderWidth
                }

                NativeRoundedRectangle {
                    x: card.record.iconBounds.x
                    y: card.record.iconBounds.y
                    width: card.record.iconBounds.width
                    height: card.record.iconBounds.height
                    radius: root.style.iconRadius
                    color: Qt.alpha(card.accent, root.style.iconAlpha)

                    ChromeText {
                        anchors.fill: parent
                        pixelSize: root.style.titlePixels
                        emphasized: true
                        color: card.accent
                        text: card.record.symbol
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideNone
                        Accessible.ignored: true
                    }
                }

                ChromeText {
                    objectName: "notificationTitle"
                    x: card.record.titleBounds.x
                    y: card.record.titleBounds.y
                    width: card.record.titleBounds.width
                    height: card.record.titleBounds.height
                    pixelSize: root.style.titlePixels
                    emphasized: true
                    text: card.record.title
                    color: root.colors.text
                    Accessible.ignored: true
                }

                Repeater {
                    model: card.record.body

                    ChromeText {
                        objectName: "notificationMessageLine"
                        required property var modelData
                        x: modelData.bounds.x
                        y: modelData.bounds.y
                        width: modelData.bounds.width
                        height: modelData.bounds.height
                        pixelSize: root.style.bodyPixels
                        text: modelData.text
                        color: root.colors.subtext0
                        elide: Text.ElideNone
                        Accessible.ignored: true
                    }
                }

                ChromeText {
                    objectName: "notificationAction"
                    x: card.record.actionBounds.x
                    y: card.record.actionBounds.y
                    width: card.record.actionBounds.width
                    height: card.record.actionBounds.height
                    visible: card.record.clickable
                    pixelSize: root.style.smallPixels
                    emphasized: true
                    text: card.record.action
                    color: card.accent
                    elide: Text.ElideNone
                    Accessible.ignored: true
                }

                NativeRoundedRectangle {
                    objectName: "notificationUnderline"
                    x: card.record.underlineBounds.x
                    y: card.record.underlineBounds.y
                    width: card.record.underlineBounds.width
                    height: card.record.underlineBounds.height
                    visible: card.record.clickable && bodyControl.hovered
                    color: card.accent
                }

                NotificationButton {
                    id: closeControl
                    objectName: "notificationClose"

                    x: card.record.closeBounds.x
                    y: card.record.closeBounds.y
                    width: card.record.closeBounds.width
                    height: card.record.closeBounds.height
                    enabled: card.record.enabled
                    Accessible.name: "Dismiss notification"
                    KeyNavigation.backtab: bodyControl
                    onActivated: root.controller.dismissNotification(card.record.key)

                    background: Item {
                        NativeRoundedRectangle {
                            anchors.fill: parent
                            visible: closeControl.hovered || closeControl.activeFocus
                            radius: root.style.closeRadius
                            color: root.colors.surface1
                        }

                        NativeRoundedRectangle {
                            objectName: "notificationCloseFocus"
                            anchors.fill: parent
                            visible: closeControl.activeFocus
                            radius: root.style.closeRadius
                            color: "transparent"
                            borderColor: card.accent
                            borderWidth: root.style.borderWidth
                        }
                    }

                    contentItem: ChromeText {
                        text: "×"
                        pixelSize: root.style.titlePixels
                        color: root.colors.subtext0
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideNone
                        Accessible.ignored: true
                    }
                }
            }
        }
    }
}
