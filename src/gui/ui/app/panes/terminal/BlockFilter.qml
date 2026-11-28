pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// The filter of a command's output, at the pane's top while it is open on one of its blocks:
// the query, how it reads it and what it found. Typing filters at once; Enter gives the keys back
// to the terminal and keeps the filter, Escape closes it. Alt+R reads the query as a regular
// expression, Alt+C matches its case, Alt+I keeps the lines it is not found in, and Alt+Up and
// Alt+Down change the lines of context around each match.
Item {
    id: root

    required property var view
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var filter: root.view ? root.view.blockFilter : ({})
    readonly property bool open: root.filter.open === true
    // How the query is read, kept here while it is typed.
    property bool regex: false
    property bool matchCase: false
    property bool invert: false
    property int context: 0
    readonly property int maximumContext: 20

    // The keys went back to the terminal.
    signal finished()

    visible: root.open
    height: 30 * root.ratio

    // Each time the filter is asked to open, on its block again too, the bar takes the keys.
    readonly property var opened: root.filter.opened ?? 0
    onOpenedChanged: {
        if (!root.open) {
            return;
        }

        field.text = root.filter.text ?? "";
        root.regex = root.filter.regex === true;
        root.matchCase = root.filter.ignoreCase === false && (root.filter.text ?? "").length > 0;
        root.invert = root.filter.invert === true;
        root.context = root.filter.context ?? 0;
        field.forceActiveFocus();
    }

    function apply() {
        root.view.queryBlockFilter(field.text, root.regex, !root.matchCase, root.invert, root.context);
    }

    function toggle(name) {
        root[name] = !root[name];
        root.apply();
    }

    function widen(delta) {
        root.context = Math.max(0, Math.min(root.maximumContext, root.context + delta));
        root.apply();
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        color: Qt.rgba(root.colors.surface0.r, root.colors.surface0.g, root.colors.surface0.b, 0.97)
        radius: ChromeStyle.controlRadius * root.ratio
    }

    NativeRoundedRectangle {
        anchors.fill: parent
        color: "transparent"
        radius: ChromeStyle.controlRadius * root.ratio
        borderWidth: Math.max(1, root.ratio)
        borderColor: root.filter.error ? root.colors.red : field.activeFocus ? root.colors.accent : root.colors.overlay1
        borderAlpha: field.activeFocus || root.filter.error ? ChromeStyle.focusAlpha : ChromeStyle.outlineAlpha
    }

    // A way the query is read, lit while it is on.
    component Toggle: Rectangle {
        id: toggle
        property alias text: toggleLabel.text
        property bool on: false
        property string hint: ""
        signal activated
        anchors.verticalCenter: parent.verticalCenter
        width: toggleLabel.implicitWidth + 12 * root.ratio
        height: root.height - 10 * root.ratio
        radius: ChromeStyle.smallRadius * root.ratio
        color: toggle.on ? Qt.alpha(root.colors.accent, 0.25) : toggleArea.containsMouse ? Qt.alpha(root.colors.text, 0.08) : "transparent"
        border.width: Math.max(1, root.ratio)
        border.color: toggle.on ? Qt.alpha(root.colors.accent, 0.8) : Qt.alpha(root.colors.overlay1, 0.5)
        Accessible.role: Accessible.CheckBox
        Accessible.name: toggle.hint
        Accessible.checked: toggle.on

        ChromeText {
            id: toggleLabel
            anchors.centerIn: parent
            width: implicitWidth
            height: implicitHeight
            pixelSize: root.typography.small ?? root.typography.body
            emphasized: toggle.on
            color: toggle.on ? root.colors.text : root.colors.subtext0
        }

        MouseArea {
            id: toggleArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toggle.activated()
        }
    }

    Row {
        id: controls
        anchors.right: parent.right
        anchors.rightMargin: 6 * root.ratio
        height: parent.height
        spacing: 4 * root.ratio

        ChromeText {
            id: found
            anchors.verticalCenter: parent.verticalCenter
            width: implicitWidth
            height: implicitHeight
            pixelSize: root.typography.small ?? root.typography.body
            text: root.filter.error ? root.filter.error : (root.filter.text ?? "").length === 0 ? "" : (root.filter.matches ?? 0) + ((root.filter.matches ?? 0) === 1 ? " line" : " lines") + (root.filter.complete ? "" : "…") + (root.filter.truncated ? ", cut" : "")
            color: root.filter.error ? root.colors.red : root.colors.subtext0
        }

        Toggle {
            text: ".*"
            hint: "Regular expression (Alt+R)"
            on: root.regex
            onActivated: root.toggle("regex")
        }

        Toggle {
            text: "Aa"
            hint: "Match case (Alt+C)"
            on: root.matchCase
            onActivated: root.toggle("matchCase")
        }

        Toggle {
            text: "!"
            hint: "Lines without it (Alt+I)"
            on: root.invert
            onActivated: root.toggle("invert")
        }

        Toggle {
            text: "±" + root.context
            hint: "Lines of context (Alt+Up, Alt+Down)"
            on: root.context > 0
            onActivated: root.widen(root.context >= root.maximumContext ? -root.context : 1)
        }

        Toggle {
            text: "esc"
            hint: "Close the filter"
            onActivated: root.view.closeBlockFilter()
        }
    }

    ChromeText {
        id: label
        x: 10 * root.ratio
        anchors.verticalCenter: parent.verticalCenter
        width: implicitWidth
        height: implicitHeight
        pixelSize: root.typography.small ?? root.typography.body
        emphasized: true
        text: "&"
        color: root.colors.accent
    }

    FormTextField {
        id: field
        objectName: "blockFilterField"
        x: label.x + label.width + 8 * root.ratio
        width: Math.max(0, controls.x - x - 8 * root.ratio)
        height: parent.height
        colors: root.colors
        typography: root.typography
        ratio: root.ratio
        placeholderText: "filter the output"
        onTextEdited: root.apply()
        Keys.onPressed: (event) => {
            if ((event.modifiers & Qt.AltModifier) === 0) {
                return;
            }

            const toggles = {[Qt.Key_R]: "regex", [Qt.Key_C]: "matchCase", [Qt.Key_I]: "invert"};
            if (event.key in toggles) {
                root.toggle(toggles[event.key]);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                root.widen(event.key === Qt.Key_Up ? 1 : -1);
                event.accepted = true;
            }
        }
        Keys.onReturnPressed: root.finished()
        Keys.onEnterPressed: root.finished()
        Keys.onEscapePressed: {
            if (!field.cancelComposition()) {
                root.view.closeBlockFilter();
                root.finished();
            }
        }
    }
}
