module;

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <array>
#include <cstddef>
#include <limits>
#include <span>
#include <stdexcept>


#include <bit>
#include <optional>
#include <string_view>


#include <initializer_list>


#include <concepts>
#include <functional>
#include <type_traits>
#include <utility>

export module telar.gui.terminal.glyphs.curve_cache;

export import telar.gui.core.metrics;


export import telar.gui.terminal.copy_mode;


export import telar.gui.terminal.font_grid;

// Interface: terminal/glyphs/ink.cppm
export {
namespace telar::gui::glyphs {

inline void validateCell(Rect cell) {
  constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();
  const auto finite_origin = std::isfinite(cell.x) && std::isfinite(cell.y);
  const auto finite_extent = std::isfinite(cell.width) && std::isfinite(cell.height);
  if (!finite_origin || !finite_extent || cell.width < 0 || cell.height < 0 || cell.width > maximum_extent || cell.height > maximum_extent) {
    throw std::invalid_argument{"InvalidCellBounds"};
  }
}

template <std::size_t Capacity>
class Ink {
public:
  inline explicit Ink(float coverage = 1) noexcept
      : coverage_(coverage) {}

  [[nodiscard]] inline float coverage() const noexcept {
    return coverage_;
  }

  [[nodiscard]] inline std::span<const Rect> rectangles() const noexcept {
    return std::span{rectangles_}.first(count_);
  }

  inline void push(Rect rectangle) {
    if (rectangle.empty()) {
      return;
    }

    if (count_ == Capacity) {
      throw std::length_error{"GlyphRectangleBudgetExceeded"};
    }

    rectangles_[count_++] = rectangle;
  }

  inline void appendMerged(Rect rectangle) {
    if (rectangle.empty()) {
      return;
    }

    for (auto &previous : std::span{rectangles_}.first(count_)) {
      if (previous.x == rectangle.x && previous.width == rectangle.width && previous.bottom() == rectangle.y) {
        previous.height += rectangle.height;

        return;
      }
    }

    push(rectangle);
  }

  inline void translate(Point origin) noexcept {
    for (auto &rectangle : std::span{rectangles_}.first(count_)) {
      rectangle.x += origin.x;
      rectangle.y += origin.y;
    }
  }

private:
  std::array<Rect, Capacity> rectangles_{};
  std::size_t count_ = 0;
  float coverage_;
};

}
}

// Interface: terminal/glyphs/block.cppm
export {
namespace telar::gui::glyphs {

class Block {
public:
  using Paint = Ink<2>;

  [[nodiscard]] inline static Paint draw(Rect cell, std::uint32_t codepoint) {
    validateCell(cell);
    if (codepoint < Symbol::first_block || codepoint > Symbol::last_block) {
      throw std::invalid_argument{"InvalidBlockElement"};
    }

    auto result = build(cell, codepoint);
    result.translate({.x = cell.x, .y = cell.y});

    return result;
  }

private:
  static constexpr unsigned upper_left = 1;
  static constexpr unsigned upper_right = 2;
  static constexpr unsigned lower_left = 4;
  static constexpr unsigned lower_right = 8;

  [[nodiscard]] inline static Paint build(Rect cell, std::uint32_t codepoint) {
    constexpr std::uint32_t lower_full = 0x2588;
    constexpr std::uint32_t left_first = 0x2589;
    constexpr std::uint32_t right_half = 0x2590;
    constexpr std::uint32_t first_shade = 0x2591;
    constexpr std::uint32_t last_shade = 0x2593;
    constexpr std::uint32_t top_eighth = 0x2594;
    constexpr std::uint32_t right_eighth = 0x2595;

    if (codepoint == Symbol::first_block || codepoint == top_eighth) {
      return slab(cell, Side::top, codepoint == top_eighth ? 1 : half_eighths);
    }

    if (codepoint <= lower_full) {
      return slab(cell, Side::bottom, codepoint - Symbol::first_block);
    }

    if (codepoint >= left_first && codepoint < right_half) {
      return slab(cell, Side::left, right_half - codepoint);
    }

    if (codepoint == right_half || codepoint == right_eighth) {
      return slab(cell, Side::right, codepoint == right_eighth ? 1 : half_eighths);
    }

    if (codepoint >= first_shade && codepoint <= last_shade) {
      constexpr float quarter_coverage = 0.25F;
      Paint result{static_cast<float>(codepoint - first_shade + 1) * quarter_coverage};
      result.push({.width = cell.width, .height = cell.height});

      return result;
    }

    constexpr std::uint32_t first_quadrant = 0x2596;
    constexpr std::array<std::uint8_t, 10> quadrants{
        lower_left,
        lower_right,
        upper_left,
        upper_left | lower_left | lower_right,
        upper_left | lower_right,
        upper_left | upper_right | lower_left,
        upper_left | upper_right | lower_right,
        upper_right,
        upper_right | lower_left,
        upper_right | lower_left | lower_right,
    };

    return quadrantInk(cell, quadrants[codepoint - first_quadrant]);
  }

  enum class Side : std::uint8_t {
    top,
    bottom,
    left,
    right,
  };

  static constexpr unsigned full_eighths = 8;
  static constexpr unsigned half_eighths = full_eighths / 2;

  [[nodiscard]] inline static float split(float extent, unsigned eighths) noexcept {
    return eighths >= full_eighths ? extent : std::round(extent * static_cast<float>(eighths) / full_eighths);
  }

  [[nodiscard]] inline static Paint slab(Rect cell, Side side, unsigned eighths) {
    Paint result;
    switch (side) {
    case Side::top:
      result.push({.width = cell.width, .height = split(cell.height, eighths)});
      break;
    case Side::bottom: {
      const auto top = split(cell.height, full_eighths - eighths);
      result.push({.y = top, .width = cell.width, .height = cell.height - top});
      break;
    }
    case Side::left:
      result.push({.width = split(cell.width, eighths), .height = cell.height});
      break;
    case Side::right: {
      const auto left = split(cell.width, full_eighths - eighths);
      result.push({.x = left, .width = cell.width - left, .height = cell.height});
      break;
    }
    }

    return result;
  }

  [[nodiscard]] inline static Paint quadrantInk(Rect cell, std::uint8_t mask) {
    const auto middle_x = split(cell.width, half_eighths);
    const auto middle_y = split(cell.height, half_eighths);
    const std::array<float, 2> tops{0, middle_y};
    const std::array<float, 2> bottoms{middle_y, cell.height};
    Paint result;
    for (std::size_t row = 0; row < tops.size(); ++row) {
      const auto left = (mask & (upper_left << (2 * row))) != 0;
      const auto right = (mask & (upper_right << (2 * row))) != 0;
      if (!left && !right) {
        continue;
      }

      const auto x = left ? 0 : middle_x;
      const auto right_edge = right ? cell.width : middle_x;
      result.appendMerged({.x = x, .y = tops[row], .width = right_edge - x, .height = bottoms[row] - tops[row]});
    }

    return result;
  }
};

}
}

// Interface: terminal/glyphs/box_metrics.cppm
export {
namespace telar::gui::glyphs {

struct BoxMetrics {
  float width = 0;
  float height = 0;
  float light = 0;
  float heavy = 0;

  [[nodiscard]] inline static BoxMetrics resolve(Rect cell, float thickness) {
    validateCell(cell);
    if (!std::isfinite(thickness) || thickness <= 0) {
      throw std::invalid_argument{"InvalidCellBounds"};
    }

    const auto minimum_extent = std::min(cell.width, cell.height);

    return {.width = cell.width, .height = cell.height, .light = std::min(minimum_extent, thickness), .heavy = std::min(minimum_extent, 2 * thickness)};
  }
};

}
}

// Interface: terminal/glyphs/box_edge_table.cppm
export {
#include "box_edge_table.inc"
}

// Interface: terminal/glyphs/box.cppm
export {
namespace telar::gui::glyphs {

class Box {
public:
  static constexpr std::size_t stroke_capacity = 8;
  static constexpr std::size_t rectangle_capacity = 21;
  using Paint = Ink<rectangle_capacity>;

  [[nodiscard]] inline static Paint draw(std::uint32_t codepoint, Rect cell, float thickness) {
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

    [[nodiscard]] inline static Axis resolve(float extent, const BoxMetrics &metrics) noexcept {
      const auto light_start = std::floor((extent - metrics.light) / 2);
      const auto heavy_start = std::floor((extent - metrics.heavy) / 2);

      return {.light_start = light_start, .light_end = light_start + metrics.light, .heavy_start = heavy_start, .heavy_end = heavy_start + metrics.heavy, .double_start = light_start - metrics.light, .double_end = (light_start + metrics.light) + metrics.light};
    }

    [[nodiscard]] inline Junction join(BoxWeight before, BoxWeight after, bool straight) const noexcept {
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

  inline explicit Box(BoxMetrics metrics) noexcept
      : metrics_(metrics),
        x_(Axis::resolve(metrics.width, metrics)),
        y_(Axis::resolve(metrics.height, metrics)) {}

  inline void add(float left, float top, float right, float bottom) {
    left = std::clamp(left, 0.0F, metrics_.width);
    top = std::clamp(top, 0.0F, metrics_.height);
    right = std::clamp(right, left, metrics_.width);
    bottom = std::clamp(bottom, top, metrics_.height);
    strokes_.push({.x = left, .y = top, .width = right - left, .height = bottom - top});
  }

  inline void intersection(const BoxEdges &edges) {
    const auto horizontal = x_.join(edges.up, edges.down, edges.left == edges.right);
    const auto vertical = y_.join(edges.left, edges.right, edges.up == edges.down);
    upperArm(edges, vertical.backward_end);
    rightArm(edges, horizontal.forward_start);
    lowerArm(edges, vertical.forward_start);
    leftArm(edges, horizontal.backward_end);
  }

  inline void upperArm(const BoxEdges &edges, float bottom) {
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

  inline void rightArm(const BoxEdges &edges, float left) {
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

  inline void lowerArm(const BoxEdges &edges, float top) {
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

  inline void leftArm(const BoxEdges &edges, float right) {
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

  inline void dashes(std::uint32_t codepoint) {
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

  [[nodiscard]] inline static unsigned dashCount(std::uint32_t codepoint) noexcept {
    constexpr std::uint32_t first_double_dash = 0x254c;
    constexpr std::uint32_t first_quadruple_dash = 0x2508;
    if (codepoint >= first_double_dash) {
      return 2;
    }

    return codepoint >= first_quadruple_dash ? 4U : 3U;
  }

  inline void addDash(bool vertical, float center, float start, float end, float thickness) {
    if (vertical) {
      add(center, start, center + thickness, end);
    } else {
      add(start, center, end, center + thickness);
    }
  }

  [[nodiscard]] inline static Paint unite(std::span<const Rect> strokes) {
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

  inline static void uniteBand(Paint &result, std::span<const Rect> strokes, float top, float bottom) {
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
}

// Interface: terminal/glyphs/box_curve.cppm
export {
namespace telar::gui::glyphs {

class BoxCurve {
public:
  enum class Shape : std::uint8_t {
    rounded_down_right,
    rounded_down_left,
    rounded_up_left,
    rounded_up_right,
    rising_diagonal,
    falling_diagonal,
    diagonal_cross,
  };

  static constexpr std::size_t shape_count = 7;

  BoxCurve(Shape shape, Rect cell, float thickness);
  [[nodiscard]] static std::optional<Shape> shape(std::uint32_t codepoint) noexcept;
  void rasterize(AlphaRaster raster) const;

private:
  static constexpr std::size_t curve_segments = 16;
  static constexpr std::size_t point_capacity = curve_segments + 3;

  struct PixelBounds {
    std::size_t left = 0;
    std::size_t top = 0;
    std::size_t right = 0;
    std::size_t bottom = 0;
  };

  [[nodiscard]] PixelBounds rasterBounds(const AlphaRaster &raster, Point scale) const noexcept;
  [[nodiscard]] float distanceSquared(Point point) const noexcept;
  [[nodiscard]] static float segmentDistance(Point point, const std::array<Point, 2> &segment) noexcept;

  BoxMetrics metrics_;
  std::array<Point, point_capacity> points_{};
  std::size_t count_ = 0;
  bool cross_ = false;
};

}
}

// Interface: terminal/glyphs/braille.cppm
export {
namespace telar::gui::glyphs {

class Braille {
public:
  static constexpr std::size_t dot_count = 8;
  using Paint = Ink<dot_count>;

  [[nodiscard]] inline static Paint draw(Rect cell, std::uint8_t dots) {
    validateCell(cell);
    const auto grid = cell.width < columns || cell.height < rows ? fractionalGrid(cell) : integerGrid(cell);
    Paint result;
    if (grid.diameter == 0) {
      return result;
    }

    constexpr std::array<unsigned, dot_count> dot_columns{0, 0, 0, 1, 1, 1, 0, 1};
    constexpr std::array<unsigned, dot_count> dot_rows{0, 1, 2, 0, 1, 2, 3, 3};
    for (std::size_t bit = 0; bit < dot_count; ++bit) {
      if ((dots & (1U << bit)) != 0) {
        result.push({.x = grid.x[dot_columns[bit]], .y = grid.y[dot_rows[bit]], .width = grid.diameter, .height = grid.diameter});
      }
    }

    return result;
  }

private:
  static constexpr int columns = 2;
  static constexpr int rows = 4;
  static constexpr int horizontal_divisions = 2 * columns;
  static constexpr int vertical_divisions = 2 * rows;

  struct Grid {
    std::array<float, columns> x{};
    std::array<float, rows> y{};
    float diameter = 0;
  };

  [[nodiscard]] inline static Grid fractionalGrid(Rect cell) noexcept {
    const auto diameter = std::min(cell.width / columns, cell.height / rows);
    constexpr std::array<float, rows> row_centers{1, 3, 5, 7};
    Grid result{.x = {cell.x + (cell.width / horizontal_divisions) - (diameter / 2), cell.x + (3 * cell.width / horizontal_divisions) - (diameter / 2)}, .diameter = diameter};
    for (std::size_t row = 0; row < result.y.size(); ++row) {
      result.y[row] = cell.y + (row_centers[row] * cell.height / vertical_divisions) - (diameter / 2);
    }

    return result;
  }

  [[nodiscard]] inline static Grid integerGrid(Rect cell) noexcept {
    const auto width = static_cast<int>(cell.width);
    const auto height = static_cast<int>(cell.height);
    auto diameter = std::min(width / horizontal_divisions, height / vertical_divisions);
    auto x_spacing = width / horizontal_divisions;
    auto y_spacing = height / vertical_divisions;
    auto x_margin = x_spacing / 2;
    auto y_margin = y_spacing / 2;
    auto x_remaining = width - (2 * x_margin) - x_spacing - (columns * diameter);
    auto y_remaining = height - (2 * y_margin) - ((rows - 1) * y_spacing) - (rows * diameter);
    if (x_remaining >= columns && y_remaining >= rows && diameter == 0) {
      ++diameter;
      x_remaining -= columns;
      y_remaining -= rows;
    }

    if (x_remaining >= 2 && x_margin == 0) {
      x_margin = 1;
      x_remaining -= 2;
    }

    if (y_remaining >= 2 && y_margin == 0) {
      y_margin = 1;
      y_remaining -= 2;
    }

    if (x_remaining >= 1) {
      ++x_spacing;
      --x_remaining;
    }

    if (y_remaining >= rows - 1) {
      ++y_spacing;
      y_remaining -= rows - 1;
    }

    if (x_remaining >= 2) {
      ++x_margin;
      x_remaining -= 2;
    }

    if (y_remaining >= 2) {
      ++y_margin;
      y_remaining -= 2;
    }

    if (x_remaining >= columns && y_remaining >= rows) {
      ++diameter;
    }

    Grid result{.diameter = static_cast<float>(diameter)};
    for (std::size_t column = 0; column < result.x.size(); ++column) {
      result.x[column] = cell.x + static_cast<float>(x_margin + (static_cast<int>(column) * (diameter + x_spacing)));
    }

    for (std::size_t row = 0; row < result.y.size(); ++row) {
      result.y[row] = cell.y + static_cast<float>(y_margin + (static_cast<int>(row) * (diameter + y_spacing)));
    }

    return result;
  }
};

}
}

// Interface: terminal/glyphs/curve_cache.cppm
export {
namespace telar::gui::glyphs {

template <std::movable Payload>
class CurveCache {
public:
  static constexpr std::size_t capacity = 56;
  static constexpr std::uint16_t raster_limit = 256;
  static constexpr std::uint16_t fallback_width = 16;
  static constexpr std::uint16_t fallback_height = 32;

  template <typename Builder>
    requires std::invocable<Builder> && std::same_as<std::invoke_result_t<Builder>, std::optional<Payload>>
  [[nodiscard]] Payload *resolve(const BoxMetrics &metrics, BoxCurve::Shape shape, Builder &&build) {
    const Key key{.width_bits = std::bit_cast<std::uint32_t>(metrics.width), .height_bits = std::bit_cast<std::uint32_t>(metrics.height), .thickness_bits = std::bit_cast<std::uint32_t>(metrics.light), .shape = shape};
    for (auto &entry : std::span{entries_}.first(count_)) {
      if (entry.key == key) {
        return entry.payload ? &*entry.payload : nullptr;
      }
    }

    if (count_ == capacity) {
      return nullptr;
    }

    auto &entry = entries_[count_++];
    entry.key = key;
    entry.payload = std::invoke(std::forward<Builder>(build));

    return entry.payload ? &*entry.payload : nullptr;
  }

  inline void reset() noexcept {
    for (auto &entry : std::span{entries_}.first(count_)) {
      entry.payload.reset();
    }

    count_ = 0;
  }

  [[nodiscard]] inline std::size_t size() const noexcept {
    return count_;
  }

private:
  struct Key {
    std::uint32_t width_bits = 0;
    std::uint32_t height_bits = 0;
    std::uint32_t thickness_bits = 0;
    BoxCurve::Shape shape = BoxCurve::Shape::rounded_down_right;

    bool operator==(const Key &) const = default;
  };

  struct Entry {
    Key key;
    std::optional<Payload> payload;
  };

  std::array<Entry, capacity> entries_{};
  std::size_t count_ = 0;
};

}
}
