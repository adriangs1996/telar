#include "platform/wall_clock.hpp"
#include <charconv>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <system_error>

namespace {

std::int64_t epochMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

}

int main(int count, char *const *arguments) try {
  if (count != 2) {
    throw std::invalid_argument{"Expected a UTC offset in minutes"};
  }

  const std::string_view expected{arguments[1]};
  std::int16_t offset = 0;
  const auto parsed = std::from_chars(expected.data(), expected.data() + expected.size(), offset);
  if (parsed.ec != std::errc{} || parsed.ptr != expected.data() + expected.size()) {
    throw std::invalid_argument{"Invalid UTC offset in minutes"};
  }

  tzset();
  const auto before = epochMilliseconds();
  const auto sampled = telar::gui::platform::WallClock::sample();
  const auto after = epochMilliseconds();
  if (sampled.now_ms < before || sampled.now_ms > after || sampled.utc_offset_min != offset) {
    throw std::runtime_error{"Wall clock must sample epoch milliseconds and the native UTC offset"};
  }

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
