#pragma once

#include <algorithm>
#include <cstddef>
#include <utility>

namespace telar::gui {

struct CellSelection {
  int anchor = -1;
  int head = -1;

  bool operator==(const CellSelection &) const = default;

  [[nodiscard]] CellSelection within(std::size_t first, std::size_t count) const noexcept {
    if (anchor < 0 || head < 0 || count == 0) {
      return {};
    }

    const auto beginning = static_cast<std::size_t>(std::min(anchor, head));
    const auto ending = static_cast<std::size_t>(std::max(anchor, head));
    const auto last = first + count - 1;
    if (ending < first || beginning > last) {
      return {};
    }

    return {.anchor = static_cast<int>(std::max(first, beginning)), .head = static_cast<int>(std::min(last, ending))};
  }

  [[nodiscard]] bool contains(std::size_t cell) const noexcept {
    return anchor >= 0 && head >= 0 && std::cmp_greater_equal(cell, std::min(anchor, head)) && std::cmp_less_equal(cell, std::max(anchor, head));
  }
};

}
