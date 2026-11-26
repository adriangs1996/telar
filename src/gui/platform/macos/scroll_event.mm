#include "platform/macos/scroll_event_bridge.h"
#include <AppKit/AppKit.h>
#include <cmath>
#include <cstdint>

namespace {

  constexpr std::uint8_t phase_none = 0;
  constexpr std::uint8_t phase_begin = 1;
  constexpr std::uint8_t phase_update = 2;
  constexpr std::uint8_t phase_end = 3;
  constexpr std::uint8_t phase_cancel = 4;

  std::uint8_t scrollPhase(NSEventPhase phase) noexcept {
    if ((phase & NSEventPhaseCancelled) != 0) {
      return phase_cancel;
    }

    if ((phase & NSEventPhaseEnded) != 0) {
      return phase_end;
    }

    if ((phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) != 0) {
      return phase_begin;
    }

    if ((phase & (NSEventPhaseChanged | NSEventPhaseStationary)) != 0) {
      return phase_update;
    }

    return phase_none;
  }

}

bool telarGuiReadNativeScrollInput(const void* event_message, const void* ns_view, TelarGuiNativeScrollInput* out) {
  if (event_message == nullptr || ns_view == nullptr || out == nullptr) {
    return false;
  }

  const auto* const event = (__bridge NSEvent*)event_message;

  if (event.type != NSEventTypeScrollWheel) {
    return false;
  }

  const auto* const view = (__bridge NSView*)ns_view;

  if (event.window != view.window) {
    return false;
  }

  const auto point = [view convertPoint:event.locationInWindow fromView:nil];
  const auto y = view.isFlipped ? point.y : view.bounds.size.height - point.y;
  const auto delta = -event.scrollingDeltaY;

  *out = TelarGuiNativeScrollInput{
      .delta = delta,
      .x = point.x,
      .y = y,
      .phase = scrollPhase(event.phase),
      .precise = static_cast<bool>(event.hasPreciseScrollingDeltas),
      .valid = std::isfinite(point.x) && std::isfinite(y) && std::isfinite(delta),
  };

  return true;
}
