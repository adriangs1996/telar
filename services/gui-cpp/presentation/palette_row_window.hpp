#pragma once

#include "core/geometry.hpp"
#include "palette_geometry.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

enum class PaletteRowKind : std::uint8_t {
  context,
  tab,
  agent,
  action,
  machine,
  pick,
};

struct PaletteRowWindow {
  static constexpr std::size_t capacity = 16;
  static constexpr float content_inset = 8;

  struct Row {
    std::size_t index = 0;
    Rect group;
    Rect bounds;
  };

  std::array<Row, capacity> rows{};
  std::size_t count = 0;
  std::size_t first = 0;

  [[nodiscard]] static PaletteRowWindow measure(std::span<const PaletteRowKind> kinds, std::size_t selection, const PaletteGeometry &geometry, const ChromeMetrics &chrome, bool grouped) noexcept {
    PaletteRowWindow result;
    if (kinds.empty()) {
      return result;
    }

    const auto bounds = PaletteGeometry::inset(geometry.results, chrome.px(content_inset));
    const auto selected = std::min(selection, kinds.size() - 1);
    auto start = selected;
    auto used = rowHeight(kinds[selected], geometry) + (grouped ? geometry.group_height : 0);
    while (start != 0 && selected - start + 1 < capacity) {
      const auto preceding = start - 1;
      const auto extra = rowHeight(kinds[preceding], geometry) + (grouped && kinds[preceding] != kinds[start] ? geometry.group_height : 0);
      if (used + extra > bounds.height) {
        break;
      }

      start = preceding;
      used += extra;
    }

    result.first = start;
    auto y = bounds.y;
    std::optional<PaletteRowKind> previous;
    for (auto index = start; index < kinds.size() && result.count < capacity; ++index) {
      const auto height = rowHeight(kinds[index], geometry);
      Rect group;
      if (grouped && previous != kinds[index]) {
        if (y + geometry.group_height + height > bounds.bottom()) {
          break;
        }

        group = {.x = bounds.x, .y = y, .width = bounds.width, .height = geometry.group_height};
        y += geometry.group_height;
        previous = kinds[index];
      }

      if (y + height > bounds.bottom()) {
        break;
      }

      result.rows[result.count++] = {.index = index, .group = group, .bounds = {.x = bounds.x, .y = y, .width = bounds.width, .height = height}};
      y += height;
    }

    return result;
  }

private:
  [[nodiscard]] static float rowHeight(PaletteRowKind kind, const PaletteGeometry &geometry) noexcept {
    return kind == PaletteRowKind::agent ? geometry.agent_height : geometry.row_height;
  }
};

}
