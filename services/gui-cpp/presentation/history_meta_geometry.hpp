#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "presentation/history_actions.hpp"
#include "presentation/history_facts.hpp"
#include "presentation/history_hint_geometry.hpp"
#include "presentation/history_row_geometry.hpp"
#include <algorithm>
#include <array>
#include <cstddef>

namespace telar::gui {

struct HistoryMetaMeasurements {
  std::array<float, HistoryFacts::capacity> facts{};
  std::array<HistoryHintMeasurements, HistoryActions::count> actions{};
  std::size_t fact_count = 0;
  bool selected = true;
  bool pane_open = false;
};

struct HistoryMetaGeometry {
  static constexpr float action_gap = 2;
  static constexpr float facts_right_inset = 10;

  std::array<Rect, HistoryFacts::capacity> facts{};
  std::array<HistoryHintGeometry, HistoryActions::count> actions{};
  std::size_t fact_count = 0;
  std::size_t action_count = 0;
  Rect facts_area;

  [[nodiscard]] static HistoryMetaGeometry derive(Rect bounds, ChromeMetrics chrome, const HistoryMetaMeasurements &measured) noexcept {
    HistoryMetaGeometry result;
    if (bounds.empty()) {
      return result;
    }

    float total = 0;
    const auto available_actions = measured.selected ? HistoryActions::count - static_cast<std::size_t>(!measured.pane_open) : 0;
    for (std::size_t index = 0; index < available_actions; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.actions[index]);
      if (bounds.width - total - width < chrome.px(HistoryRowGeometry::minimum_command)) {
        break;
      }

      total += width + chrome.px(action_gap);
      ++result.action_count;
    }

    auto x = bounds.right() - total;
    for (std::size_t index = 0; index < result.action_count; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.actions[index]);
      result.actions[index] = HistoryHintGeometry::derive({.x = x, .y = bounds.y, .width = width, .height = bounds.height}, chrome, measured.actions[index]);
      x += width + chrome.px(action_gap);
    }

    const auto right = bounds.right() - total;
    result.facts_area = {.x = bounds.x, .y = bounds.y, .width = std::max(0.0F, right - chrome.px(facts_right_inset) - bounds.x), .height = bounds.height};
    x = result.facts_area.x;
    const auto count = std::min(measured.fact_count, measured.facts.size());
    for (std::size_t index = 0; index < count; ++index) {
      const auto width = measured.facts[index];
      if (x + width > result.facts_area.right()) {
        break;
      }

      result.facts[index] = {.x = x, .y = bounds.y, .width = width, .height = bounds.height};
      ++result.fact_count;
      x += width + chrome.px(HistoryRowGeometry::fact_gap);
    }

    return result;
  }
};

}
