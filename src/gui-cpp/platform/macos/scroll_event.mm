#include "platform/scroll_event.hpp"
#include "input/wheel_accumulator.hpp"
#include <AppKit/AppKit.h>
#include <QWindow>
#include <bit>
#include <cmath>
#include <optional>
#include <string_view>

namespace telar::gui::platform {
namespace {

ScrollPhase scrollPhase(NSEventPhase phase) noexcept {
  if ((phase & NSEventPhaseCancelled) != 0) {
    return ScrollPhase::cancel;
  }

  if ((phase & NSEventPhaseEnded) != 0) {
    return ScrollPhase::end;
  }

  if ((phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) != 0) {
    return ScrollPhase::begin;
  }

  if ((phase & (NSEventPhaseChanged | NSEventPhaseStationary)) != 0) {
    return ScrollPhase::update;
  }

  return ScrollPhase::none;
}

}

std::optional<NativeScrollInput> nativeScrollInput(std::string_view event_type, const void *message, const QWindow &window) noexcept {
  if ((event_type != "mac_generic_NSEvent" && event_type != "NSEvent") || message == nullptr || window.handle() == nullptr) {
    return {};
  }

  const auto *const event = (__bridge NSEvent *)message;
  if (event.type != NSEventTypeScrollWheel) {
    return {};
  }

  const auto *const view = (__bridge NSView *)std::bit_cast<const void *>(window.winId());
  if (event.window != view.window) {
    return {};
  }

  const auto point = [view convertPoint:event.locationInWindow fromView:nil];
  const auto y = view.isFlipped ? point.y : view.bounds.size.height - point.y;
  const auto delta = -event.scrollingDeltaY;

  return NativeScrollInput{.sample = {.delta = delta, .precise = static_cast<bool>(event.hasPreciseScrollingDeltas), .phase = scrollPhase(event.phase)}, .x = point.x, .y = y, .valid = std::isfinite(point.x) && std::isfinite(y) && std::isfinite(delta)};
}

}
