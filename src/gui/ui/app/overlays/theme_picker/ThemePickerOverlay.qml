pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The theme picker over the whole window: a row of slanted slices, one per theme, with the
// configuration's first. The focused slice opens to show the window itself, which already wears
// that theme; the others draw a small window in their colors. Its name is written below.
FocusScope {
    id: root

    required property ThemePickerController controller
    // The window's content, which the open slice shows live. The picker is not inside it.
    required property Item source
    required property var colors
    required property var typography
    property real ratio: 1

    readonly property var themes: controller.themes
    readonly property int focusIndex: controller.focus
    readonly property var focused: themes[focusIndex] ?? ({})
    readonly property real aspect: source && source.height > 0 ? source.width / source.height : 1.6
    // Every size follows the window: the open slice takes most of it, never less than it can be
    // read at, and the closed ones and the caption follow the open one.
    readonly property real minimumCardHeight: 180 * ratio
    readonly property real cardHeight: Math.max(minimumCardHeight, Math.min(height * 0.58, width * 0.68 / aspect))
    readonly property real cardWidth: cardHeight * aspect
    readonly property real sliceWidth: Math.max(14 * ratio, cardWidth * 0.045)
    readonly property real gap: Math.max(3 * ratio, cardWidth * 0.008)
    readonly property real titleSize: Math.max(typography.title, cardHeight * 0.045)
    readonly property real detailSize: Math.max(typography.small, cardHeight * 0.028)
    // How far a slice leans: its bottom edge sits this share of its height to the left of its top.
    readonly property real lean: 0.12

    objectName: "themePickerOverlay"
    anchors.fill: parent
    visible: telar.dialogs.kind === Store.Dialog.themes && controller.open
    z: 60
    onVisibleChanged: {
        if (visible)
            root.forceActiveFocus();
    }

    Keys.onPressed: event => {
        const key = event.key;
        event.accepted = true;
        if (key === Qt.Key_Right || key === Qt.Key_Down || key === Qt.Key_Tab)
            controller.move(1);
        else if (key === Qt.Key_Left || key === Qt.Key_Up || key === Qt.Key_Backtab)
            controller.move(-1);
        else if (key === Qt.Key_Home)
            controller.focusTheme(0);
        else if (key === Qt.Key_End)
            controller.focusTheme(themes.length - 1);
        else if (key === Qt.Key_Return || key === Qt.Key_Enter)
            controller.choose();
        else if (key === Qt.Key_Escape)
            controller.cancel();
        else if (event.text.length > 0 && event.text.trim().length > 0 && !(event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)))
            controller.type(event.text);
        else
            event.accepted = false;
    }

    // The window behind, dimmed: it still shows the focused theme around the slices.
    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 0.55
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.controller.cancel()
        property real pending: 0
        onWheel: wheel => {
            const delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : -wheel.angleDelta.x;
            pending += delta;
            if (Math.abs(pending) >= 120) {
                root.controller.move(pending > 0 ? -1 : 1);
                pending = 0;
            }
        }
    }

    Item {
        id: stage
        anchors.centerIn: parent
        width: parent.width
        height: root.cardHeight * 1.05 + caption.height

        Row {
            id: strip
            objectName: "themePickerStrip"
            y: 0
            height: root.cardHeight
            spacing: root.gap
            // The focused slice stays at the middle of the window.
            x: stage.width / 2 - (root.focusIndex * (root.sliceWidth + root.gap) + (root.cardWidth + root.lean * root.cardHeight) / 2)

            Behavior on x {
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
            }

            Repeater {
                model: root.themes

                delegate: Item {
                    id: slice

                    required property var modelData
                    required property int index
                    readonly property bool current: index === root.focusIndex
                    readonly property var shades: modelData.colors

                    objectName: "themeSlice_" + index
                    width: current ? root.cardWidth : root.sliceWidth
                    height: root.cardHeight
                    clip: true
                    transform: Matrix4x4 {
                        matrix: Qt.matrix4x4(1, -root.lean, 0, root.lean * slice.height, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
                    }

                    Behavior on width {
                        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                    }

                    // Undoes the lean, so what the slice shows stands upright inside it.
                    Item {
                        id: upright
                        x: -root.lean * slice.height
                        width: slice.width + root.lean * slice.height
                        height: slice.height
                        transform: Matrix4x4 {
                            matrix: Qt.matrix4x4(1, root.lean, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
                        }

                        // A small window in the theme's colors: its bars, its sidebar and lines of
                        // its terminal colors.
                        Rectangle {
                            anchors.fill: parent
                            visible: !slice.current
                            color: slice.shades.background

                            Rectangle {
                                width: parent.width
                                height: parent.height * 0.07
                                color: slice.shades.panel
                            }

                            Column {
                                x: parent.width * 0.18
                                y: parent.height * 0.12
                                spacing: parent.height * 0.028

                                Repeater {
                                    model: [4, 2, 3, 5, 6, 1, 4, 2, 10, 12, 3, 9, 13, 5, 11, 14, 2, 4]

                                    delegate: Rectangle {
                                        required property int modelData
                                        required property int index
                                        width: upright.width * (0.25 + (index * 37 % 50) / 100)
                                        height: Math.max(2, slice.height * 0.014)
                                        radius: height / 2
                                        color: slice.shades.ansi[modelData] ?? slice.shades.foreground
                                    }
                                }
                            }

                            Rectangle {
                                y: parent.height * 0.93
                                width: parent.width
                                height: parent.height * 0.07
                                color: slice.shades.panel

                                Rectangle {
                                    x: parent.width * 0.18
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.height * 0.35
                                    height: width
                                    radius: width / 2
                                    color: slice.shades.accent
                                }
                            }
                        }

                        // The window itself, live: it wears the focused theme already.
                        Rectangle {
                            anchors.fill: parent
                            visible: slice.current
                            color: root.colors.background

                            ShaderEffectSource {
                                objectName: "themePickerLiveWindow"
                                anchors.centerIn: parent
                                width: parent.width
                                height: parent.width / root.aspect
                                sourceItem: slice.current && root.visible ? root.source : null
                                live: true
                                hideSource: false
                                smooth: true
                                textureSize: Qt.size(Math.ceil(width * Screen.devicePixelRatio), Math.ceil(height * Screen.devicePixelRatio))
                            }
                        }
                    }

                    // The configuration's slice says so in its corner.
                    Rectangle {
                        visible: slice.modelData.configuration
                        x: root.lean * slice.height * 0.2 + 6 * root.ratio
                        y: slice.height - height - 6 * root.ratio
                        width: configLabel.implicitWidth + 8 * root.ratio
                        height: configLabel.implicitHeight + 4 * root.ratio
                        radius: 3 * root.ratio
                        color: Qt.rgba(0, 0, 0, 0.55)

                        ChromeText {
                            id: configLabel
                            anchors.centerIn: parent
                            text: slice.current ? "config.lua" : "cfg"
                            pixelSize: root.typography.small
                            color: "white"
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (slice.current)
                                root.controller.choose();
                            else
                                root.controller.focusTheme(slice.index);
                        }
                    }
                }
            }
        }

        // The ring around the open slice, in its theme's accent.
        Item {
            x: strip.x + root.focusIndex * (root.sliceWidth + root.gap)
            width: root.cardWidth
            height: root.cardHeight
            transform: Matrix4x4 {
                matrix: Qt.matrix4x4(1, -root.lean, 0, root.lean * root.cardHeight, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: -2 * root.ratio
                color: "transparent"
                border.width: 2 * root.ratio
                border.color: root.focused.colors ? root.focused.colors.accent : root.colors.accent
                radius: 3 * root.ratio
            }
        }

        Column {
            id: caption
            objectName: "themePickerCaption"
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.cardHeight + root.cardHeight * 0.05
            spacing: root.cardHeight * 0.012

            ChromeText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.focused.label ?? ""
                pixelSize: root.titleSize
                emphasized: true
                color: "white"
            }

            ChromeText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.focused.detail ?? ""
                pixelSize: root.detailSize
                color: Qt.rgba(1, 1, 1, 0.7)
            }

            ChromeText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "←  →  preview      ↵  use      esc  back"
                pixelSize: root.detailSize
                color: Qt.rgba(1, 1, 1, 0.55)
            }
        }
    }
}
