#include "animation_presentation.hpp"
#include <AppKit/AppKit.h>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>
#include <objc/runtime.h>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickWindow>
#include <atomic>
#include <bit>
#include <cstddef>
#include <cstdint>

namespace telar::gui::probe {
namespace {

IMP original_next;
id<CAMetalDrawable> current_drawable;
QJsonArray presentations;
std::atomic<bool> synchronized_display{true};

id nextDrawable(CAMetalLayer *layer, SEL selector) {
  current_drawable = std::bit_cast<id (*)(id, SEL)>(original_next)(layer, selector);
  if (!layer.displaySyncEnabled) {
    synchronized_display.store(false, std::memory_order_relaxed);
  }
  return current_drawable;
}

}

void observeAnimationPresentation() {
  original_next = method_setImplementation(class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable)), std::bit_cast<IMP>(&nextDrawable));
}

void recordAnimationPresentation(std::uint64_t cycle, double value) {
  if (current_drawable == nil || cycle == 0) {
    return;
  }

  [current_drawable addPresentedHandler:^(id<MTLDrawable> drawable) {
    const auto timestamp = drawable.presentedTime;
    dispatch_async(dispatch_get_main_queue(), ^{
      presentations.append(QJsonObject{{QStringLiteral("cycle"), static_cast<qint64>(cycle)}, {QStringLiteral("value"), value}, {QStringLiteral("presented_seconds"), timestamp}});
    });
  }];
  current_drawable = nil;
}

QJsonArray animationPresentations() {
  return presentations;
}

QJsonObject animationDisplay(const QQuickWindow &window) {
  auto *const view = (__bridge NSView *)std::bit_cast<const void *>(window.winId());
  NSScreen *const screen = view.window.screen;
  return {
      {QStringLiteral("name"), QString::fromNSString(screen.localizedName)},
      {QStringLiteral("maximum_fps"), static_cast<int>(screen.maximumFramesPerSecond)},
      {QStringLiteral("display_sync_enabled"), synchronized_display.load(std::memory_order_relaxed)},
      {QStringLiteral("device_pixel_ratio"), window.effectiveDevicePixelRatio()},
  };
}

}
