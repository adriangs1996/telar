import QtQuick

MouseArea {
    id: root

    property string identity: ""
    property bool captureValid: false
    signal activated
    signal captureStarted

    hoverEnabled: true
    // MouseArea.enabled does not disable the item, so a disabled area must give its cursor back.
    cursorShape: enabled ? Qt.PointingHandCursor : undefined
    onIdentityChanged: captureValid = false
    onEnabledChanged: captureValid = false
    onVisibleChanged: captureValid = false
    onPressed: {
        captureValid = true;
        root.captureStarted();
    }
    onCanceled: captureValid = false
    onClicked: {
        const accepted = captureValid;
        captureValid = false;
        if (accepted) {
            root.activated();
        }
    }
}
