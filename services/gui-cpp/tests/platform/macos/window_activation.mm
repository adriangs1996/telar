#include "../window_activation.hpp"
#include <AppKit/AppKit.h>
#include <QFile>
#include <QGuiApplication>
#include <QIODevice>
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

// Cocoa can recreate the native window while the fixture still has its old acknowledgement.
bool windowManagerReady(const QWindow &window) {
  const auto ready = qEnvironmentVariable("TELAR_GUI_TEST_WINDOW_READY");
  if (ready.isEmpty() || QGuiApplication::platformName() != QLatin1StringView("cocoa")) {
    return true;
  }

  if (window.handle() == nullptr) {
    return false;
  }

  const auto *handle = std::bit_cast<const void *>(window.winId());
  auto *const view = (__bridge NSView *)handle;
  QFile acknowledgement{ready + QStringLiteral(".owner")};
  if (view.window == nil || !acknowledgement.open(QIODevice::ReadOnly)) {
    return false;
  }

  bool parsed = false;
  const auto admitted = acknowledgement.readAll().trimmed().toLongLong(&parsed);

  return parsed && admitted == view.window.windowNumber;
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
