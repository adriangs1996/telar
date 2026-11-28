#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "platform/scroll_event.hpp"
#include "scroll_fixture.h"
#include <QWindow>
#include <bit>
#include <cstdint>
#include <limits>
#include <memory>
#include <utility>

import telar.base.ds;
import telar.testing;

namespace {

  using telar::gui::ScrollPhase;
  using telar::gui::platform::nativeScrollInput;
  using telar::testing::check;

  struct ReleaseEvent {
    void operator()(void* handle) const noexcept {
      telarTestScrollEventDestroy(handle);
    }
  };

  void verifyNativeScroll() {
    QWindow window;
    constexpr int window_width = 320;
    constexpr int window_height = 200;

    window.resize(window_width, window_height);
    window.create();
    constexpr double x = 8.125;
    constexpr double y = 12.875;
    constexpr double fractional_delta = 0.375;
    const std::unique_ptr<void, ReleaseEvent> event{
        telarTestScrollEventCreate(std::bit_cast<const void*>(window.winId()), x, y, fractional_delta, true)
    };
    const auto phases = telar::ds::Array<std::pair<std::uint64_t, ScrollPhase>, 8>{
        {
            {telar_test_scroll_phase_none, ScrollPhase::none},
            {telar_test_scroll_phase_began, ScrollPhase::begin},
            {telar_test_scroll_phase_may_begin, ScrollPhase::begin},
            {telar_test_scroll_phase_stationary, ScrollPhase::update},
            {telar_test_scroll_phase_changed, ScrollPhase::update},
            {telar_test_scroll_phase_ended, ScrollPhase::end},
            {telar_test_scroll_phase_cancelled, ScrollPhase::cancel},
            {telar_test_scroll_phase_cancelled | telar_test_scroll_phase_began, ScrollPhase::cancel},
        },
    };

    for (const auto& [phase, expected] : phases) {
      telarTestScrollEventConfigure(event.get(), phase, telar_test_scroll_phase_none, fractional_delta, true);
      for (const auto* const type : {"mac_generic_NSEvent", "NSEvent"}) {
        const auto input = nativeScrollInput(type, event.get(), window);

        check(input && input->valid, "owned native wheel must decode through both Qt event kinds");
        check(input->sample.phase == expected, "native phase must preserve begin, cancellation and end");
        check(input->sample.delta == -fractional_delta && input->sample.precise, "native delta must preserve fractions and direction");
        check(input->x == x && input->y == y, "native position must remain in logical top-left coordinates");
      }
    }

    telarTestScrollEventConfigure(event.get(), telar_test_scroll_phase_none, telar_test_scroll_phase_began, fractional_delta, false);
    const auto momentum = nativeScrollInput("NSEvent", event.get(), window);

    check(momentum && momentum->valid && momentum->sample.phase == ScrollPhase::none && !momentum->sample.precise, "momentum must not invent a new finger gesture or discard a discrete fraction");
    telarTestScrollEventConfigure(event.get(), telar_test_scroll_phase_none, telar_test_scroll_phase_began, std::numeric_limits<double>::quiet_NaN(), false);
    const auto invalid = nativeScrollInput("NSEvent", event.get(), window);

    check(invalid && !invalid->valid, "recognized malformed input must be consumed without changing history");
    check(!nativeScrollInput("unrelated", event.get(), window), "other native sources must pass through");
    check(!nativeScrollInput("NSEvent", nullptr, window), "missing native input must pass through");
    QWindow other;

    check(!nativeScrollInput("NSEvent", event.get(), other), "missing window handle must not create a window");
    other.create();
    check(!nativeScrollInput("NSEvent", event.get(), other), "wheel input must remain scoped to its owning native window");
  }

  const telar::testing::Case case_verify_native_scroll{"native_scroll_input.verify_native_scroll", verifyNativeScroll};

}
