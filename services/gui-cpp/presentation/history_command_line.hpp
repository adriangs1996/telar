#pragma once

#include "core/geometry.hpp"
#include <algorithm>
#include <cmath>
#include <string_view>

namespace telar::gui {

struct HistoryCommandMetrics {
  float needed = 0;
  float cell_width = 1;
  bool continues = false;
};

struct HistoryCommandLine {
  static constexpr float minimum_marked_columns = 2;
  static constexpr std::string_view ellipsis = "…";
  static constexpr std::string_view continuation = "↵";

  Rect text;
  Rect marker;
  std::string_view mark;

  [[nodiscard]] static HistoryCommandLine derive(Rect bounds, HistoryCommandMetrics metrics) noexcept {
    HistoryCommandLine result;
    result.text = bounds;
    const auto cell = std::max(1.0F, metrics.cell_width);
    const auto columns = std::floor(bounds.width / cell);
    const auto overflows = metrics.needed > bounds.width;
    if ((overflows || metrics.continues) && columns >= minimum_marked_columns) {
      const auto tail_limit = (columns - 1) * cell;
      result.text.width = overflows ? tail_limit : std::min(metrics.needed + cell, tail_limit);
      result.marker = {.x = bounds.x + result.text.width, .y = bounds.y, .width = cell, .height = bounds.height};
      result.mark = overflows ? ellipsis : continuation;
    }

    return result;
  }
};

}
