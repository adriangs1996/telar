#pragma once

#include "box_edge_table.hpp"
#include "box_edges.hpp"
#include "box_metrics.hpp"
#include "core/geometry.hpp"
#include "ink.hpp"
#include "symbol.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>

namespace telar::gui::glyphs {

class Box {
public:
  static constexpr std::size_t stroke_capacity = 8;
  static constexpr std::size_t rectangle_capacity = 21;
  using Paint = Ink<rectangle_capacity>;

  [[nodiscard]] static Paint draw(std::uint32_t codepoint, Rect cell, float thickness) {
    const auto metrics = BoxMetrics::resolve(cell, thickness);
    if (codepoint < Symbol::first_box || codepoint > Symbol::last_box || (codepoint >= Symbol::first_box_curve && codepoint <= Symbol::last_box_curve)) {
      throw std::invalid_argument{"InvalidStraightBox"};
    }

    Box box{metrics};
    auto edges = box_edge_table[codepoint - Symbol::first_box];
    if (edges.empty()) {
      box.dashes(codepoint);
    } else {
      constexpr float double_stroke_units = 3;
      if (std::min(cell.width, cell.height) < double_stroke_units * metrics.light) {
        edges.simplifyDoubles();
      }

      box.intersection(edges);
    }

    auto result = unite(box.strokes_.rectangles());
    result.translate({.x = cell.x, .y = cell.y});

    return result;
  }

private:
  struct Junction {
    float backward_end = 0;
    float forward_start = 0;
  };

  struct Axis {
    float light_start = 0;
    float light_end = 0;
    float heavy_start = 0;
    float heavy_end = 0;
    float double_start = 0;
    float double_end = 0;

    [[nodiscard]] static Axis resolve(float extent, const BoxMetrics &metrics) noexcept {
      const auto light_start = std::floor((extent - metrics.light) / 2);
      const auto heavy_start = std::floor((extent - metrics.heavy) / 2);

      return {.light_start = light_start, .light_end = light_start + metrics.light, .heavy_start = heavy_start, .heavy_end = heavy_start + metrics.heavy, .double_start = light_start - metrics.light, .double_end = (light_start + metrics.light) + metrics.light};
    }

    [[nodiscard]] Junction join(BoxWeight before, BoxWeight after, bool straight) const noexcept {
      if (before == BoxWeight::heavy || after == BoxWeight::heavy) {
        return {.backward_end = heavy_end, .forward_start = heavy_start};
      }

      if (before != after || straight) {
        return before == BoxWeight::double_line || after == BoxWeight::double_line ? Junction{.backward_end = double_end, .forward_start = double_start} : Junction{.backward_end = light_end, .forward_start = light_start};
      }

      if (before == BoxWeight::none && after == BoxWeight::none) {
        return {.backward_end = light_end, .forward_start = light_start};
      }

      return {.backward_end = light_start, .forward_start = light_end};
    }
  };

  struct Interval {
    float left = 0;
    float right = 0;
  };

  explicit Box(BoxMetrics metrics) noexcept
      : metrics_(metrics),
        x_(Axis::resolve(metrics.width, metrics)),
        y_(Axis::resolve(metrics.height, metrics)) {}

  void add(float left, float top, float right, float bottom) {
    left = std::clamp(left, 0.0F, metrics_.width);
    top = std::clamp(top, 0.0F, metrics_.height);
    right = std::clamp(right, left, metrics_.width);
    bottom = std::clamp(bottom, top, metrics_.height);
    strokes_.push({.x = left, .y = top, .width = right - left, .height = bottom - top});
  }

  void intersection(const BoxEdges &edges) {
    const auto horizontal = x_.join(edges.up, edges.down, edges.left == edges.right);
    const auto vertical = y_.join(edges.left, edges.right, edges.up == edges.down);
    upperArm(edges, vertical.backward_end);
    rightArm(edges, horizontal.forward_start);
    lowerArm(edges, vertical.forward_start);
    leftArm(edges, horizontal.backward_end);
  }

  void upperArm(const BoxEdges &edges, float bottom) {
    switch (edges.up) {
    case BoxWeight::none:
      break;
    case BoxWeight::light:
      add(x_.light_start, 0, x_.light_end, bottom);
      break;
    case BoxWeight::heavy:
      add(x_.heavy_start, 0, x_.heavy_end, bottom);
      break;
    case BoxWeight::double_line:
      add(x_.double_start, 0, x_.light_start, edges.left == BoxWeight::double_line ? y_.light_start : bottom);
      add(x_.light_end, 0, x_.double_end, edges.right == BoxWeight::double_line ? y_.light_start : bottom);
      break;
    }
  }

  void rightArm(const BoxEdges &edges, float left) {
    switch (edges.right) {
    case BoxWeight::none:
      break;
    case BoxWeight::light:
      add(left, y_.light_start, metrics_.width, y_.light_end);
      break;
    case BoxWeight::heavy:
      add(left, y_.heavy_start, metrics_.width, y_.heavy_end);
      break;
    case BoxWeight::double_line:
      add(edges.up == BoxWeight::double_line ? x_.light_end : left, y_.double_start, metrics_.width, y_.light_start);
      add(edges.down == BoxWeight::double_line ? x_.light_end : left, y_.light_end, metrics_.width, y_.double_end);
      break;
    }
  }

  void lowerArm(const BoxEdges &edges, float top) {
    switch (edges.down) {
    case BoxWeight::none:
      break;
    case BoxWeight::light:
      add(x_.light_start, top, x_.light_end, metrics_.height);
      break;
    case BoxWeight::heavy:
      add(x_.heavy_start, top, x_.heavy_end, metrics_.height);
      break;
    case BoxWeight::double_line:
      add(x_.double_start, edges.left == BoxWeight::double_line ? y_.light_end : top, x_.light_start, metrics_.height);
      add(x_.light_end, edges.right == BoxWeight::double_line ? y_.light_end : top, x_.double_end, metrics_.height);
      break;
    }
  }

  void leftArm(const BoxEdges &edges, float right) {
    switch (edges.left) {
    case BoxWeight::none:
      break;
    case BoxWeight::light:
      add(0, y_.light_start, right, y_.light_end);
      break;
    case BoxWeight::heavy:
      add(0, y_.heavy_start, right, y_.heavy_end);
      break;
    case BoxWeight::double_line:
      add(0, y_.double_start, edges.up == BoxWeight::double_line ? x_.light_start : right, y_.light_start);
      add(0, y_.light_end, edges.down == BoxWeight::double_line ? x_.light_start : right, y_.double_end);
      break;
    }
  }

  void dashes(std::uint32_t codepoint) {
    constexpr std::uint32_t first_double_dash = 0x254c;
    constexpr unsigned vertical_bit = 2;
    constexpr unsigned heavy_bit = 1;
    constexpr float standard_gap = 4;
    const auto count = dashCount(codepoint);
    const auto vertical = (codepoint & vertical_bit) != 0;
    const auto thickness = (codepoint & heavy_bit) != 0 ? metrics_.heavy : metrics_.light;
    auto desired_gap = std::max(standard_gap, metrics_.light);
    if (count == 2) {
      desired_gap = codepoint == first_double_dash ? metrics_.light : metrics_.heavy;
    }
    const auto extent = vertical ? metrics_.height : metrics_.width;
    const auto across = vertical ? metrics_.width : metrics_.height;
    const auto center = std::max(0.0F, std::floor((across - thickness) / 2));
    const auto dash_count = static_cast<float>(count);
    if (extent < 2 * dash_count) {
      addDash(vertical, center, 0, extent, thickness);

      return;
    }

    const auto gap = std::min(desired_gap, std::floor(extent / (2 * dash_count)));
    const auto total = extent - (gap * dash_count);
    const auto length = std::floor(total / dash_count);
    auto remainder = total - (length * dash_count);
    auto start = vertical ? 0 : std::floor(gap / 2);
    for (unsigned index = 0; index < count; ++index) {
      const auto extra = std::min(1.0F, remainder);
      remainder -= extra;
      const auto end = start + length + extra;
      addDash(vertical, center, start, end, thickness);
      start = end + gap;
    }
  }

  [[nodiscard]] static unsigned dashCount(std::uint32_t codepoint) noexcept {
    constexpr std::uint32_t first_double_dash = 0x254c;
    constexpr std::uint32_t first_quadruple_dash = 0x2508;
    if (codepoint >= first_double_dash) {
      return 2;
    }

    return codepoint >= first_quadruple_dash ? 4U : 3U;
  }

  void addDash(bool vertical, float center, float start, float end, float thickness) {
    if (vertical) {
      add(center, start, center + thickness, end);
    } else {
      add(start, center, end, center + thickness);
    }
  }

  [[nodiscard]] static Paint unite(std::span<const Rect> strokes) {
    std::array<float, 2 * stroke_capacity> edges{};
    for (std::size_t index = 0; index < strokes.size(); ++index) {
      edges[2 * index] = strokes[index].y;
      edges[(2 * index) + 1] = strokes[index].bottom();
    }

    const auto rows = std::span{edges}.first(2 * strokes.size());
    std::ranges::sort(rows);
    Paint result;
    for (std::size_t index = 1; index < rows.size(); ++index) {
      const auto top = rows[index - 1];
      const auto bottom = rows[index];
      if (top != bottom) {
        uniteBand(result, strokes, top, bottom);
      }
    }

    return result;
  }

  static void uniteBand(Paint &result, std::span<const Rect> strokes, float top, float bottom) {
    std::array<Interval, stroke_capacity> storage{};
    std::size_t count = 0;
    for (const auto rectangle : strokes) {
      if (rectangle.y <= top && rectangle.bottom() >= bottom) {
        storage[count++] = {.left = rectangle.x, .right = rectangle.right()};
      }
    }

    const auto intervals = std::span{storage}.first(count);
    std::ranges::sort(intervals, {}, &Interval::left);
    for (std::size_t index = 0; index < intervals.size();) {
      const auto left = intervals[index].left;
      auto right = intervals[index++].right;
      while (index < intervals.size() && intervals[index].left <= right) {
        right = std::max(right, intervals[index++].right);
      }

      result.appendMerged({.x = left, .y = top, .width = right - left, .height = bottom - top});
    }
  }

  BoxMetrics metrics_;
  Axis x_;
  Axis y_;
  Ink<stroke_capacity> strokes_;
};

}
