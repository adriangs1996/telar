#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <algorithm>
#include <cmath>
#include <cstddef>

namespace telar::gui {

struct NotificationMetrics {
  static constexpr float margin = 16;
  static constexpr float preferred_width = 360;
  static constexpr float minimum_width = 160;
  static constexpr float minimum_host_height = 96;
  static constexpr float minimum_card_height = 64;
  static constexpr float card_padding = 14;
  static constexpr float vertical_padding = 28;
  static constexpr float body_gap = 4;
  static constexpr float action_gap = 10;
  static constexpr float stack_gap = 10;
  static constexpr float enter_shift_x = 12;
  static constexpr float enter_shift_y = 6;
  static constexpr float radius = 12;
  static constexpr float icon_side = 28;
  static constexpr float icon_radius = 9;
  static constexpr float text_left = 54;
  static constexpr float text_insets = 76;
  static constexpr float title_insets = 94;
  static constexpr float body_top = 18;
  static constexpr float close_right = 34;
  static constexpr float close_top = 8;
  static constexpr float close_side = 26;
  static constexpr float close_radius = 7;
  static constexpr float border_width = 1;
  static constexpr float border_alpha = 0.35F;
  static constexpr float focus_border_width = 1.5F;
  static constexpr float icon_alpha = 0.14F;
  static constexpr std::size_t shadow_layers = 3;
  static constexpr float shadow_spread = 2;
  static constexpr float shadow_offset = 3;
  static constexpr float shadow_alpha = 0.055F;
  static constexpr float underline_bottom = 2;
  static constexpr float underline_height = 1;

  float ratio = 1;
  float title_row = ChromeMetrics::lineHeight(ChromeMetrics{}.title);
  float body_row = ChromeMetrics::lineHeight(ChromeMetrics{}.body);
  float small_row = ChromeMetrics::lineHeight(ChromeMetrics{}.small);

  [[nodiscard]] float px(float value) const noexcept {
    return value * ratio;
  }

  [[nodiscard]] float height(std::size_t body_lines, bool clickable) const noexcept {
    auto height = px(vertical_padding) + title_row;
    if (body_lines > 0) {
      height += px(body_gap) + (static_cast<float>(body_lines) * body_row);
    }

    if (clickable) {
      height += px(action_gap) + small_row;
    }

    return std::max(height, px(minimum_card_height));
  }
};

struct NotificationCardGeometry {
  Rect bounds;
  NotificationMetrics metrics;

  [[nodiscard]] Rect icon() const noexcept {
    return {.x = bounds.x + metrics.px(NotificationMetrics::card_padding), .y = bounds.y + metrics.px(NotificationMetrics::card_padding), .width = metrics.px(NotificationMetrics::icon_side), .height = metrics.px(NotificationMetrics::icon_side)};
  }

  [[nodiscard]] Rect title() const noexcept {
    return {.x = textLeft(), .y = bounds.y + metrics.px(NotificationMetrics::card_padding), .width = bounds.width - metrics.px(NotificationMetrics::title_insets), .height = metrics.title_row};
  }

  [[nodiscard]] Rect body(std::size_t row) const noexcept {
    auto y = bounds.y + metrics.px(NotificationMetrics::body_top) + metrics.title_row;
    for (std::size_t index = 0; index < row; ++index) {
      y += metrics.body_row;
    }

    return {.x = textLeft(), .y = y, .width = bodyWidth(), .height = metrics.body_row};
  }

  [[nodiscard]] Rect action() const noexcept {
    return {.x = textLeft(), .y = bounds.y + bounds.height - metrics.px(NotificationMetrics::card_padding) - metrics.small_row, .width = bodyWidth(), .height = metrics.small_row};
  }

  [[nodiscard]] Rect close() const noexcept {
    return {.x = bounds.x + bounds.width - metrics.px(NotificationMetrics::close_right), .y = bounds.y + metrics.px(NotificationMetrics::close_top), .width = metrics.px(NotificationMetrics::close_side), .height = metrics.px(NotificationMetrics::close_side)};
  }

  [[nodiscard]] Rect actionUnderline(float line_height, float advance) const noexcept {
    const auto row = action();
    const auto top = std::floor(row.y + ((row.height - line_height) / 2));

    return {.x = row.x, .y = top + line_height - NotificationMetrics::underline_bottom, .width = std::min(row.width, advance), .height = NotificationMetrics::underline_height};
  }

  [[nodiscard]] float bodyWidth() const noexcept {
    return bounds.width - metrics.px(NotificationMetrics::text_insets);
  }

private:
  [[nodiscard]] float textLeft() const noexcept {
    return bounds.x + metrics.px(NotificationMetrics::text_left);
  }
};

}
