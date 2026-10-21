#include "surface_bridge.hpp"
#include "ui/quick_surface.hpp"
#include <QCoreApplication>
#include <QEnterEvent>
#include <QGuiApplication>
#include <QMouseEvent>
#include <QPointer>
#include <algorithm>

namespace {
  QVariantMap rectangle(NSRect rect) {
    return {{"x", rect.origin.x},
            {"y", rect.origin.y},
            {"width", rect.size.width},
            {"height", rect.size.height}};
  }

  NSRect desktopRect(NSRect rect) {
    const auto top = NSMaxY(NSScreen.screens.firstObject.frame);

    return NSMakeRect(NSMinX(rect), top - NSMaxY(rect), NSWidth(rect), NSHeight(rect));
  }
} // namespace

@implementation TelarSurfaceBridge {
  __weak NSView *_view;
  __weak NSWindow *_panel;
  NSTrackingArea *_tracking_area;
  QuickSurface *_surface;
  QPointer<QQuickWindow> _window;
}

- (instancetype)initWithView:(NSView *)view surface:(QuickSurface &)surface {
  self = [super init];

  if (self) {
    _view = view;
    _panel = view.window;
    _surface = &surface;
    _window = &surface.window();

    if (!_panel.ignoresMouseEvents) {
      const auto options = NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                           NSTrackingActiveAlways | NSTrackingInVisibleRect;
      _tracking_area = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                    options:options
                                                      owner:self
                                                   userInfo:nil];
      [view addTrackingArea:_tracking_area];
    }

    __weak TelarSurfaceBridge *weak_self = self;
    surface.setFocusHandler([weak_self] {
      TelarSurfaceBridge *bridge = weak_self;

      if (bridge) {
        NSWindow *panel = bridge->_panel;

        if (!panel.canBecomeKeyWindow) {
          return;
        }

        [panel makeKeyWindow];
        [panel makeFirstResponder:bridge->_view];
        [bridge updateState:nil];
      }
    });

    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;

    for (NSNotificationName name in @[
           NSWindowDidChangeScreenNotification,
           NSWindowDidChangeBackingPropertiesNotification,
           NSWindowDidResizeNotification,
           NSWindowDidMoveNotification,
           NSWindowDidBecomeKeyNotification,
           NSWindowDidResignKeyNotification,
           NSWindowDidChangeOcclusionStateNotification,
           NSWindowDidExposeNotification,
           NSWindowDidMiniaturizeNotification,
           NSWindowDidDeminiaturizeNotification,
         ]) {
      [notifications addObserver:self selector:@selector(updateState:) name:name object:_panel];
    }

    [notifications addObserver:self
                      selector:@selector(updateState:)
                          name:NSApplicationDidChangeScreenParametersNotification
                        object:nil];
    [self updateState:nil];
  }

  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  if (_tracking_area) {
    [_view removeTrackingArea:_tracking_area];
  }

  if (_window) {
    _surface->setFocusHandler({});
  }
}

- (void)updateState:(NSNotification *)notification {
  NSView *view = _view;
  NSWindow *panel = _panel;
  NSScreen *screen = panel.screen;

  if (!_window || !view || !panel || !screen) {
    return;
  }

  const auto bounds = view.bounds;
  const auto frame = [panel convertRectToScreen:[view convertRect:bounds toView:nil]];
  const auto screen_frame = screen.frame;
  QVariantMap safe{{"top", 0.0}, {"left", 0.0}, {"right", 0.0}, {"bottom", 0.0}};
  QVariantList exclusions;

  if (@available(macOS 12.0, *)) {
    const auto insets = screen.safeAreaInsets;
    safe.insert(
        "left",
        std::clamp(NSMinX(screen_frame) + insets.left - NSMinX(frame), 0.0, NSWidth(frame)));
    safe.insert(
        "right",
        std::clamp(NSMaxX(frame) - NSMaxX(screen_frame) + insets.right, 0.0, NSWidth(frame)));
    safe.insert(
        "top",
        std::clamp(NSMaxY(frame) - NSMaxY(screen_frame) + insets.top, 0.0, NSHeight(frame)));
    safe.insert(
        "bottom",
        std::clamp(NSMinY(screen_frame) + insets.bottom - NSMinY(frame), 0.0, NSHeight(frame)));
    const auto left = screen.auxiliaryTopLeftArea;
    const auto right = screen.auxiliaryTopRightArea;
    NSRect excluded = NSMakeRect(NSMinX(screen_frame),
                                 NSMaxY(screen_frame) - insets.top,
                                 NSWidth(screen_frame),
                                 insets.top);

    if (!NSIsEmptyRect(left) && !NSIsEmptyRect(right)) {
      excluded = NSMakeRect(NSMaxX(left),
                            NSMinY(left),
                            NSMinX(right) - NSMaxX(left),
                            std::max(NSHeight(left), NSHeight(right)));
    }

    const auto overlap = NSIntersectionRect(frame, excluded);

    if (!NSIsEmptyRect(overlap)) {
      exclusions.append(rectangle(NSMakeRect(NSMinX(overlap) - NSMinX(frame),
                                             NSMaxY(frame) - NSMaxY(overlap),
                                             NSWidth(overlap),
                                             NSHeight(overlap))));
    }
  }

  safe.insert("exclusions", exclusions);
  const QVariantMap monitor{{"name", QString::fromUtf8(screen.localizedName.UTF8String)},
                            {"id", [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]},
                            {"geometry", rectangle(desktopRect(screen.frame))},
                            {"available_geometry", rectangle(desktopRect(screen.visibleFrame))}};
  const auto size = QSize(static_cast<int>(NSWidth(bounds)), static_cast<int>(NSHeight(bounds)));

  if (_window->size() != size) {
    _window->resize(size);
  }

  _surface->setNativeState({{"screen", monitor},
                            {"scale", panel.backingScaleFactor},
                            {"safe_area", safe},
                            {"visible", static_cast<bool>(panel.visible && !panel.miniaturized)},
                            {"active", static_cast<bool>(panel.keyWindow)}});
}

// Cocoa suppresses Qt hover tracking while the application is inactive.
- (void)forwardEvent:(NSEvent *)event type:(QEvent::Type)type {
  if (!_window || NSApp.active) {
    return;
  }

  if (type == QEvent::Leave) {
    QEvent leave(QEvent::Leave);
    QCoreApplication::sendEvent(_window.data(), &leave);
    return;
  }

  NSView *view = _view;

  if (!view) {
    return;
  }

  const NSPoint position = [view convertPoint:event.locationInWindow fromView:nil];
  const QPointF local(position.x, view.flipped ? position.y : NSHeight(view.bounds) - position.y);
  const auto global = _window->mapToGlobal(local);

  if (type == QEvent::Enter) {
    QEnterEvent enter(local, local, global);
    QCoreApplication::sendEvent(_window.data(), &enter);
  } else {
    const auto buttons = QGuiApplication::mouseButtons();
    QMouseEvent move(QEvent::MouseMove,
                     local,
                     local,
                     global,
                     Qt::NoButton,
                     buttons,
                     QGuiApplication::queryKeyboardModifiers());
    move.setTimestamp(static_cast<quint64>(event.timestamp * 1000));
    QCoreApplication::sendEvent(_window.data(), &move);
  }
}

- (void)mouseEntered:(NSEvent *)event {
  [self forwardEvent:event type:QEvent::Enter];
}

- (void)mouseMoved:(NSEvent *)event {
  [self forwardEvent:event type:QEvent::MouseMove];
}

- (void)mouseExited:(NSEvent *)event {
  [self forwardEvent:event type:QEvent::Leave];
}

@end
