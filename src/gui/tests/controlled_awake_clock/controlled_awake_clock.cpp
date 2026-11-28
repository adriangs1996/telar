module telar.gui.tests.controlled_awake_clock;

import std;
import telar.gui.foundation.system;

namespace {

  std::atomic<std::uint64_t>& timestamp() noexcept {
    static std::atomic<std::uint64_t> now_ns = 0;

    return now_ns;
  }

}

void telar::gui::test::ControlledAwakeClock::set(std::uint64_t now_ns) noexcept {
  timestamp().store(now_ns, std::memory_order_relaxed);
}

// AwakeClock belongs to the global module, so this test double replaces its definition
// without being a unit of telar.gui.platform.awake_clock.
extern "C++" std::uint64_t telar::gui::system::AwakeClock::nowNanoseconds() noexcept {
  return timestamp().load(std::memory_order_relaxed);
}
