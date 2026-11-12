import QtQuick
import Telar.Gui

// Documents drawn in place of the rows of text they stand for (`telar render` in a pane). The
// terminal lists them and where each one's display rows start; one it has yet to place is laid
// out unseen here and measured in rows, and the terminal makes that many rows for it.
Item {
    id: root

    required property var application
    required property string paneId
    required property var view
    property var colors: ({})
    property var grid: ({})
    property real ratio: 1

    DocumentTheme {
        id: documentTheme
        colors: root.colors
        grid: root.grid
        ratio: root.ratio
    }

    Repeater {
        model: root.view ? root.view.documents : []

        delegate: Item {
            id: zone
            objectName: "inlineDocument"
            required property var modelData

            readonly property real cell: root.view.cell.height
            readonly property var start: root.view.documentRows[String(zone.modelData.id)]
            readonly property int needed: Math.max(1, Math.ceil(body.implicitHeight / Math.max(1, zone.cell)))

            function report() {
                // A deferred call may run after the document went and its delegate with it.
                if (typeof root === "undefined" || !root || !root.application || typeof inlineDocument === "undefined" || !inlineDocument) {
                    return;
                }
                if (inlineDocument.shown && zone.cell > 0 && body.implicitHeight > 0) {
                    root.application.measureInlineDocument(root.paneId, zone.modelData.id, zone.needed);
                }
            }

            width: root.width
            height: zone.modelData.placed ? zone.modelData.rows * zone.cell : body.implicitHeight
            y: zone.modelData.placed && zone.start !== undefined ? zone.start * zone.cell - root.view.scrollShift : 0
            readonly property bool placed: zone.modelData.placed && zone.start !== undefined
            // Laid out even while unplaced, as invisible items take no room, to be measured.
            visible: inlineDocument.shown
            opacity: zone.placed ? 1 : 0
            enabled: zone.placed
            clip: true

            // Measured after the frame that laid it out: the terminal makes rows for it, which
            // changes the list this delegate comes from.
            onNeededChanged: Qt.callLater(zone.report)
            Component.onCompleted: Qt.callLater(zone.report)

            NativeDocument {
                id: inlineDocument
                application: root.application
                paneId: root.paneId
                documentId: zone.modelData.id
                colors: root.colors
                monoFamily: documentTheme.monoFamily
                onDocumentChanged: Qt.callLater(zone.report)
            }

            Column {
                id: body
                width: zone.width
                topPadding: documentTheme.bodySize * 0.4
                bottomPadding: documentTheme.bodySize * 0.4
                readonly property real inset: Math.max(root.view.cell.width, 1)

                Repeater {
                    model: inlineDocument.blocks
                    delegate: DocumentBlock {
                        width: body.width
                        theme: documentTheme
                        document: inlineDocument
                        inset: body.inset
                        measure: Math.min(body.width - body.inset * 2, documentTheme.bodySize * 46)
                    }
                }
            }
        }
    }
}
