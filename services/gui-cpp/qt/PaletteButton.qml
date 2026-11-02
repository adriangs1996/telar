pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

FormButton {
    property real ratio: 1

    quiet: true
    radius: 7 * ratio
    pressedAlpha: 0.8
    disabledAlpha: 0.4
}
