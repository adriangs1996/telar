#include "platform/window.hpp"
#include "blur_radius.hpp"
#include "blur_symbols.h"
#include <AppKit/AppKit.h>
#include <objc/runtime.h>
#include <QGuiApplication>
#include <QObject>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QWindow>
#include <QtCore/qtenvironmentvariables.h>
#include <bit>
#include <cmath>
#include <cstdint>
#include <memory>
#include <tuple>

namespace telar::gui::platform {

namespace {

constexpr CGFloat controls_leading = 14;
constexpr CGFloat controls_pitch = 20;
constexpr CGFloat controls_trailing = 10;

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

  NSButton *const button = [native_window standardWindowButton:NSWindowZoomButton];
  constexpr CGFloat controls_gaps = 2;

  return static_cast<float>(controls_leading + (controls_gaps * controls_pitch) + button.frame.size.width + controls_trailing);
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

  if (!appearance.titlebar && (native_window.styleMask & NSWindowStyleMaskFullScreen) == 0) {
    auto *const container = [native_window standardWindowButton:NSWindowCloseButton].superview.superview;
    if (container == nil) {
      return;
    }

    auto bar = container.frame;
    bar.size.height = appearance.navigation_height;
    bar.origin.y = native_window.frame.size.height - bar.size.height;
    container.frame = bar;
    CGFloat horizontal = controls_leading;
    for (const auto button : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
      NSButton *const control = [native_window standardWindowButton:button];
      NSRect frame = control.frame;
      frame.origin.x = horizontal;
      frame.origin.y = std::round((appearance.navigation_height - frame.size.height) / 2);
      horizontal += controls_pitch;
      control.frame = frame;
    }
  }
}

}
