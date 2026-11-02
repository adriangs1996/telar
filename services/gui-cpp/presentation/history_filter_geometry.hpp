#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "history_filter_chip_geometry.hpp"
#include "history_filter_labels.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>

namespace telar::gui {

struct HistoryFilterMeasurements {
  std::array<HistoryFilterChipMeasurements, HistoryFilterLabels::scopes.size()> scopes{};
  std::array<HistoryFilterChipMeasurements, HistoryFilterLabels::authors.size()> authors{};
  std::array<float, HistoryFilterLabels::key_count> keys{};
  float failed = 0;
};

struct HistoryFilterGeometry {
  static constexpr float horizontal_inset = 16;
  static constexpr float maximum_chip_height = 28;
  static constexpr float vertical_inset = 12;
  static constexpr float group_padding = 4;
  static constexpr float chip_inset = 2;
  static constexpr float group_gap = 8;
  static constexpr float group_radius = 6;
  static constexpr float key_gap = 8;
  static constexpr float separator_height = 1;

  std::array<HistoryFilterChipGeometry, HistoryFilterLabels::scopes.size()> scopes{};
  std::array<HistoryFilterChipGeometry, HistoryFilterLabels::authors.size()> authors{};
  std::array<Rect, HistoryFilterLabels::key_count> keys{};
  HistoryFilterChipGeometry failed;
  Rect scope_group;
  Rect author_group;
  Rect separator;
  bool visible = false;
  bool show_keys = false;
  bool show_right = false;

  [[nodiscard]] static HistoryFilterGeometry derive(Rect area, ChromeMetrics chrome, const HistoryFilterMeasurements &measured) noexcept {
    HistoryFilterGeometry result;
    if (area.empty()) {
      return result;
    }

    result.visible = true;
    result.separator = {.x = area.x, .y = area.bottom() - separator_height, .width = area.width, .height = separator_height};
    const auto height = std::min(chrome.px(maximum_chip_height), std::max(0.0F, area.height - chrome.px(vertical_inset)));
    const auto y = area.y + std::floor((area.height - height) / 2);
    auto scope_total = chrome.px(group_padding);
    auto author_total = chrome.px(group_padding);
    for (const auto &chip : measured.scopes) {
      scope_total += HistoryFilterChipGeometry::width(chrome, chip) + chrome.px(chip_inset);
    }
    for (const auto &chip : measured.authors) {
      author_total += HistoryFilterChipGeometry::width(chrome, chip) + chrome.px(chip_inset);
    }

    const auto failed_width = HistoryFilterChipGeometry::width(chrome, {.label = measured.failed});
    const auto gap = chrome.px(group_gap);
    const auto key_spacing = chrome.px(key_gap);
    const auto scope_key_width = measured.keys[0] + key_spacing;
    const auto author_key_width = measured.keys[1] + key_spacing;
    const auto failed_key_width = measured.keys[2] + key_spacing;
    const auto available = area.width - chrome.px(horizontal_inset * 2);
    const auto with_keys = scope_total + scope_key_width + gap + author_total + author_key_width + gap + failed_width + failed_key_width;
    result.show_keys = with_keys <= available;
    result.show_right = result.show_keys || scope_total + gap + author_total + gap + failed_width <= available;

    const auto left = area.x + chrome.px(horizontal_inset);
    result.scope_group = {.x = left, .y = y, .width = scope_total, .height = height};
    const auto scope_end = placeGroup(result.scopes, result.scope_group, chrome, measured.scopes);
    if (result.show_keys) {
      result.keys[0] = {.x = scope_end + key_spacing, .y = y, .width = scope_key_width, .height = height};
    }
    if (!result.show_right) {
      return result;
    }

    auto right = area.right() - chrome.px(horizontal_inset);
    if (result.show_keys) {
      right -= failed_key_width;
      result.keys[2] = {.x = right + key_spacing, .y = y, .width = failed_key_width, .height = height};
    }
    right -= failed_width;
    result.failed = HistoryFilterChipGeometry::derive({.x = right, .y = y, .width = failed_width, .height = height}, chrome, {.label = measured.failed});
    right -= gap;
    if (result.show_keys) {
      right -= author_key_width;
      result.keys[1] = {.x = right + key_spacing, .y = y, .width = author_key_width, .height = height};
    }
    right -= author_total;
    result.author_group = {.x = right, .y = y, .width = author_total, .height = height};
    placeGroup(result.authors, result.author_group, chrome, measured.authors);

    return result;
  }

private:
  template <std::size_t Count>
  static float placeGroup(std::array<HistoryFilterChipGeometry, Count> &destination, Rect group, ChromeMetrics chrome, const std::array<HistoryFilterChipMeasurements, Count> &measured) noexcept {
    auto x = group.x + chrome.px(chip_inset);
    for (std::size_t index = 0; index < Count; ++index) {
      const auto width = HistoryFilterChipGeometry::width(chrome, measured[index]);
      destination[index] = HistoryFilterChipGeometry::derive({.x = x, .y = group.y + chrome.px(chip_inset), .width = width, .height = std::max(0.0F, group.height - chrome.px(chip_inset * 2))}, chrome, measured[index]);
      x += width + chrome.px(chip_inset);
    }

    return x + chrome.px(chip_inset);
  }
};

}
