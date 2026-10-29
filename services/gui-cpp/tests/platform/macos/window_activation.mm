#include "../window_activation.hpp"
#include <AppKit/AppKit.h>
#include <QGuiApplication>
#include <QWindow>
#include <QtCore/qnamespace.h>
#include <QtCore/qstring.h>
#include <bit>

namespace telar::gui::test {

void activateApplication() {
  if (QGuiApplication::platformName() == QLatin1StringView("cocoa")) {
    [NSRunningApplication.currentApplication activateWithOptions:NSApplicationActivationOptions{}];
  }
}

void activateWindow(QWindow &window) {
  activateApplication();
  window.requestActivate();
}

void configureComponentWindow(QWindow &window) {
  if (QGuiApplication::platformName() == QLatin1StringView("cocoa")) {
    window.setFlags(Qt::Tool);

    const auto *handle = std::bit_cast<const void *>(window.winId());
    auto *const view = (__bridge NSView *)handle;

    view.window.hidesOnDeactivate = NO;
  }
}

}
