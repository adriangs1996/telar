#include "window_activation.hpp"
#include <QGuiApplication>
#include <QWindow>
#include <QtGui/qpa/qwindowsysteminterface.h>

namespace telar::gui::test {

// A window manager deactivates a window it hides. Qt's offscreen platform
// keeps the hidden window focused, so report the focus loss as one would.
void hideWindow(QWindow &window) {
  window.hide();
  if (QGuiApplication::focusWindow() == &window) {
    QWindowSystemInterface::handleFocusWindowChanged(nullptr, Qt::ActiveWindowFocusReason);
  }
}

}
