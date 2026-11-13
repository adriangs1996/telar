#include "platform/window.hpp"
#include "blur_radius.hpp"
#include "blur_symbols.h"
#include <AppKit/AppKit.h>
#include <objc/runtime.h>
#include <QGuiApplication>
#include <QMetaObject>
#include <QObject>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QWindow>
#include <QtCore/qtenvironmentvariables.h>
#include <qpa/qplatformwindow.h>
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <memory>
#include <tuple>

namespace telar::gui::platform {

bool supportsImmediateWindowUpdates() {
  return QGuiApplication::platformName() == QLatin1StringView{"cocoa"};
}

void deliverPendingWindowUpdate(QWindow &window) {
  if (auto *handle = window.handle(); handle != nullptr && handle->hasPendingUpdateRequest()) {
    handle->deliverUpdateRequest();
  }
}

namespace {

constexpr CGFloat controls_leading = 16;
constexpr CGFloat controls_trailing = 16;

NSWindow *nativeWindow(const QWindow &window) {
  if (window.handle() == nullptr) {
    return nil;
  }

  const auto *const handle = std::bit_cast<const void *>(window.winId());
  auto *const view = (__bridge NSView *)handle;

  return view.window;
}

char content_layout_key;

// Opt in individual windows without changing their class: Qt/AppKit can already
// be observing them through KVO. Other Qt windows retain their original layout.
void configureContentLayout(NSWindow *window) {
  objc_setAssociatedObject(window, &content_layout_key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  Class base = window.class;
  if (objc_getAssociatedObject(base, &content_layout_key) != nil) {
    return;
  }

  const SEL selector = @selector(contentLayoutRect);
  const Method method = class_getInstanceMethod(base, selector);
  const auto original = std::bit_cast<NSRect (*)(NSWindow *, SEL)>(method_getImplementation(method));
  const IMP replacement = imp_implementationWithBlock(^NSRect(NSWindow *native) {
    auto rect = original(native, selector);
    const auto style = native.styleMask;
    if (objc_getAssociatedObject(native, &content_layout_key) != nil && (style & NSWindowStyleMaskFullSizeContentView) != 0 && (style & NSWindowStyleMaskFullScreen) == 0) {
      rect.origin.y = 0;
      rect.size.height = native.frame.size.height;
    }

    return rect;
  });
  class_replaceMethod(base, selector, replacement, method_getTypeEncoding(method));
  objc_setAssociatedObject(base, &content_layout_key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

NativeBlurFunctions blurFunctions() noexcept {
  const auto symbols = telarGuiBlurSymbols();
  return {.connection = symbols.connection, .set_radius = symbols.set_radius};
}

class WindowBlur final : public QObject {
public:
  explicit WindowBlur(QWindow &window)
      : QObject(&window),
        window_(window),
        radius_(blurFunctions()) {
    connect(&window_, &QWindow::visibleChanged, this, [this](bool visible) {
      if (visible) {
        apply();
      }
    });
    connect(&window_, &QWindow::windowStateChanged, this, [this] {
      apply();
    });
    connect(&window_, &QWindow::widthChanged, this, [this] {
      apply();
    });
    connect(&window_, &QWindow::heightChanged, this, [this] {
      apply();
    });
  }

  void set(WindowAppearance appearance) {
    appearance_ = appearance;
    apply();
  }

private:
  void apply() {
    NSWindow *const window = nativeWindow(window_);
    if (window == nil) {
      return;
    }
    const bool numeric = radius_.apply({.number = static_cast<std::int64_t>(window.windowNumber), .style = static_cast<std::uint64_t>(window.styleMask)}, appearance_);
    NSView *const content = window.contentView;
    NSView *const backdrop = content.superview;
    NSVisualEffectView *effect = nil;
    for (NSView *child in backdrop.subviews) {
      if ([child.identifier isEqualToString:@"telar.background.blur"]) {
        effect = (NSVisualEffectView *)child;
        break;
      }
    }
    if (appearance_.background_opacity >= 1 || appearance_.background_blur == 0) {
      [effect removeFromSuperview];
      return;
    }
    if (effect == nil) {
      effect = [[NSVisualEffectView alloc] initWithFrame:content.frame];
      effect.identifier = @"telar.background.blur";
      effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      effect.material = NSVisualEffectMaterialUnderWindowBackground;
      effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
      effect.state = NSVisualEffectStateActive;
      [backdrop addSubview:effect positioned:NSWindowBelow relativeTo:content];
    }
    effect.frame = content.frame;
    effect.hidden = numeric;
  }

  QWindow &window_;
  WindowAppearance appearance_;
  BlurRadius radius_;
};

constexpr std::array control_kinds{NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};

// AppKit lays the title bar out again whenever it retiles the window (showing it,
// resizing it, leaving full screen), putting the buttons back in its own 32-point
// strip. Every relayout moves a button or the container, so their frame
// notifications give the last word back to the navigation bar's geometry. AppKit
// posts them from inside its own setters, which overwrite a frame set there, so the
// layout is applied once that pass returns.
class WindowControls final : public QObject {
public:
  explicit WindowControls(QWindow &window)
      : QObject(&window),
        window_(window) {}

  ~WindowControls() override {
    observe(nil);
  }

  WindowControls(const WindowControls &) = delete;
  WindowControls &operator=(const WindowControls &) = delete;
  WindowControls(WindowControls &&) = delete;
  WindowControls &operator=(WindowControls &&) = delete;

  void set(WindowAppearance appearance) {
    height_ = appearance.navigation_height;
    NSWindow *const window = nativeWindow(window_);
    observe(appearance.titlebar ? nil : window);
    apply();
  }

  [[nodiscard]] float inset() const noexcept {
    return observed_ == nil ? 0 : static_cast<float>(controls_leading + (2 * pitch_) + side_ + controls_trailing);
  }

private:
  void observe(NSWindow *window) {
    if (window == observed_) {
      return;
    }

    for (id token in tokens_) {
      [NSNotificationCenter.defaultCenter removeObserver:token];
    }
    tokens_ = nil;
    views_ = nil;
    observed_ = window;
    if (window == nil) {
      return;
    }

    // Measured once, before any move: the native spacing differs between releases.
    NSButton *const close = [window standardWindowButton:NSWindowCloseButton];
    NSButton *const zoom = [window standardWindowButton:NSWindowZoomButton];
    side_ = zoom.frame.size.width;
    pitch_ = std::max(side_, (zoom.frame.origin.x - close.frame.origin.x) / 2);
  }

  // Re-registers when AppKit replaced the title bar views, and only then.
  void track(NSArray<NSView *> *views) {
    if ([views isEqualToArray:views_]) {
      return;
    }

    for (id token in tokens_) {
      [NSNotificationCenter.defaultCenter removeObserver:token];
    }
    views_ = views;
    auto *const tokens = [NSMutableArray arrayWithCapacity:views.count];
    for (NSView *view in views) {
      view.postsFrameChangedNotifications = YES;
      [tokens addObject:[NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification object:view queue:nil usingBlock:^(NSNotification *) {
        schedule();
      }]];
    }
    tokens_ = tokens;
  }

  void schedule() {
    if (applying_ || pending_) {
      return;
    }

    pending_ = true;
    QMetaObject::invokeMethod(
        this, [this] {
          pending_ = false;
          apply();
        },
        Qt::QueuedConnection);
  }

  void apply() {
    NSWindow *const window = observed_;
    if (applying_ || window == nil || (window.styleMask & NSWindowStyleMaskFullScreen) != 0) {
      return;
    }

    NSButton *const close = [window standardWindowButton:NSWindowCloseButton];
    NSView *const container = close.superview.superview;
    if (container == nil) {
      return;
    }

    applying_ = true;
    auto bar = container.frame;
    bar.size.height = height_;
    bar.origin.y = window.frame.size.height - height_;
    if (!NSEqualRects(bar, container.frame)) {
      container.frame = bar;
    }

    auto *const views = [NSMutableArray<NSView *> arrayWithObject:container];
    CGFloat horizontal = controls_leading;
    for (const auto kind : control_kinds) {
      NSButton *const control = [window standardWindowButton:kind];
      const NSPoint origin{.x = horizontal, .y = std::round((height_ - control.frame.size.height) / 2)};
      if (!NSEqualPoints(origin, control.frame.origin)) {
        [control setFrameOrigin:origin];
      }
      horizontal += pitch_;
      [views addObject:control];
    }
    applying_ = false;
    track(views);
  }

  QWindow &window_;
  NSWindow *__weak observed_ = nil;
  NSArray<NSView *> *views_ = nil;
  NSArray *tokens_ = nil;
  CGFloat height_ = WindowAppearance::default_navigation_height;
  CGFloat pitch_ = 0;
  CGFloat side_ = 0;
  bool applying_ = false;
  bool pending_ = false;
};

WindowControls *controlsOf(const QWindow &window) {
  for (auto *child : window.children()) {
    if (auto *controls = dynamic_cast<WindowControls *>(child)) {
      return controls;
    }
  }

  return nullptr;
}

void configureControls(QWindow &window, WindowAppearance appearance) {
  if (auto *const controls = controlsOf(window)) {
    controls->set(appearance);
    return;
  }
  auto controls = std::make_unique<WindowControls>(window);
  controls->set(appearance);
  std::ignore = controls.release();
}

void configureBlur(QWindow &window, WindowAppearance appearance) {
  for (auto *child : window.children()) {
    if (auto *blur = dynamic_cast<WindowBlur *>(child)) {
      blur->set(appearance);
      return;
    }
  }
  auto blur = std::make_unique<WindowBlur>(window);
  blur->set(appearance);
  std::ignore = blur.release();
}
}

// Press-and-hold accents swallow the repeats of a held letter. Disable them in
// this process's volatile argument domain, before Qt creates NSApplication, so
// held keys repeat at the system rate without writing the user's preferences.
void configureKeyRepeat() {
  NSUserDefaults *preferences = NSUserDefaults.standardUserDefaults;
  NSMutableDictionary *arguments = [[preferences volatileDomainForName:NSArgumentDomain] mutableCopy];
  arguments[@"ApplePressAndHoldEnabled"] = @NO;
  [preferences setVolatileDomain:arguments forName:NSArgumentDomain];
}

void configureGraphics() {
  if (!qEnvironmentVariableIsSet("QSG_RHI_BACKEND") && !qEnvironmentVariableIsSet("QT_QUICK_BACKEND")) {
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
  }
}

bool defaultTitlebar() noexcept {
  return false;
}

bool usesCommandKey() noexcept {
  return true;
}

float windowControls(const QWindow &window) noexcept {
  if (QGuiApplication::platformName() != QLatin1StringView("cocoa")) {
    return 0;
  }

  NSWindow *const native_window = nativeWindow(window);
  if (native_window == nil || (native_window.styleMask & NSWindowStyleMaskFullSizeContentView) == 0 || (native_window.styleMask & NSWindowStyleMaskFullScreen) != 0) {
    return 0;
  }

  const auto *const controls = controlsOf(window);

  return controls == nullptr ? 0 : controls->inset();
}

void configureWindow(QWindow &window, WindowAppearance appearance) {
  if (QGuiApplication::platformName() != QLatin1StringView("cocoa")) {
    return;
  }

  window.create();
  NSWindow *const native_window = nativeWindow(window);
  if (native_window == nil) {
    return;
  }

  configureContentLayout(native_window);
  native_window.titleVisibility = appearance.titlebar ? NSWindowTitleVisible : NSWindowTitleHidden;
  native_window.titlebarAppearsTransparent = !appearance.titlebar;
  if (appearance.titlebar) {
    native_window.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
  } else {
    native_window.styleMask |= NSWindowStyleMaskFullSizeContentView;
  }

  native_window.tabbingMode = NSWindowTabbingModeDisallowed;
  native_window.opaque = appearance.background_opacity >= 1;
  if (!native_window.opaque) {
    native_window.backgroundColor = NSColor.clearColor;
  }

  configureBlur(window, appearance);
  configureControls(window, appearance);
}

}
