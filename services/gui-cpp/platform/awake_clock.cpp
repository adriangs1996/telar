module;

#include <cstdint>
#include <ctime>
#include <exception>
#include <limits>

module telar.gui.platform.profile_file;



namespace telar::gui::platform {

std::uint64_t AwakeClock::nowNanoseconds() noexcept {
#ifdef __APPLE__
  constexpr clockid_t awake_clock = CLOCK_UPTIME_RAW;
#elifdef __linux__
  constexpr clockid_t awake_clock = CLOCK_MONOTONIC;
#else
#error Unsupported GUI platform
#endif
  timespec timestamp{};
  if (clock_gettime(awake_clock, &timestamp) != 0) {
    std::terminate();
  }

  if (timestamp.tv_sec < 0) {
    return 0;
  }

  constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
  constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
  const auto seconds = static_cast<std::uint64_t>(timestamp.tv_sec);
  const auto fraction = static_cast<std::uint64_t>(timestamp.tv_nsec);
  if (seconds > (maximum - fraction) / nanoseconds_per_second) {
    return maximum;
  }

  return (seconds * nanoseconds_per_second) + fraction;
}

}
