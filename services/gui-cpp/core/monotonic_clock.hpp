#pragma once

#include <concepts>
#include <cstdint>

namespace telar::gui {

template <typename Clock>
concept MonotonicClock = requires {
  { Clock::nowNanoseconds() } noexcept -> std::same_as<std::uint64_t>;
};

}
