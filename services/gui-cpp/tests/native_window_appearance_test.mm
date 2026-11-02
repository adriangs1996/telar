#include "assertions.hpp"
#include "platform/window.hpp"
#include <AppKit/AppKit.h>
#include <QEventLoop>
#include <QMouseEvent>
#include <QObject>
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

void requireHiddenTitleLayout(NSWindow *window) {
  require(window.titleVisibility == NSWindowTitleHidden, "custom navigation must hide the native window title");
  require(window.contentLayoutRect.origin.y == 0, "hidden title must not inset the content layout");
  require(window.contentLayoutRect.size.height == window.frame.size.height, "hidden title must not reserve an invisible window-drag strip over the tabs");
}

class NavigationPointerProbe final : public QObject {
public:
  explicit NavigationPointerProbe(QEventLoop &loop)
      : loop_(loop) {}

  int presses = 0;
  int drags = 0;
  int releases = 0;

protected:
  bool eventFilter(QObject *, QEvent *event) override {
    switch (event->type()) {
    case QEvent::MouseButtonPress:
      ++presses;
      return true;
    case QEvent::MouseMove:
      if (static_cast<QMouseEvent *>(event)->buttons().testFlag(Qt::LeftButton)) {
        ++drags;
      }
      return true;
    case QEvent::MouseButtonRelease:
      ++releases;
      loop_.quit();
      return true;
    default:
      return false;
    }
  }

private:
  QEventLoop &loop_;
};

void verifyNavigationMouseDelivery(QQuickWindow &window) {
  auto *const view = (__bridge NSView *)std::bit_cast<const void *>(window.winId());
  NSWindow *const native = view.window;
  constexpr CGFloat navigation_y = 10;
  constexpr CGFloat start_x = 200;
  constexpr CGFloat drag_distance = 80;
  constexpr int timeout_ms = 5'000;
  const auto origin = window.position();
  QEventLoop delivery;
  NavigationPointerProbe probe{delivery};
  window.installEventFilter(&probe);
  QTimer deadline;
  deadline.setSingleShot(true);
  QObject::connect(&deadline, &QTimer::timeout, &delivery, &QEventLoop::quit);
  const auto timestamp = NSProcessInfo.processInfo.systemUptime;
  const auto start = [view convertPoint:NSMakePoint(start_x, view.isFlipped ? navigation_y : view.bounds.size.height - navigation_y) toView:nil];
  const auto end = NSMakePoint(start.x + drag_distance, start.y);
  const auto post = [&](NSEventType type, NSPoint point) {
    NSEvent *const event = [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:timestamp windowNumber:native.windowNumber context:nil eventNumber:0 clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
    [NSApp postEvent:event atStart:NO];
  };
  post(NSEventTypeLeftMouseDown, start);
  post(NSEventTypeLeftMouseDragged, end);
  post(NSEventTypeLeftMouseUp, end);
  deadline.start(timeout_ms);
  delivery.exec();
  window.removeEventFilter(&probe);
  require(probe.presses == 1 && probe.drags > 0 && probe.releases == 1, "native navigation drags must reach Qt instead of AppKit's window-drag strip");
  require(window.position() == origin, "dragging inside navigation must not move the native window");
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
  requireHiddenTitleLayout(native);
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
  verifyNavigationMouseDelivery(window);

  configureWindow(window, blurred);
  requireHiddenTitleLayout(native);
  require(effectIn(content.superview) == effect, "appearance reload must reuse its existing effect");
  window.resize(resized_size);
  QGuiApplication::processEvents();
  require(NSEqualRects(effect.frame, content.frame), "native blur must follow resized content");
  requireHiddenTitleLayout(native);
  auto titled = blurred;
  titled.titlebar = true;
  configureWindow(window, titled);
  require(native.titleVisibility == NSWindowTitleVisible, "enabling the native title must restore its visibility");
  require(native.contentLayoutRect.size.height < native.frame.size.height, "visible title must keep AppKit's original content layout");
  require(NSEqualRects(effect.frame, content.frame), "native blur must follow titlebar changes");
  configureWindow(window, {});
  require(effectIn(content.superview) == nil && effectIn(content) == nil, "disabling blur must remove the native effect");
  require(native.opaque, "opaque configuration must restore an opaque window");
  configureWindow(window, blurred);
  require(effectIn(content.superview) != nil && effectIn(content) == nil, "re-enabling blur must keep content unobscured");
  requireHiddenTitleLayout(native);

  QQuickWindow other;
  other.resize(initial_size);
  other.create();
  auto *const other_view = (__bridge NSView *)std::bit_cast<const void *>(other.winId());
  require(other_view.window.contentLayoutRect.size.height < other_view.window.frame.size.height, "custom navigation must not change the layout of unrelated Qt windows");
  other.show();
  QGuiApplication::processEvents();
  configureWindow(other, blurred);
  requireHiddenTitleLayout(other_view.window);
  configureWindow(other, titled);
  configureWindow(other, blurred);
  requireHiddenTitleLayout(other_view.window);
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
