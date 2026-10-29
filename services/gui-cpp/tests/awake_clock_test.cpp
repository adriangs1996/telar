#include "platform/awake_clock.hpp"
#include <cstddef>
#include <cstdint>
#include <ctime>
#include <exception>
#include <iostream>
#include <stdexcept>

namespace {

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

}

int main() try {
  constexpr std::size_t samples = 1000;
  for (std::size_t index = 0; index < samples; ++index) {
    const auto before = nativeAwakeNanoseconds();
    const auto sample = telar::gui::platform::AwakeClock::nowNanoseconds();
    const auto after = nativeAwakeNanoseconds();
    if (sample < before || sample > after) {
      throw std::runtime_error{"Awake clock differs from the original platform timebase"};
    }
  }

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
