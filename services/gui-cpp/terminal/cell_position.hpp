#pragma once

#include <compare>
#include <cstdint>
#include <tuple>

namespace telar::gui {

struct CellPosition {
  std::uint16_t x = 0;
  std::uint32_t y = 0;

  [[nodiscard]] auto operator<=>(const CellPosition &other) const noexcept {
    return std::tie(y, x) <=> std::tie(other.y, other.x);
  }

  bool operator==(const CellPosition &) const = default;
};

}
