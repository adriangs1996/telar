#include "objc_case.hpp"
#include "platform/window.hpp"
#include <AppKit/AppKit.h>
#include <QEventLoop>
#include <QGuiApplication>
#include <QMouseEvent>
#include <QObject>
#include <QQuickWindow>
#include <QTimer>
#include <bit>
#include <cmath>

namespace {

  using telar::gui::test::check;

  NSView* effectIn(NSView* parent) {
    for (NSView* child in parent.subviews) {
      if ([child.identifier isEqualToString:@"telar.background.blur"]) {
        return child;
      }
    }

    return nil;
  }

  void requireHiddenTitleLayout(NSWindow* window) {
    check(window.titleVisibility == NSWindowTitleHidden, "custom navigation must hide the native window title");
    check(window.contentLayoutRect.origin.y == 0, "hidden title must not inset the content layout");
    check(window.contentLayoutRect.size.height == window.frame.size.height, "hidden title must not reserve an invisible window-drag strip over the tabs");
  }

  CGFloat controlsPitch(NSWindow* window) {
    return [window standardWindowButton:NSWindowMiniaturizeButton].frame.origin.x - [window standardWindowButton:NSWindowCloseButton].frame.origin.x;
  }

  // The buttons keep AppKit's spacing, sit on the navigation bar's middle line and
  // leave room before the first control drawn by Qt, even after AppKit retiles them.
  void requireNavigationControls(QQuickWindow& window, NSWindow* native, CGFloat navigation_height, CGFloat pitch) {
    const auto middle = native.frame.size.height - (navigation_height / 2);
    CGFloat previous = 0;
    CGFloat trailing = 0;

    for (const auto kind : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
      NSButton* const button = [native standardWindowButton:kind];
      const auto frame = [button convertRect:button.bounds toView:nil];

      check(std::abs(NSMidY(frame) - middle) <= 1, "window controls must be vertically centered in the navigation bar");
      check(previous == 0 || frame.origin.x - previous == pitch, "window controls must keep AppKit's spacing");
      previous = frame.origin.x;
      trailing = NSMaxX(frame);
    }

    check(telar::gui::platform::windowControls(window) > trailing, "navigation controls must start after the window controls");
  }

  class NavigationPointerProbe final : public QObject {
  public:
    explicit NavigationPointerProbe(QEventLoop& loop)
        : loop_(loop) {}

    int presses = 0;
    int drags = 0;
    int releases = 0;

  protected:
    bool eventFilter(QObject*, QEvent* event) override {
      switch (event->type()) {
      case QEvent::MouseButtonPress:
        ++presses;
        return true;
      case QEvent::MouseMove:
        if (static_cast<QMouseEvent*>(event)->buttons().testFlag(Qt::LeftButton)) {
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
    QEventLoop& loop_;
  };

  void verifyNavigationMouseDelivery(QQuickWindow& window) {
    auto* const view = (__bridge NSView*)std::bit_cast<const void*>(window.winId());
    NSWindow* const native = view.window;
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
      NSEvent* const event = [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:timestamp windowNumber:native.windowNumber context:nil eventNumber:0 clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];

      [NSApp postEvent:event atStart:NO];
    };

    post(NSEventTypeLeftMouseDown, start);
    post(NSEventTypeLeftMouseDragged, end);
    post(NSEventTypeLeftMouseUp, end);
    deadline.start(timeout_ms);
    delivery.exec();
    window.removeEventFilter(&probe);
    check(probe.presses == 1 && probe.drags > 0 && probe.releases == 1, "native navigation drags must reach Qt instead of AppKit's window-drag strip");
    check(window.position() == origin, "dragging inside navigation must not move the native window");
  }

  void verifyAppearance() {
    constexpr QSize initial_size{640, 480};
    constexpr QSize resized_size{800, 600};
    constexpr int frame_timeout_ms = 5'000;
    QQuickWindow window;

    window.resize(initial_size);
    window.create();
    auto* const view = (__bridge NSView*)std::bit_cast<const void*>(window.winId());
    NSWindow* const native = view.window;
    NSView* const content = native.contentView;
    using telar::gui::platform::configureWindow;
    const auto pitch = controlsPitch(native);
    const telar::gui::platform::WindowAppearance blurred{.titlebar = false, .navigation_height = 42, .background_opacity = 0.98F, .background_blur = 20};

    configureWindow(window, blurred);
    requireHiddenTitleLayout(native);
    check(native.contentView == content, "appearance must preserve the Qt content view");
    check(effectIn(content) == nil, "native blur must not cover Qt's Metal layer as a child of its content view");
    NSView* const effect = effectIn(content.superview);

    check(effect != nil, "blur must be a sibling behind the Qt content view");
    check([effect isKindOfClass:NSVisualEffectView.class], "background must retain native visual effects");
    check([content.superview.subviews indexOfObject:effect] < [content.superview.subviews indexOfObject:content], "Qt content must composite above native blur");
    check(NSEqualRects(effect.frame, content.frame), "native blur must cover the content geometry");

    QEventLoop painted;
    QTimer deadline;

    deadline.setSingleShot(true);
    QObject::connect(&deadline, &QTimer::timeout, &painted, &QEventLoop::quit);
    QObject::connect(&window, &QQuickWindow::frameSwapped, &painted, &QEventLoop::quit, Qt::QueuedConnection);
    deadline.start(frame_timeout_ms);
    window.show();
    painted.exec();
    check(deadline.isActive(), "native blurred window must present a Qt frame");
    deadline.stop();
    requireNavigationControls(window, native, blurred.navigation_height, pitch);
    verifyNavigationMouseDelivery(window);

    configureWindow(window, blurred);
    requireHiddenTitleLayout(native);
    check(effectIn(content.superview) == effect, "appearance reload must reuse its existing effect");
    window.resize(resized_size);
    QGuiApplication::processEvents();
    check(NSEqualRects(effect.frame, content.frame), "native blur must follow resized content");
    requireHiddenTitleLayout(native);
    requireNavigationControls(window, native, blurred.navigation_height, pitch);
    auto titled = blurred;

    titled.titlebar = true;
    configureWindow(window, titled);
    check(native.titleVisibility == NSWindowTitleVisible, "enabling the native title must restore its visibility");
    check(native.contentLayoutRect.size.height < native.frame.size.height, "visible title must keep AppKit's original content layout");
    check(NSEqualRects(effect.frame, content.frame), "native blur must follow titlebar changes");
    configureWindow(window, {});
    check(effectIn(content.superview) == nil && effectIn(content) == nil, "disabling blur must remove the native effect");
    check(native.opaque, "opaque configuration must restore an opaque window");
    configureWindow(window, blurred);
    check(effectIn(content.superview) != nil && effectIn(content) == nil, "re-enabling blur must keep content unobscured");
    requireHiddenTitleLayout(native);

    QQuickWindow other;

    other.resize(initial_size);
    other.create();
    auto* const other_view = (__bridge NSView*)std::bit_cast<const void*>(other.winId());

    check(other_view.window.contentLayoutRect.size.height < other_view.window.frame.size.height, "custom navigation must not change the layout of unrelated Qt windows");
    other.show();
    QGuiApplication::processEvents();
    configureWindow(other, blurred);
    requireHiddenTitleLayout(other_view.window);
    configureWindow(other, titled);
    configureWindow(other, blurred);
    requireHiddenTitleLayout(other_view.window);
  }

  void configuredAppearance() {
    telar::gui::platform::configureGraphics();
    verifyAppearance();
  }

  const telar::gui::test::ObjcCase case_verify_appearance{"native_window_appearance.verify_appearance", configuredAppearance};

}
