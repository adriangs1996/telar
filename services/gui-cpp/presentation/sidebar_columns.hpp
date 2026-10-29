#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <utility>

namespace telar::gui {

struct SidebarColumns {
  static constexpr std::uint16_t minimum_width = 42;
  static constexpr std::uint16_t minimum_workbench = 20;

  [[nodiscard]] static std::uint16_t clamp(std::uint16_t host_width, std::int64_t requested_width) {
    if (requested_width <= 0 || std::cmp_greater(requested_width, std::numeric_limits<std::uint16_t>::max())) {
      throw std::invalid_argument{"InvalidWidth"};
    }

    if (host_width < minimum_width + minimum_workbench) {
      return minimum_width;
    }

    return std::clamp(static_cast<std::uint16_t>(requested_width), minimum_width, static_cast<std::uint16_t>(host_width - minimum_workbench));
  }
};

}
