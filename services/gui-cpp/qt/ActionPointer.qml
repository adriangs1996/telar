import QtQuick

MouseArea {
    id: root

    property string identity: ""
    property bool captureValid: false
    signal activated()

    hoverEnabled: true
    onIdentityChanged: captureValid = false
    onEnabledChanged: captureValid = false
    onVisibleChanged: captureValid = false
    onPressed: captureValid = true
    onCanceled: captureValid = false
    onClicked: {
        const accepted = captureValid;
        captureValid = false;
        if (accepted) {
            root.activated();
        }
    }
}
