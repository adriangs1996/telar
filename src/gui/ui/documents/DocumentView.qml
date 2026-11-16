import QtQuick
import Telar.Gui

// The document a pane's program shows natively (`telar render --pager`), drawn over the pane's
// rows while the program runs. It scrolls by wheel, drag and the keys the terminal hands it;
// every other key reaches the program, which ends the document by leaving the alternate screen.
Item {
    id: root
    objectName: "documentView"

    required property var application
    required property string paneId
    property var colors: ({})
    property var grid: ({})
    property real ratio: 1
    // Takes the keyboard when the document is clicked, so keys keep reaching the pane.
    property Item focusTarget: null

    readonly property bool shown: nativeDocument.shown

    visible: shown

    function scroll(action) {
        const page = list.height * 0.9;
        const line = documentTheme.bodySize * 1.5 * 3;
        const end = Math.max(0, list.contentHeight - list.height) + list.originY;
        let target = list.contentY;
        switch (action) {
        case "line_down": target += line; break;
        case "line_up": target -= line; break;
        case "half_down": target += page / 2; break;
        case "half_up": target -= page / 2; break;
        case "page_down": target += page; break;
        case "page_up": target -= page; break;
        case "top": target = list.originY; break;
        case "bottom": target = end; break;
        }
        list.cancelFlick();
        list.contentY = Math.max(list.originY, Math.min(end, target));
    }

    DocumentTheme {
        id: documentTheme
        colors: root.colors
        grid: root.grid
        ratio: root.ratio
    }

    NativeDocument {
        id: nativeDocument
        application: root.application
        paneId: root.paneId
        colors: root.colors
        monoFamily: documentTheme.monoFamily
        onScrollRequested: action => root.scroll(action)
        onDocumentChanged: list.positionViewAtBeginning()
    }

    Rectangle {
        anchors.fill: parent
        color: documentTheme.colorOf("terminalBackground", "#1e1e2e")
    }

    TapHandler {
        onTapped: {
            if (root.focusTarget) {
                root.application.execute(ApplicationController.Action.focus_pane, root.paneId);
                root.focusTarget.forceActiveFocus();
            }
        }
    }

    ListView {
        id: list
        objectName: "documentList"
        anchors.fill: parent
        anchors.topMargin: documentTheme.bodySize * 1.5
        anchors.bottomMargin: documentTheme.bodySize
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.shown ? nativeDocument.blocks : []
        // Lines no longer than a comfortable measure, centred in a wide pane.
        readonly property real measure: Math.min(width - documentTheme.bodySize * 3, documentTheme.bodySize * 46)
        readonly property real inset: Math.max(documentTheme.bodySize * 1.5, (width - measure) / 2)

        delegate: DocumentBlock {
            width: ListView.view.width
            theme: documentTheme
            document: nativeDocument
            inset: list.inset
            measure: list.measure
        }

        footer: Item {
            width: 1
            height: documentTheme.bodySize * 2
        }
    }
}
