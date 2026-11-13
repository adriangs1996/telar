#include "assertions.hpp"
#include "input/wheel_accumulator.hpp"
#include "platform/scroll_event.hpp"
#include <AppKit/AppKit.h>
#include <QGuiApplication>
#include <QWindow>
#include <array>
#include <bit>
#include <exception>
#include <initializer_list>
#include <iostream>
#include <limits>
#include <utility>

@interface NativeScrollFixture : NSEvent
@property(nonatomic, weak) NSWindow *target;
@property(nonatomic) NSPoint point;
@property(nonatomic) double delta;
@property(nonatomic) BOOL precise;
@property(nonatomic) NSEventPhase scrollPhase;
@property(nonatomic) NSEventPhase momentum;
@end

@implementation NativeScrollFixture

- (NSWindow *)window {
  return self.target;
}

- (NSEventType)type {
  return NSEventTypeScrollWheel;
}

- (NSPoint)locationInWindow {
  return self.point;
}

- (CGFloat)scrollingDeltaY {
  return self.delta;
}

- (BOOL)hasPreciseScrollingDeltas {
  return self.precise;
}

- (NSEventPhase)phase {
  return self.scrollPhase;
}

- (NSEventPhase)momentumPhase {
  return self.momentum;
}

@end

namespace {

using telar::gui::ScrollPhase;
using telar::gui::platform::nativeScrollInput;
using telar::gui::test::require;

void verifyNativeScroll() {
  QWindow window;
  constexpr int window_width = 320;
  constexpr int window_height = 200;
  window.resize(window_width, window_height);
  window.create();
  const auto *const view = (__bridge NSView *)std::bit_cast<const void *>(window.winId());
  auto *const event = [NativeScrollFixture new];
  event.target = view.window;
  constexpr double x = 8.125;
  constexpr double y = 12.875;
  event.point = [view convertPoint:NSMakePoint(x, view.isFlipped ? y : view.bounds.size.height - y) toView:nil];
  constexpr double fractional_delta = 0.375;
  event.delta = fractional_delta;
  event.precise = YES;
  const auto phases = std::to_array<std::pair<NSEventPhase, ScrollPhase>>({
      {NSEventPhaseNone, ScrollPhase::none},
      {NSEventPhaseBegan, ScrollPhase::begin},
      {NSEventPhaseMayBegin, ScrollPhase::begin},
      {NSEventPhaseStationary, ScrollPhase::update},
      {NSEventPhaseChanged, ScrollPhase::update},
      {NSEventPhaseEnded, ScrollPhase::end},
      {NSEventPhaseCancelled, ScrollPhase::cancel},
      {static_cast<NSEventPhase>(NSEventPhaseCancelled | NSEventPhaseBegan), ScrollPhase::cancel},
  });
  for (const auto &[phase, expected] : phases) {
    event.scrollPhase = phase;
    for (const auto *const type : {"mac_generic_NSEvent", "NSEvent"}) {
      const auto input = nativeScrollInput(type, (__bridge const void *)event, window);
      require(input && input->valid, "owned native wheel must decode through both Qt event kinds");
      require(input->sample.phase == expected, "native phase must preserve begin, cancellation and end");
      require(input->sample.delta == -event.delta && input->sample.precise, "native delta must preserve fractions and direction");
      require(input->x == x && input->y == y, "native position must remain in logical top-left coordinates");
    }
  }

  event.scrollPhase = NSEventPhaseNone;
  event.momentum = NSEventPhaseBegan;
  event.precise = NO;
  const auto momentum = nativeScrollInput("NSEvent", (__bridge const void *)event, window);
  require(momentum && momentum->valid && momentum->sample.phase == ScrollPhase::none && !momentum->sample.precise, "momentum must not invent a new finger gesture or discard a discrete fraction");
  event.delta = std::numeric_limits<double>::quiet_NaN();
  const auto invalid = nativeScrollInput("NSEvent", (__bridge const void *)event, window);
  require(invalid && !invalid->valid, "recognized malformed input must be consumed without changing history");
  require(!nativeScrollInput("unrelated", (__bridge const void *)event, window), "other native sources must pass through");
  require(!nativeScrollInput("NSEvent", nullptr, window), "missing native input must pass through");
  QWindow other;
  require(!nativeScrollInput("NSEvent", (__bridge const void *)event, other), "missing window handle must not create a window");
  other.create();
  require(!nativeScrollInput("NSEvent", (__bridge const void *)event, other), "wheel input must remain scoped to its owning native window");
}

}

int main(int argc, char **argv) {
  const QGuiApplication application(argc, argv);
  try {
    verifyNativeScroll();
    std::cout << "PASS native scroll phases, fractional deltas, coordinates, momentum and window guards\n";

    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
