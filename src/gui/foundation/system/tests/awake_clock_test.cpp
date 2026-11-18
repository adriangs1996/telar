#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <ctime>

import std;
import telar.testing;
import telar.gui.foundation.system;

namespace {

  using telar::testing::check;

  std::uint64_t nativeAwakeNanoseconds() {
#ifdef __APPLE__
    constexpr clockid_t identity = CLOCK_UPTIME_RAW;
#elifdef __linux__
    constexpr clockid_t identity = CLOCK_MONOTONIC;
#endif
    timespec timestamp{};
    if (clock_gettime(identity, &timestamp) != 0) {
      throw std::runtime_error{"Native awake clock is unavailable"};
    }

    constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;

    return (static_cast<std::uint64_t>(timestamp.tv_sec) * nanoseconds_per_second) + static_cast<std::uint64_t>(timestamp.tv_nsec);
  }

  void samplesTheNativeTimebase() {
    constexpr std::size_t samples = 1000;

    for (std::size_t index = 0; index < samples; ++index) {
      const auto before = nativeAwakeNanoseconds();
      const auto sample = telar::gui::system::AwakeClock::nowNanoseconds();
      const auto after = nativeAwakeNanoseconds();

      check(sample >= before && sample <= after, "Awake clock differs from the original platform timebase");
    }
  }

  const telar::testing::Case case_samples_the_native_timebase{"awake_clock.samples_the_native_timebase", samplesTheNativeTimebase};

}
