#include "foundation/core/wheel_accumulator.hpp"
#include "objc_case.hpp"
#include "platform/scroll_event.hpp"
#include "telar_base/ds/values.hpp"
#include <AppKit/AppKit.h>
#include <QWindow>
#include <array>
#include <bit>
#include <initializer_list>
#include <limits>
#include <utility>

@interface NativeScrollFixture : NSEvent
@property(nonatomic, weak) NSWindow* target;
@property(nonatomic) NSPoint point;
@property(nonatomic) double delta;
@property(nonatomic) BOOL precise;
@property(nonatomic) NSEventPhase scrollPhase;
@property(nonatomic) NSEventPhase momentum;
@end

@implementation NativeScrollFixture

- (NSWindow*)window {
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
  using telar::gui::test::check;

  void verifyNativeScroll() {
    QWindow window;
    constexpr int window_width = 320;
    constexpr int window_height = 200;

    window.resize(window_width, window_height);
    window.create();
    const auto* const view = (__bridge NSView*)std::bit_cast<const void*>(window.winId());
    auto* const event = [NativeScrollFixture new];

    event.target = view.window;
    constexpr double x = 8.125;
    constexpr double y = 12.875;

    event.point = [view convertPoint:NSMakePoint(x, view.isFlipped ? y : view.bounds.size.height - y) toView:nil];
    constexpr double fractional_delta = 0.375;

    event.delta = fractional_delta;
    event.precise = YES;
    const auto phases = telar::ds::Array<std::pair<NSEventPhase, ScrollPhase>, 8>{
        {
            {NSEventPhaseNone, ScrollPhase::none},
            {NSEventPhaseBegan, ScrollPhase::begin},
            {NSEventPhaseMayBegin, ScrollPhase::begin},
            {NSEventPhaseStationary, ScrollPhase::update},
            {NSEventPhaseChanged, ScrollPhase::update},
            {NSEventPhaseEnded, ScrollPhase::end},
            {NSEventPhaseCancelled, ScrollPhase::cancel},
            {static_cast<NSEventPhase>(NSEventPhaseCancelled | NSEventPhaseBegan), ScrollPhase::cancel},
        },
    };

    for (const auto& [phase, expected] : phases) {
      event.scrollPhase = phase;
      for (const auto* const type : {"mac_generic_NSEvent", "NSEvent"}) {
        const auto input = nativeScrollInput(type, (__bridge const void*)event, window);

        check(input && input->valid, "owned native wheel must decode through both Qt event kinds");
        check(input->sample.phase == expected, "native phase must preserve begin, cancellation and end");
        check(input->sample.delta == -event.delta && input->sample.precise, "native delta must preserve fractions and direction");
        check(input->x == x && input->y == y, "native position must remain in logical top-left coordinates");
      }
    }

    event.scrollPhase = NSEventPhaseNone;
    event.momentum = NSEventPhaseBegan;
    event.precise = NO;
    const auto momentum = nativeScrollInput("NSEvent", (__bridge const void*)event, window);

    check(momentum && momentum->valid && momentum->sample.phase == ScrollPhase::none && !momentum->sample.precise, "momentum must not invent a new finger gesture or discard a discrete fraction");
    event.delta = std::numeric_limits<double>::quiet_NaN();
    const auto invalid = nativeScrollInput("NSEvent", (__bridge const void*)event, window);

    check(invalid && !invalid->valid, "recognized malformed input must be consumed without changing history");
    check(!nativeScrollInput("unrelated", (__bridge const void*)event, window), "other native sources must pass through");
    check(!nativeScrollInput("NSEvent", nullptr, window), "missing native input must pass through");
    QWindow other;

    check(!nativeScrollInput("NSEvent", (__bridge const void*)event, other), "missing window handle must not create a window");
    other.create();
    check(!nativeScrollInput("NSEvent", (__bridge const void*)event, other), "wheel input must remain scoped to its owning native window");
  }

  const telar::gui::test::ObjcCase case_verify_native_scroll{"native_scroll_input.verify_native_scroll", verifyNativeScroll};

}
