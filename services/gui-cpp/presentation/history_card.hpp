#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "presentation/history_row_geometry.hpp"
#include "text/wrapped_lines.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

namespace telar::gui {

struct HistoryCardMetrics {
  float cell_width = 1;
  float cell_height = 1;
  float row_height = 0;
  float viewport_height = 0;
};

struct HistoryCard {
  static constexpr std::size_t maximum_lines = 10;
  static constexpr std::uint16_t more_bound = 64;
  static constexpr float viewport_share = 0.45F;
  static constexpr float viewport_reservation = 32;
  static constexpr float viewport_clearance = 4;
  static constexpr float meta_gap = 4;
  static constexpr float bottom_inset = 8;
  static constexpr float minimum_meta_height = 22;
  static constexpr float meta_padding = 6;

  std::array<std::string_view, maximum_lines> lines{};
  std::uint16_t shown = 0;
  std::uint16_t more = 0;
  std::uint16_t line_limit = maximum_lines;
  float text_y = 0;
  float intrinsic_height = 0;
  float height = 0;
  Rect meta;

  [[nodiscard]] static HistoryCard measure(const HistoryRowGeometry &row, ChromeMetrics chrome, HistoryCardMetrics metrics, std::string_view command) noexcept {
    HistoryCard result;
    result.line_limit = lineLimit(chrome, metrics);
    const auto columns = std::floor(row.command.width / std::max(1.0F, metrics.cell_width));
    const auto bounded_columns = static_cast<std::uint16_t>(std::clamp(columns, 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    WrappedLines wrapped{command, bounded_columns, true};
    std::uint16_t total = 0;
    while (total < result.line_limit + more_bound) {
      const auto line = wrapped.next();
      if (!line) {
        break;
      }

      if (total < result.line_limit) {
        result.lines[total] = *line;
      }

      ++total;
    }

    result.shown = std::min(total, result.line_limit);
    result.more = total - result.shown;
    const auto top_inset = std::max(0.0F, std::floor((row.command.height - metrics.cell_height) / 2));
    const auto command_height = static_cast<float>(result.shown) * metrics.cell_height;
    const auto meta_height = std::max(chrome.px(minimum_meta_height), ChromeMetrics::lineHeight(chrome.small) + chrome.px(meta_padding));
    result.text_y = row.command.y + top_inset;
    result.meta = {.x = row.command.x, .y = result.text_y + command_height + chrome.px(meta_gap), .width = std::max(0.0F, row.frame.right() - chrome.px(bottom_inset) - row.command.x), .height = meta_height};
    result.intrinsic_height = chrome.px(2 * HistoryRowGeometry::vertical_inset) + top_inset + command_height + chrome.px(meta_gap) + meta_height + chrome.px(bottom_inset);
    const auto opened_height = std::round(metrics.row_height + std::max(0.0F, result.intrinsic_height - metrics.row_height));
    const auto tallest = std::max(metrics.row_height, metrics.viewport_height - chrome.px(viewport_clearance));
    result.height = metrics.viewport_height > 0 ? std::min(tallest, opened_height) : opened_height;

    return result;
  }

private:
  [[nodiscard]] static std::uint16_t lineLimit(ChromeMetrics chrome, HistoryCardMetrics metrics) noexcept {
    if (metrics.viewport_height <= 0) {
      return maximum_lines;
    }

    const auto budget = (metrics.viewport_height * viewport_share) - metrics.row_height - chrome.px(viewport_reservation);
    const auto count = std::floor(budget / std::max(1.0F, metrics.cell_height)) + 1;

    return static_cast<std::uint16_t>(std::clamp(count, 1.0F, static_cast<float>(maximum_lines)));
  }
};

}
