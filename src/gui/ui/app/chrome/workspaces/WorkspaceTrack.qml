pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import Telar.Gui

// The workspaces of the machine as one segmented control, in the runtime's order: each segment a
// swatch of its hue and a name, the active one filled. While the room holds every name they all
// show; when it does not, only the active one keeps its name and the others a tile with their
// initial; past that the ones that do not fit hide behind the control that opens the whole list.
Item {
    id: root

    required property var model
    required property var colors
    required property var typography
    property real ratio: 1
    // The bar's controls share one height; the track takes it from the bar.
    property real controlHeight: Math.round(30 * ratio)
    property int selectedIndex: -1
    // The room the bar leaves the track; it draws the richest form that fits it.
    property real room: 0
    readonly property int count: segments.count
    readonly property real trackHeight: controlHeight
    readonly property real inset: Math.round(3 * ratio)
    readonly property real spacing: Math.round(2 * ratio)
    readonly property real markSide: Math.round(20 * ratio)
    // A named segment's hue: the name beside it already says what the tile's initial would.
    readonly property real swatchSide: Math.round(8 * ratio)
    readonly property real segmentHeight: trackHeight - 2 * inset
    readonly property real segmentPadding: Math.round(8 * ratio)
    readonly property real labelGap: Math.round(6 * ratio)
    readonly property real dotSide: Math.round(6 * ratio)
    readonly property real compactWidth: markSide + 2 * Math.round(2 * ratio)
    readonly property real moreWidth: Math.round(26 * ratio)
    // The grounds the track's ink sits on. The text of a segment at rest reads on the well, or
    // on the hover over it, whichever is closer to the text.
    readonly property color well: Qt.tint(Qt.rgba(colors.topbarBackground.r, colors.topbarBackground.g, colors.topbarBackground.b, 1), Qt.alpha(colors.chromeText, ChromeStyle.wellAlpha))
    readonly property color hoverGround: Qt.tint(well, Qt.alpha(colors.chromeText, ChromeStyle.hoverAlpha))
    readonly property color currentGround: Qt.tint(well, Qt.alpha(colors.chromeText, currentAlpha))
    readonly property color secondary: ChromeStyle.legible(colors.subtext0, hoverGround, 4.5)
    readonly property real currentAlpha: 0.18
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
    // The track with every name, and with only the active one's: the bar gives it the first when
    // it has the room, else the second.
    readonly property real namedWidth: count === 0 ? 0 : namedTotal + chrome
    readonly property real shortWidth: count === 0 ? 0 : compactTotal + chrome
    readonly property real preferredWidth: namedWidth
    readonly property real activeWidth: selectedIndex >= 0 && selectedIndex < namedWidths.length ? (namedWidths[selectedIndex] ?? compactWidth) : compactWidth
    readonly property real compactTotal: count === 0 ? 0 : activeWidth + Math.max(0, count - (selectedIndex >= 0 ? 1 : 0)) * compactWidth + Math.max(0, count - 1) * spacing
    readonly property bool named: count > 0 && namedWidth <= room
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
        color: Qt.alpha(root.colors.chromeText, ChromeStyle.wellAlpha)
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
            // Every name in one weight, so the room a name keeps is the room it draws and
            // choosing a workspace moves none of the others.
            readonly property real namedWidth: root.segmentPadding + root.swatchSide + root.labelGap + Math.ceil(name.implicitWidth) + dotRoom + root.segmentPadding
            readonly property bool whole: root.named || current
            readonly property color ground: current ? root.currentGround : root.well
            // The hue in full on the workspace in front; the others' fade toward the well, so
            // their names, not their colors, are what reads first.
            readonly property color ink: current ? hue : Qt.tint(root.well, Qt.alpha(hue, 0.6))

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
                // The active segment is raised by its fill alone, so the well draws the only
                // outline; a border marks keyboard focus.
                color: segment.current ? Qt.alpha(root.colors.chromeText, root.currentAlpha) : segment.hovered || segment.visualFocus ? Qt.alpha(root.colors.chromeText, ChromeStyle.hoverAlpha) : "transparent"
                borderColor: root.colors.accent
                borderAlpha: ChromeStyle.focusAlpha
                borderWidth: segment.visualFocus ? root.ratio : 0
            }

            HoverHandler { cursorShape: Qt.PointingHandCursor }

            // The workspace's hue: a swatch beside its name, or a tile with its initial when the
            // name has no room.
            NativeRoundedRectangle {
                id: mark
                objectName: "workspaceSegmentMark"
                readonly property real fill: segment.current ? 0.24 : 0.14
                x: segment.whole ? root.segmentPadding : (segment.width - width) / 2
                y: (segment.height - height) / 2
                width: segment.whole ? root.swatchSide : root.markSide
                height: width
                radius: segment.whole ? width / 2 : Math.round(6 * root.ratio)
                color: segment.whole ? segment.ink : Qt.alpha(segment.hue, fill)
                borderColor: segment.hue
                borderAlpha: segment.whole ? 0 : segment.current ? 0.5 : 0.25
                borderWidth: segment.whole ? 0 : 1 / Screen.devicePixelRatio

                ChromeText {
                    objectName: "workspaceSegmentInitial"
                    anchors.fill: parent
                    text: segment.record.initial || "?"
                    color: ChromeStyle.legible(segment.ink, Qt.tint(segment.ground, Qt.alpha(segment.hue, mark.fill)), 3)
                    pixelSize: root.typography.small
                    emphasized: true
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideNone
                    visible: !segment.whole
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
                x: root.segmentPadding + root.swatchSide + root.labelGap
                width: Math.max(0, segment.width - x - segment.dotRoom - root.segmentPadding)
                height: segment.height
                text: segment.record.name ?? ""
                color: segment.current || segment.hovered ? root.colors.chromeText : root.secondary
                pixelSize: root.typography.body
                visible: segment.whole
                Accessible.ignored: true
            }

            NativeRoundedRectangle {
                objectName: "workspaceSegmentAttention"
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
                text: segment.record.name + "\n" + (segment.record.shownPath ?? segment.record.path ?? "")
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
            }

            Accessible.role: Accessible.PageTab
            Accessible.name: record.name + " " + (record.path ?? "") + (alerting ? ", needs attention" : "")
            Accessible.selected: current
        }
    }

    // Opens the list of every workspace, which starts on its search field: a magnifier while
    // every workspace shows, the count of the ones the track could not show otherwise. The
    // machine's chevron is the only chevron in the bar.
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
            color: root.secondary
            pixelSize: root.typography.small
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideNone
            visible: more.hiddenCount > 0
            Accessible.ignored: true
        }

        ProviderMark {
            objectName: "workspaceTrackMoreSearch"
            anchors.centerIn: parent
            width: Math.round(12 * root.ratio)
            height: width
            symbol: "search"
            color: root.secondary
            visible: more.hiddenCount === 0
        }

        Accessible.role: Accessible.Button
        Accessible.name: more.hiddenCount > 0 ? "Show all workspaces, " + more.hiddenCount + " hidden" : "Find a workspace"
    }
}
