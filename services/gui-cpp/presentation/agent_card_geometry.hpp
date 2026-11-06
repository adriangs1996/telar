#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "chrome_style.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace telar::gui {

struct AgentCardGeometry {
  static constexpr float horizontal_padding = 10;
  static constexpr float vertical_padding = 8;
  static constexpr float compact_vertical_padding = 4;
  static constexpr float task_indent = 12;
  static constexpr float spacing = 3;
  static constexpr float radius = ChromeStyle::surface_radius;
  static constexpr float gap = 6;
  static constexpr float mark_side = 14;
  static constexpr float project_label_gap = 4;
  static constexpr float project_label_minimum = 24;
  static constexpr float title_gap = 4;
  static constexpr float total_row_spacing = 6;
  static constexpr float group_gap = 8;
  static constexpr float scrollbar_width = 3;
  static constexpr float icon_size_ratio = 0.85F;
  static constexpr float provider_alpha = 0.6F;

  enum class Row : std::uint8_t {
    context,
    title,
    detail,
  };

  float small_row = 0;
  float title_row = 0;
  float scale = 1;

  [[nodiscard]] static AgentCardGeometry derive(const ChromeMetrics &chrome) noexcept {
    return {.small_row = ChromeMetrics::lineHeight(chrome.small), .title_row = ChromeMetrics::lineHeight(chrome.title), .scale = chrome.ratio};
  }

  [[nodiscard]] float px(float logical) const noexcept {
    return std::round(logical * scale);
  }

  [[nodiscard]] float height() const noexcept {
    return (2 * small_row) + title_row + px(total_row_spacing) + (2 * px(vertical_padding));
  }

  [[nodiscard]] float compactHeight() const noexcept {
    return title_row + (2 * px(compact_vertical_padding));
  }

  [[nodiscard]] float cardWidth(float list_width) const noexcept {
    return std::max(0.0F, list_width - (scrollbar_width * scale) - px(spacing));
  }

  [[nodiscard]] Rect row(Rect bounds, Row role) const noexcept {
    float top = 0;
    if (role == Row::title) {
      top = small_row + px(title_gap);
    } else if (role == Row::detail) {
      top = small_row + title_row + px(total_row_spacing);
    }

    return {.x = bounds.x + px(horizontal_padding), .y = bounds.y + px(vertical_padding) + top, .width = std::max(0.0F, bounds.width - (2 * px(horizontal_padding))), .height = role == Row::title ? title_row : small_row};
  }
};

}
