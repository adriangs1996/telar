import QtQuick

// How documents (`telar render`) look in a pane: sizes from the terminal's grid, colours from
// the theme. DocumentView and InlineDocuments share it with the blocks they draw.
QtObject {
    property var colors: ({})
    property var grid: ({})
    property real ratio: 1

    readonly property real bodySize: Math.max(12, (grid.pixelHeight || 14) * 1.08)
    readonly property string bodyFamily: "IBM Plex Sans"
    readonly property string monoFamily: grid.family || "monospace"
    readonly property real indentStep: bodySize * 1.6
    readonly property real quoteStep: bodySize * 1.1

    function colorOf(name, fallback) {
        return colors[name] || fallback;
    }

    function calloutColor(callout) {
        switch (callout) {
        case "note": return colorOf("blue", colorOf("accent", "#8aadf4"));
        case "tip": return colorOf("green", colorOf("success", "#a6da95"));
        case "important": return colorOf("mauve", colorOf("accent", "#c6a0f6"));
        case "warning": return colorOf("yellow", colorOf("warning", "#eed49f"));
        case "caution": return colorOf("red", colorOf("failure", "#ed8796"));
        }
        return colorOf("border", "#5b6078");
    }

    function headingSize(level) {
        return bodySize * [2.0, 1.6, 1.3, 1.15, 1.0, 0.95][Math.max(0, Math.min(5, level - 1))];
    }
}
