#include "controlled_awake_clock.hpp"
#include "platform/awake_clock.hpp"
#include <atomic>
#include <cstdint>

namespace {

std::atomic<std::uint64_t> &timestamp() noexcept {
  static std::atomic<std::uint64_t> now_ns = 0;

  return now_ns;
}

}

void telar::gui::test::ControlledAwakeClock::set(std::uint64_t now_ns) noexcept {
  timestamp().store(now_ns, std::memory_order_relaxed);
}

std::uint64_t telar::gui::platform::AwakeClock::nowNanoseconds() noexcept {
  return timestamp().load(std::memory_order_relaxed);
}
