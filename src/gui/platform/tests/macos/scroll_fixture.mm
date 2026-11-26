#include "scroll_fixture.h"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdint>

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

  NSEventPhase toNativePhase(std::uint64_t bits) noexcept {
    NSEventPhase phase = NSEventPhaseNone;

    if ((bits & telar_test_scroll_phase_began) != 0) {
      phase |= NSEventPhaseBegan;
    }

    if ((bits & telar_test_scroll_phase_stationary) != 0) {
      phase |= NSEventPhaseStationary;
    }

    if ((bits & telar_test_scroll_phase_changed) != 0) {
      phase |= NSEventPhaseChanged;
    }

    if ((bits & telar_test_scroll_phase_ended) != 0) {
      phase |= NSEventPhaseEnded;
    }

    if ((bits & telar_test_scroll_phase_cancelled) != 0) {
      phase |= NSEventPhaseCancelled;
    }

    if ((bits & telar_test_scroll_phase_may_begin) != 0) {
      phase |= NSEventPhaseMayBegin;
    }

    return phase;
  }

}

void* telarTestScrollEventCreate(const void* ns_view, double x, double y, double delta, bool precise) {
  const auto* const view = (__bridge NSView*)ns_view;
  auto* const event = [NativeScrollFixture new];

  event.target = view.window;
  event.point = [view convertPoint:NSMakePoint(x, view.isFlipped ? y : view.bounds.size.height - y) toView:nil];
  event.delta = delta;
  event.precise = precise ? YES : NO;
  return (__bridge_retained void*)event;
}

void telarTestScrollEventConfigure(void* event_handle, uint64_t phase_bits, uint64_t momentum_bits, double delta, bool precise) {
  auto* const event = (__bridge NativeScrollFixture*)event_handle;

  event.scrollPhase = toNativePhase(phase_bits);
  event.momentum = toNativePhase(momentum_bits);
  event.delta = delta;
  event.precise = precise ? YES : NO;
}

void telarTestScrollEventDestroy(void* event_handle) {
  if (event_handle != nullptr) {
    CFRelease(event_handle);
  }
}
