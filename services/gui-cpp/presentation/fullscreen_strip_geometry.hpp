#pragma once

#include "application/pane_layout.hpp"
#include "core/geometry.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <span>

namespace telar::gui {

struct FullscreenEntryMeasure {
  float index = 0;
  float name = 0;
  bool focused = false;
  bool attention = false;
};

struct FullscreenStripMetrics {
  float ratio = 1;
  float maximum_band_height = 0;
  float mark_side = 0;
};

struct FullscreenStripMeasurements {
  float chip = 0;
  float progress = 0;
  float compact_progress = 0;
};

struct FullscreenStripGeometry {
  static constexpr float entry_gap = 16;
  static constexpr float part_gap = 6;
  static constexpr float chip_gap = 8;
  static constexpr float leave_width = 22;
  static constexpr float margin = 8;
  static constexpr float minimum_entry_room = 48;
  static constexpr float attention_gap = 6;
  static constexpr float attention_diameter = 6;

  struct Entry {
    std::size_t source = 0;
    Rect bounds;
    Rect mark;
    Rect index;
    Rect name;
    Rect attention;
  };

  std::array<Entry, PaneLayout::maximum_panes> entries{};
  std::size_t count = 0;
  Rect leave;
  Rect progress;
  Rect chip;
  bool named = true;
  bool compact_progress = false;

  [[nodiscard]] static FullscreenStripGeometry derive(Rect row, const FullscreenStripMetrics &metrics, std::span<const FullscreenEntryMeasure> sizes, const FullscreenStripMeasurements &measurements) noexcept {
    FullscreenStripGeometry result;
    const auto height = std::min(row.height, metrics.maximum_band_height);
    if (height <= 0 || row.width <= 0 || sizes.empty() || sizes.size() > PaneLayout::maximum_panes) {
      return result;
    }

    const auto ratio = metrics.ratio;
    Rect band{.x = row.x + (margin * ratio), .y = row.y + std::floor((row.height - height) / 2), .width = std::max(0.0F, row.width - (2 * margin * ratio)), .height = height};
    const auto control_width = std::min(band.width, leave_width * ratio);
    if (control_width > 0) {
      result.leave = {.x = band.right() - control_width, .y = band.y, .width = control_width, .height = height};
      band.width = std::max(0.0F, band.width - (control_width + (part_gap * ratio)));
    }

    auto progress_width = measurements.progress;
    if (progress_width > band.width / 2) {
      result.compact_progress = true;
      progress_width = measurements.compact_progress;
    }

    if (progress_width > 0 && progress_width + ((part_gap + minimum_entry_room) * ratio) <= band.width) {
      result.progress = {.x = band.right() - progress_width, .y = band.y, .width = progress_width, .height = height};
      band.width = std::max(0.0F, band.width - (progress_width + (part_gap * ratio)));
    }

    std::array<float, PaneLayout::maximum_panes> widths{};
    std::size_t focus = 0;
    const auto gap = entry_gap * ratio;
    auto total = gap * static_cast<float>(sizes.size() - 1);
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      widths[index] = entryWidth(sizes[index], metrics, measurements.chip, true);
      total += widths[index];
      if (sizes[index].focused) {
        focus = index;
      }
    }

    result.named = total <= band.width;
    if (!result.named) {
      for (std::size_t index = 0; index < sizes.size(); ++index) {
        widths[index] = entryWidth(sizes[index], metrics, measurements.chip, false);
      }
    }

    auto first = focus;
    auto used = std::min(widths[first], band.width);
    while (first > 0) {
      const auto required = widths[first - 1] + gap;
      if (required > band.width - used) {
        break;
      }

      --first;
      used += required;
    }

    auto x = band.x;
    for (auto index = first; index < sizes.size(); ++index) {
      if (index != first) {
        x += gap;
      }

      const auto width = std::min(widths[index], std::max(0.0F, band.right() - x));
      if (width <= 0) {
        break;
      }

      auto &entry = result.entries[result.count++];
      entry.source = index;
      entry.bounds = {.x = x, .y = band.y, .width = width, .height = height};
      const auto advance = placeEntry(entry, sizes[index], metrics, result.named);
      if (sizes[index].focused && measurements.chip > 0) {
        const auto chip_x = std::min(band.right(), x + advance + (chip_gap * ratio));
        result.chip = {.x = chip_x, .y = band.y, .width = std::max(0.0F, std::min(measurements.chip, x + width - chip_x)), .height = height};
      }

      x += width;
    }

    return result;
  }

private:
  [[nodiscard]] static float entryWidth(const FullscreenEntryMeasure &size, const FullscreenStripMetrics &metrics, float chip_width, bool named) noexcept {
    auto width = metrics.mark_side + (part_gap * metrics.ratio) + size.index;
    if (named || size.focused) {
      width += (part_gap * metrics.ratio) + size.name;
    }

    if (size.attention) {
      width += (attention_gap + attention_diameter) * metrics.ratio;
    }

    if (size.focused && chip_width > 0) {
      width += (chip_gap * metrics.ratio) + chip_width;
    }

    return width;
  }

  [[nodiscard]] static float placeEntry(Entry &entry, const FullscreenEntryMeasure &size, const FullscreenStripMetrics &metrics, bool named) noexcept {
    const auto &bounds = entry.bounds;
    const auto end = bounds.right();
    const auto ratio = metrics.ratio;
    const auto side = metrics.mark_side;
    entry.mark = {.x = bounds.x, .y = bounds.y + ((bounds.height - side) / 2), .width = std::max(0.0F, std::min(side, bounds.width)), .height = side};
    auto x = bounds.x + side + (part_gap * ratio);
    entry.index = {.x = x, .y = bounds.y, .width = std::max(0.0F, end - x), .height = bounds.height};
    x += std::min(entry.index.width, size.index);
    if (named || size.focused) {
      x += part_gap * ratio;
      entry.name = {.x = x, .y = bounds.y, .width = std::max(0.0F, end - x), .height = bounds.height};
      x += std::min(entry.name.width, size.name);
    }

    if (size.attention) {
      const auto diameter = attention_diameter * ratio;
      if (x + (((2 * attention_gap) + attention_diameter) * ratio) <= end) {
        entry.attention = {.x = x + (attention_gap * ratio), .y = bounds.y + std::max(0.0F, (bounds.height - diameter) / 2), .width = diameter, .height = std::min(diameter, bounds.height)};
      }

      x += (attention_gap + attention_diameter) * ratio;
    }

    return std::min(x, end) - bounds.x;
  }
};

}
