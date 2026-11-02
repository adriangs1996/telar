#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "presentation/form_button_style.hpp"
#include "presentation/history_inspection.hpp"
#include "presentation/history_actions.hpp"
#include "presentation/history_modal_geometry.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>

namespace telar::gui {

struct HistoryInspectionGeometry {
  static constexpr std::size_t maximum_actions = history_inspection_action_count;
  static constexpr float command_padding = 8;
  static constexpr float fact_label_width = 64;
  static constexpr float fact_label_divisor = 3;
  static constexpr float button_padding = 24;
  static constexpr float button_gap = 8;
  static constexpr float button_radius = FormButtonStyle::radius;
  static constexpr float disabled_alpha = FormButtonStyle::disabled_alpha;
  static constexpr float pressed_alpha = FormButtonStyle::pressed_alpha;

  Rect content;
  Rect actions;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;
  float row_height = 0;
  float label_width = 0;
  float command_inset = 0;

  [[nodiscard]] static HistoryInspectionGeometry derive(Rect area, ChromeMetrics chrome, Point cell) noexcept {
    HistoryModalGeometry modal{};
    modal.inspection = area;
    const auto content = modal.inspectionContent(chrome);
    const auto bounded = [](float value) {
      return static_cast<std::uint16_t>(std::clamp(std::floor(value), 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    };

    return {.content = content, .actions = modal.inspectionActions(chrome), .columns = bounded(content.width / std::max(1.0F, cell.x)), .rows = cell.y > 0 ? bounded(content.height / cell.y) : std::uint16_t{0}, .row_height = cell.y, .label_width = std::min(chrome.px(fact_label_width), content.width / fact_label_divisor), .command_inset = chrome.px(command_padding)};
  }

  [[nodiscard]] Rect row(std::size_t index) const noexcept {
    return {.x = content.x, .y = content.y + (static_cast<float>(index) * row_height), .width = content.width, .height = row_height};
  }

  [[nodiscard]] Rect text(Rect row, HistoryInspectionLine::Kind kind) const noexcept {
    if (kind == HistoryInspectionLine::Kind::command) {
      return {.x = row.x + command_inset, .y = row.y, .width = std::max(0.0F, row.width - (command_inset * 2)), .height = row.height};
    }

    if (kind == HistoryInspectionLine::Kind::fact) {
      return {.x = row.x + label_width, .y = row.y, .width = std::max(0.0F, row.width - label_width), .height = row.height};
    }

    return row;
  }

  [[nodiscard]] std::array<Rect, maximum_actions> buttons(std::span<const float> advances, ChromeMetrics chrome) const noexcept {
    std::array<Rect, maximum_actions> result{};
    auto x = actions.x;
    for (std::size_t index = 0; index < std::min(advances.size(), result.size()); ++index) {
      const auto width = advances[index] + chrome.px(button_padding);
      if (x + width > actions.right()) {
        break;
      }

      result[index] = {.x = x, .y = actions.y, .width = width, .height = actions.height};
      x += width + chrome.px(button_gap);
    }

    return result;
  }
};

}
