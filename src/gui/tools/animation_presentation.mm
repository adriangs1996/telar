#include "animation_presentation.hpp"
#include <AppKit/AppKit.h>
#include <Metal/Metal.h>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickWindow>
#include <QuartzCore/CAMetalLayer.h>
#include <atomic>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <objc/runtime.h>

namespace telar::gui::probe {
  namespace {

    struct Presentation {
      id<CAMetalDrawable> current_drawable;
      QJsonArray presentations;
      std::atomic<bool> synchronized_display{true};
    };

    Presentation& presentation() {
      static Presentation state;

      return state;
    }

  }
}

@interface CAMetalLayer (TelarAnimationProbe)
- (id<CAMetalDrawable>)telarProbeNextDrawable;
@end

@implementation CAMetalLayer (TelarAnimationProbe)

- (id<CAMetalDrawable>)telarProbeNextDrawable {
  auto& state = telar::gui::probe::presentation();

  // The implementations are exchanged, so this message runs the original -nextDrawable.
  state.current_drawable = [self telarProbeNextDrawable];
  if (!self.displaySyncEnabled) {
    state.synchronized_display.store(false, std::memory_order_relaxed);
  }

  return state.current_drawable;
}

@end

namespace telar::gui::probe {

  void observeAnimationPresentation() {
    const Method original = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    const Method replacement = class_getInstanceMethod(CAMetalLayer.class, @selector(telarProbeNextDrawable));
    if (original == nullptr || replacement == nullptr) {
      return;
    }

    method_exchangeImplementations(original, replacement);
  }

  void recordAnimationPresentation(std::uint64_t cycle, double value) {
    auto& state = presentation();
    if (state.current_drawable == nil || cycle == 0) {
      return;
    }

    [state.current_drawable addPresentedHandler:^(id<MTLDrawable> drawable) {
      const auto timestamp = drawable.presentedTime;

      dispatch_async(dispatch_get_main_queue(), ^{
        presentation().presentations.append(QJsonObject{{QStringLiteral("cycle"), static_cast<qint64>(cycle)}, {QStringLiteral("value"), value}, {QStringLiteral("presented_seconds"), timestamp}});
      });
    }];

    state.current_drawable = nil;
  }

  QJsonArray animationPresentations() {
    return presentation().presentations;
  }

  QJsonObject animationDisplay(const QQuickWindow& window) {
    auto* const view = (__bridge NSView*)std::bit_cast<const void*>(window.winId());
    NSScreen* const screen = view.window.screen;

    return {
        {QStringLiteral("name"), QString::fromNSString(screen.localizedName)},
        {QStringLiteral("maximum_fps"), static_cast<int>(screen.maximumFramesPerSecond)},
        {QStringLiteral("display_sync_enabled"), presentation().synchronized_display.load(std::memory_order_relaxed)},
        {QStringLiteral("device_pixel_ratio"), window.effectiveDevicePixelRatio()},
    };
  }

}
