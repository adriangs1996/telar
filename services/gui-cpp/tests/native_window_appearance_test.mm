#include "assertions.hpp"
#include "platform/window.hpp"
#include <AppKit/AppKit.h>
#include <QEventLoop>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QTimer>
#include <bit>
#include <exception>
#include <iostream>

namespace {

using telar::gui::test::require;

NSView *effectIn(NSView *parent) {
  for (NSView *child in parent.subviews) {
    if ([child.identifier isEqualToString:@"telar.background.blur"]) {
      return child;
    }
  }

  return nil;
}

void verifyAppearance() {
  constexpr QSize initial_size{640, 480};
  constexpr QSize resized_size{800, 600};
  constexpr int frame_timeout_ms = 5'000;
  QQuickWindow window;
  window.resize(initial_size);
  window.create();
  auto *const view = (__bridge NSView *)std::bit_cast<const void *>(window.winId());
  NSWindow *const native = view.window;
  NSView *const content = native.contentView;
  using telar::gui::platform::configureWindow;
  const telar::gui::platform::WindowAppearance blurred{.titlebar = false, .navigation_height = 42, .background_opacity = 0.98F, .background_blur = 20};
  configureWindow(window, blurred);
  require(native.contentView == content, "appearance must preserve the Qt content view");
  require(effectIn(content) == nil, "native blur must not cover Qt's Metal layer as a child of its content view");
  NSView *const effect = effectIn(content.superview);
  require(effect != nil, "blur must be a sibling behind the Qt content view");
  require([effect isKindOfClass:NSVisualEffectView.class], "background must retain native visual effects");
  require([content.superview.subviews indexOfObject:effect] < [content.superview.subviews indexOfObject:content], "Qt content must composite above native blur");
  require(NSEqualRects(effect.frame, content.frame), "native blur must cover the content geometry");

  QEventLoop painted;
  QTimer deadline;
  deadline.setSingleShot(true);
  QObject::connect(&deadline, &QTimer::timeout, &painted, &QEventLoop::quit);
  QObject::connect(&window, &QQuickWindow::frameSwapped, &painted, &QEventLoop::quit, Qt::QueuedConnection);
  deadline.start(frame_timeout_ms);
  window.show();
  painted.exec();
  require(deadline.isActive(), "native blurred window must present a Qt frame");
  deadline.stop();

  configureWindow(window, blurred);
  require(effectIn(content.superview) == effect, "appearance reload must reuse its existing effect");
  window.resize(resized_size);
  QGuiApplication::processEvents();
  require(NSEqualRects(effect.frame, content.frame), "native blur must follow resized content");
  auto titled = blurred;
  titled.titlebar = true;
  configureWindow(window, titled);
  require(NSEqualRects(effect.frame, content.frame), "native blur must follow titlebar changes");
  configureWindow(window, {});
  require(effectIn(content.superview) == nil && effectIn(content) == nil, "disabling blur must remove the native effect");
  require(native.opaque, "opaque configuration must restore an opaque window");
  configureWindow(window, blurred);
  require(effectIn(content.superview) != nil && effectIn(content) == nil, "re-enabling blur must keep content unobscured");
}

}

int main(int argc, char **argv) {
  try {
    const QGuiApplication application{argc, argv};
    telar::gui::platform::configureGraphics();
    verifyAppearance();
    std::cout << "native window appearance passed\n";

    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
