module telar.gui.foundation.fonts;

import std;

import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::inline foundation::inline fonts::glyphs {

  namespace {

    // Whether `lower` starts where `upper` ends, over the same columns: the two make one rectangle.
    bool stacks(Rect upper, Rect lower) noexcept {
      return std::equal_to<>{}(upper.x, lower.x) && std::equal_to<>{}(upper.width, lower.width) && std::equal_to<>{}(upper.bottom(), lower.y);
    }

  }

  void validateCell(Rect cell) {
    constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();
    const auto finite_origin = std::isfinite(cell.x) && std::isfinite(cell.y);
    const auto finite_extent = std::isfinite(cell.width) && std::isfinite(cell.height);
    if (!finite_origin || !finite_extent || cell.width < 0 || cell.height < 0 || cell.width > maximum_extent || cell.height > maximum_extent) {
      throw std::invalid_argument{"InvalidCellBounds"};
    }
  }

  template <std::size_t Capacity>
  Ink<Capacity>::Ink(float coverage) noexcept
      : coverage_(coverage) {}

  template <std::size_t Capacity>
  float Ink<Capacity>::coverage() const noexcept {
    return coverage_;
  }

  template <std::size_t Capacity>
  std::span<const Rect> Ink<Capacity>::rectangles() const noexcept {
    return std::span{rectangles_}.first(count_);
  }

  template <std::size_t Capacity>
  void Ink<Capacity>::push(Rect rectangle) {
    if (rectangle.empty()) {
      return;
    }

    if (count_ == Capacity) {
      throw std::length_error{"GlyphRectangleBudgetExceeded"};
    }

    rectangles_.atMut(count_++) = rectangle;
  }

  template <std::size_t Capacity>
  void Ink<Capacity>::appendMerged(Rect rectangle) {
    if (rectangle.empty()) {
      return;
    }

    for (auto& previous : rectangles_.viewMut().first(count_)) {
      if (stacks(previous, rectangle)) {
        previous.height += rectangle.height;

        return;
      }
    }

    push(rectangle);
  }

  template <std::size_t Capacity>
  void Ink<Capacity>::translate(Point origin) noexcept {
    for (auto& rectangle : rectangles_.viewMut().first(count_)) {
      rectangle.x += origin.x;
      rectangle.y += origin.y;
    }
  }

  // Braille shares the stroke capacity of Box, so its ink is the same instance.
  static_assert(Braille::dot_count == Box::stroke_capacity);

  template class Ink<2>;
  template class Ink<Box::stroke_capacity>;
  template class Ink<Box::rectangle_capacity>;

  Block::Paint Block::draw(Rect cell, std::uint32_t codepoint) {
    validateCell(cell);
    if (codepoint < Symbol::first_block || codepoint > Symbol::last_block) {
      throw std::invalid_argument{"InvalidBlockElement"};
    }

    auto result = build(cell, codepoint);

    result.translate({.x = cell.x, .y = cell.y});

    return result;
  }

  Block::Paint Block::build(Rect cell, std::uint32_t codepoint) {
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
    constexpr ds::Array<std::uint8_t, 10> quadrants{
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

  float Block::split(float extent, unsigned eighths) noexcept {
    return eighths >= full_eighths ? extent : std::round(extent * static_cast<float>(eighths) / full_eighths);
  }

  Block::Paint Block::slab(Rect cell, Side side, unsigned eighths) {
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

  Block::Paint Block::quadrantInk(Rect cell, std::uint8_t mask) {
    const auto middle_x = split(cell.width, half_eighths);
    const auto middle_y = split(cell.height, half_eighths);
    // A row with neither of its quadrants comes out with no width, which the ink skips.
    const auto band = [&](unsigned row) -> Rect {
      const auto top = row == 0 ? 0.0F : middle_y;
      const auto bottom = row == 0 ? middle_y : cell.height;
      const auto x = (mask & (upper_left << (2 * row))) != 0 ? 0 : middle_x;
      const auto right_edge = (mask & (upper_right << (2 * row))) != 0 ? cell.width : middle_x;

      return {.x = x, .y = top, .width = right_edge - x, .height = bottom - top};
    };

    auto upper = band(0);
    const auto lower = band(1);
    Paint result;

    // Two bands that line up make one rectangle, as Ink::appendMerged would join them; with only
    // two, the ink needs no search for the band to join.
    if (!upper.empty() && !lower.empty() && stacks(upper, lower)) {
      upper.height += lower.height;
      result.push(upper);

      return result;
    }

    result.push(upper);
    result.push(lower);

    return result;
  }

  BoxMetrics BoxMetrics::resolve(Rect cell, float thickness) {
    validateCell(cell);
    if (!std::isfinite(thickness) || thickness <= 0) {
      throw std::invalid_argument{"InvalidCellBounds"};
    }

    const auto minimum_extent = std::min(cell.width, cell.height);

    return {.width = cell.width, .height = cell.height, .light = std::min(minimum_extent, thickness), .heavy = std::min(minimum_extent, 2 * thickness)};
  }

  Box::Paint Box::draw(std::uint32_t codepoint, Rect cell, float thickness) {
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

  Box::Axis Box::Axis::resolve(float extent, const BoxMetrics& metrics) noexcept {
    const auto light_start = std::floor((extent - metrics.light) / 2);
    const auto heavy_start = std::floor((extent - metrics.heavy) / 2);

    return {.light_start = light_start, .light_end = light_start + metrics.light, .heavy_start = heavy_start, .heavy_end = heavy_start + metrics.heavy, .double_start = light_start - metrics.light, .double_end = (light_start + metrics.light) + metrics.light};
  }

  Box::Junction Box::Axis::join(BoxWeight before, BoxWeight after, bool straight) const noexcept {
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

  Box::Box(BoxMetrics metrics) noexcept
      : metrics_(metrics),
        x_(Axis::resolve(metrics.width, metrics)),
        y_(Axis::resolve(metrics.height, metrics)) {}

  void Box::add(float left, float top, float right, float bottom) {
    left = std::clamp(left, 0.0F, metrics_.width);
    top = std::clamp(top, 0.0F, metrics_.height);
    right = std::clamp(right, left, metrics_.width);
    bottom = std::clamp(bottom, top, metrics_.height);
    strokes_.push({.x = left, .y = top, .width = right - left, .height = bottom - top});
  }

  void Box::intersection(const BoxEdges& edges) {
    const auto horizontal = x_.join(edges.up, edges.down, edges.left == edges.right);
    const auto vertical = y_.join(edges.left, edges.right, edges.up == edges.down);

    upperArm(edges, vertical.backward_end);
    rightArm(edges, horizontal.forward_start);
    lowerArm(edges, vertical.forward_start);
    leftArm(edges, horizontal.backward_end);
  }

  void Box::upperArm(const BoxEdges& edges, float bottom) {
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

  void Box::rightArm(const BoxEdges& edges, float left) {
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

  void Box::lowerArm(const BoxEdges& edges, float top) {
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

  void Box::leftArm(const BoxEdges& edges, float right) {
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

  void Box::dashes(std::uint32_t codepoint) {
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

  unsigned Box::dashCount(std::uint32_t codepoint) noexcept {
    constexpr std::uint32_t first_double_dash = 0x254c;
    constexpr std::uint32_t first_quadruple_dash = 0x2508;

    if (codepoint >= first_double_dash) {
      return 2;
    }

    return codepoint >= first_quadruple_dash ? 4U : 3U;
  }

  void Box::addDash(bool vertical, float center, float start, float end, float thickness) {
    if (vertical) {
      add(center, start, center + thickness, end);
    } else {
      add(start, center, end, center + thickness);
    }
  }

  Box::Paint Box::unite(std::span<const Rect> strokes) {
    ds::Array<float, 2 * stroke_capacity> edges{};

    for (std::size_t index = 0; index < strokes.size(); ++index) {
      edges.atMut(2 * index) = strokes[index].y;
      edges.atMut((2 * index) + 1) = strokes[index].bottom();
    }

    const auto rows = edges.viewMut().first(2 * strokes.size());

    std::ranges::sort(rows);
    Paint result;

    for (std::size_t index = 1; index < rows.size(); ++index) {
      const auto top = rows[index - 1];
      const auto bottom = rows[index];
      if (std::not_equal_to<>{}(top, bottom)) {
        uniteBand(result, strokes, top, bottom);
      }
    }

    return result;
  }

  void Box::uniteBand(Paint& result, std::span<const Rect> strokes, float top, float bottom) {
    ds::Array<Interval, stroke_capacity> storage{};
    std::size_t count = 0;

    for (const auto rectangle : strokes) {
      if (rectangle.y <= top && rectangle.bottom() >= bottom) {
        storage.atMut(count++) = {.left = rectangle.x, .right = rectangle.right()};
      }
    }

    const auto intervals = storage.viewMut().first(count);

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

  Braille::Paint Braille::draw(Rect cell, std::uint8_t dots) {
    validateCell(cell);
    const auto grid = cell.width < columns || cell.height < rows ? fractionalGrid(cell) : integerGrid(cell);
    Paint result;

    if (std::equal_to<>{}(grid.diameter, 0.0F)) {
      return result;
    }

    constexpr ds::Array<unsigned, dot_count> dot_columns{0, 0, 0, 1, 1, 1, 0, 1};
    constexpr ds::Array<unsigned, dot_count> dot_rows{0, 1, 2, 0, 1, 2, 3, 3};

    for (std::size_t bit = 0; bit < dot_count; ++bit) {
      if ((dots & (1U << bit)) != 0) {
        result.push({.x = grid.x[dot_columns[bit]], .y = grid.y[dot_rows[bit]], .width = grid.diameter, .height = grid.diameter});
      }
    }

    return result;
  }

  Braille::Grid Braille::fractionalGrid(Rect cell) noexcept {
    const auto diameter = std::min(cell.width / columns, cell.height / rows);
    constexpr ds::Array<float, rows> row_centers{1, 3, 5, 7};
    Grid result{.x = {cell.x + (cell.width / horizontal_divisions) - (diameter / 2), cell.x + (3 * cell.width / horizontal_divisions) - (diameter / 2)}, .diameter = diameter};

    for (std::size_t row = 0; row < result.y.size(); ++row) {
      result.y.atMut(row) = cell.y + (row_centers[row] * cell.height / vertical_divisions) - (diameter / 2);
    }

    return result;
  }

  Braille::Grid Braille::integerGrid(Rect cell) noexcept {
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
      result.x.atMut(column) = cell.x + static_cast<float>(x_margin + (static_cast<int>(column) * (diameter + x_spacing)));
    }

    for (std::size_t row = 0; row < result.y.size(); ++row) {
      result.y.atMut(row) = cell.y + static_cast<float>(y_margin + (static_cast<int>(row) * (diameter + y_spacing)));
    }

    return result;
  }

}
