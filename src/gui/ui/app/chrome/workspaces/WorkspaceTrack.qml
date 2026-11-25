pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

// The workspaces of the machine as one segmented control, in the runtime's order: each segment a
// mark and a name, the active one filled. From three workspaces on, or when the bar runs short,
// only the active one keeps its name and the others their mark, so the track leaves the tabs
// their room; past that the ones that do not fit hide behind the control that opens the whole
// list.
Item {
    id: root

    required property var model
    required property var colors
    required property var typography
    property real ratio: 1
    property int selectedIndex: -1
    // The room the bar leaves the track; it draws the richest form that fits it.
    property real room: 0
    readonly property int count: segments.count
    readonly property real trackHeight: Math.round(30 * ratio)
    readonly property real inset: Math.round(3 * ratio)
    readonly property real spacing: Math.round(2 * ratio)
    readonly property real markSide: Math.round(20 * ratio)
    readonly property real segmentHeight: trackHeight - 2 * inset
    readonly property real segmentPadding: Math.round(6 * ratio)
    readonly property real labelGap: Math.round(6 * ratio)
    readonly property real dotSide: Math.round(6 * ratio)
    readonly property real compactWidth: markSide + 2 * Math.round(2 * ratio)
    readonly property real moreWidth: Math.round(26 * ratio)
    // What each segment measures with its name, as its delegate reports it; the list counts its
    // rows before or after it builds them, so the total follows both.
    property var namedWidths: []
    // Every segment whole, then only the active one whole.
    readonly property real namedTotal: {
        let total = 0;

        for (let position = 0; position < count; ++position) total += namedWidths[position] ?? compactWidth;

        return count === 0 ? 0 : total + (count - 1) * spacing;
    }
    readonly property real chrome: 2 * inset + spacing + moreWidth
    // The most workspaces that all show their name.
    readonly property int namedLimit: 2
    readonly property bool few: count <= namedLimit
    readonly property real preferredWidth: count === 0 ? 0 : (few ? namedTotal : compactTotal) + chrome
    readonly property real activeWidth: selectedIndex >= 0 && selectedIndex < namedWidths.length ? (namedWidths[selectedIndex] ?? compactWidth) : compactWidth
    readonly property real compactTotal: count === 0 ? 0 : activeWidth + Math.max(0, count - (selectedIndex >= 0 ? 1 : 0)) * compactWidth + Math.max(0, count - 1) * spacing
    readonly property bool named: few && namedTotal + chrome <= room
    readonly property real listRoom: Math.max(0, room - chrome)
    readonly property real listWidth: Math.min(named ? namedTotal : compactTotal, listRoom)
    readonly property bool overflowing: !named && compactTotal > listRoom
    // How many marks the room holds beside the active segment.
    readonly property int shownCount: !overflowing ? count : Math.max(selectedIndex >= 0 ? 1 : 0, Math.min(count, (selectedIndex >= 0 ? 1 : 0) + Math.floor(Math.max(0, listRoom - (selectedIndex >= 0 ? activeWidth : 0)) / (compactWidth + spacing))))
    signal selected(string key)
    signal listRequested()

    implicitWidth: count === 0 || room < chrome + compactWidth ? 0 : listWidth + chrome
    implicitHeight: trackHeight
    visible: implicitWidth > 0
    Accessible.role: Accessible.PageTabList
    Accessible.name: "Workspaces"

    function report(index, natural) {
        if (namedWidths[index] === natural) return;
        const widths = namedWidths.slice();

        widths[index] = natural;
        namedWidths = widths;
    }

    NativeRoundedRectangle {
        objectName: "workspaceTrackWell"
        y: (root.height - height) / 2
        width: root.width
        height: root.trackHeight
        radius: height / 2
        color: Qt.alpha(root.colors.chromeText, 0.07)
    }

    ListView {
        id: segments
        objectName: "workspaceTrackList"
        x: root.inset
        y: (root.height - height) / 2
        width: root.listWidth
        height: root.segmentHeight
        orientation: ListView.Horizontal
        spacing: root.spacing
        model: root.model
        currentIndex: root.selectedIndex
        interactive: false
        clip: true
        highlightFollowsCurrentItem: false
        // Every segment is measured even while it is scrolled out of the row.
        cacheBuffer: 100000

        // The row starts at its first segment whenever all of them fit, and otherwise moves just
        // enough to hold the one in front.
        function reveal() {
            if (root.overflowing && root.selectedIndex >= 0) {
                positionViewAtIndex(root.selectedIndex, ListView.Contain);
            } else {
                positionViewAtBeginning();
            }
        }

        onCurrentIndexChanged: Qt.callLater(reveal)
        onWidthChanged: Qt.callLater(reveal)
        onCountChanged: Qt.callLater(reveal)
        onContentWidthChanged: Qt.callLater(reveal)

        delegate: AbstractButton {
            id: segment
            objectName: "workspaceSegment"
            required property var record
            required property int index
            readonly property bool current: record.selected ?? false
            readonly property color hue: root.colors[record.markHue ?? "mauve"]
            readonly property bool alerting: (record.attention ?? "").length > 0
            readonly property real dotRoom: alerting ? root.labelGap + root.dotSide : 0
            // The heavier weight's width, so choosing a workspace moves none of the others.
            readonly property real namedWidth: root.segmentPadding + root.markSide + root.labelGap + Math.ceil(measure.implicitWidth) + dotRoom + root.segmentPadding + Math.round(2 * root.ratio)
            readonly property bool whole: root.named || current

            width: whole ? namedWidth : root.compactWidth
            height: root.segmentHeight
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            padding: 0
            contentItem: null
            onNamedWidthChanged: root.report(index, namedWidth)
            Component.onCompleted: root.report(index, namedWidth)
            onClicked: root.selected(record.key)
            background: NativeRoundedRectangle {
                objectName: "workspaceSegmentSurface"
                radius: height / 2
                color: segment.current ? Qt.alpha(root.colors.chromeText, 0.1) : segment.hovered || segment.visualFocus ? Qt.alpha(root.colors.chromeText, ChromeStyle.hoverAlpha) : "transparent"
                borderColor: segment.visualFocus ? root.colors.accent : root.colors.chromeText
                borderAlpha: segment.visualFocus ? ChromeStyle.focusAlpha : 0.32
                borderWidth: segment.current || segment.visualFocus ? root.ratio : 0
            }

            HoverHandler { cursorShape: Qt.PointingHandCursor }

            NativeChromeText {
                id: measure
                text: segment.record.name ?? ""
                pixelSize: root.typography.body
                emphasized: true
                visible: false
            }

            // The workspace's hue and initial, a tile like a machine's.
            NativeRoundedRectangle {
                id: mark
                objectName: "workspaceSegmentMark"
                x: segment.whole ? root.segmentPadding : (segment.width - width) / 2
                y: (segment.height - height) / 2
                width: root.markSide
                height: root.markSide
                radius: Math.round(6 * root.ratio)
                color: Qt.alpha(segment.hue, 0.16)
                borderColor: segment.hue
                borderAlpha: 0.4
                borderWidth: 1 / Screen.devicePixelRatio
                opacity: segment.current || segment.hovered ? 1 : 0.75

                ChromeText {
                    anchors.fill: parent
                    text: segment.record.initial || "?"
                    color: segment.hue
                    pixelSize: root.typography.small
                    emphasized: true
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideNone
                    Accessible.ignored: true
                }

                // On a segment that shows no name, the state rides the mark's corner.
                NativeRoundedRectangle {
                    objectName: "workspaceSegmentMarkAttention"
                    x: parent.width - width / 2 - Math.round(root.ratio)
                    y: -height / 2 + Math.round(root.ratio)
                    width: root.dotSide
                    height: width
                    radius: width / 2
                    color: root.colors[segment.record.attentionColor ?? "yellow"]
                    borderColor: root.colors.topbarBackground
                    borderAlpha: 1
                    borderWidth: Math.max(1, Math.round(root.ratio))
                    visible: segment.alerting && !segment.whole
                }
            }

            ChromeText {
                id: name
                objectName: "workspaceSegmentName"
                x: mark.x + mark.width + root.labelGap
                width: Math.max(0, segment.width - x - segment.dotRoom - root.segmentPadding)
                height: segment.height
                text: segment.record.name ?? ""
                color: segment.current ? root.colors.chromeText : root.colors.subtext0
                pixelSize: root.typography.body
                emphasized: segment.current
                visible: segment.whole
                Accessible.ignored: true
            }

            NativeRoundedRectangle {
                objectName: "workspaceSegmentAttention"
                // Right after the name as it is drawn, which is narrower than the room its heavier weight keeps.
                x: Math.min(name.x + Math.ceil(name.implicitWidth), name.x + name.width) + root.labelGap
                y: (segment.height - height) / 2
                width: root.dotSide
                height: width
                radius: width / 2
                color: root.colors[segment.record.attentionColor ?? "yellow"]
                visible: segment.alerting && segment.whole
            }

            ChromeToolTip {
                visible: segment.hovered
                text: segment.record.name + "\n" + (segment.record.detail ?? segment.record.path ?? "")
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
            }

            Accessible.role: Accessible.PageTab
            Accessible.name: record.name + " " + (record.path ?? "") + (alerting ? ", needs attention" : "")
            Accessible.selected: current
        }
    }

    // Opens the list of every workspace; it counts the ones the track could not show.
    AbstractButton {
        id: more
        objectName: "workspaceTrackMore"
        readonly property int hiddenCount: Math.max(0, root.count - root.shownCount)
        x: root.width - root.inset - width
        y: (root.height - height) / 2
        width: root.moreWidth
        height: root.segmentHeight
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        padding: 0
        contentItem: null
        onClicked: root.listRequested()
        background: NativeRoundedRectangle {
            radius: height / 2
            color: more.hovered || more.visualFocus ? Qt.alpha(root.colors.chromeText, ChromeStyle.hoverAlpha) : "transparent"
            borderColor: root.colors.accent
            borderAlpha: ChromeStyle.focusAlpha
            borderWidth: more.visualFocus ? root.ratio : 0
        }

        HoverHandler { cursorShape: Qt.PointingHandCursor }

        ChromeText {
            objectName: "workspaceTrackMoreLabel"
            anchors.fill: parent
            text: "+" + more.hiddenCount
            color: root.colors.subtext0
            pixelSize: root.typography.small
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideNone
            visible: more.hiddenCount > 0
            Accessible.ignored: true
        }

        ProviderMark {
            objectName: "workspaceTrackMoreChevron"
            anchors.centerIn: parent
            width: Math.round(14 * root.ratio)
            height: width
            symbol: "chevron-down"
            color: root.colors.subtext0
            visible: more.hiddenCount === 0
        }

        Accessible.role: Accessible.Button
        Accessible.name: more.hiddenCount > 0 ? "Show all workspaces, " + more.hiddenCount + " hidden" : "Show all workspaces"
    }
}
