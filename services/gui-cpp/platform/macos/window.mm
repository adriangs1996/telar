#include "platform/window.hpp"
#include <AppKit/AppKit.h>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QWindow>
#include <QtCore/qtenvironmentvariables.h>
#include <bit>
#include <cmath>

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

  NSView *const content = native_window.contentView;
  NSVisualEffectView *effect = nil;
  for (NSView *child in content.subviews) {
    if ([child.identifier isEqualToString:@"telar.background.blur"]) {
      effect = (NSVisualEffectView *)child;

      break;
    }
  }

  if (appearance.background_blur == 0) {
    [effect removeFromSuperview];
  } else {
    if (effect == nil) {
      effect = [[NSVisualEffectView alloc] initWithFrame:content.bounds];
      effect.identifier = @"telar.background.blur";
      effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      effect.material = NSVisualEffectMaterialUnderWindowBackground;
      effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
      effect.state = NSVisualEffectStateFollowsWindowActiveState;
      [content addSubview:effect positioned:NSWindowBelow relativeTo:nil];
    }
  }

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
