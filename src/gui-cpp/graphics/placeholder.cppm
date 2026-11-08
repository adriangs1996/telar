module;
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cmath>
#include <cstdint>


#include "placeholder_diacritics.hpp"

#include <cstddef>


export module telar.gui.graphics.placeholder;

import std;

export import telar.gui.core.metrics;


export import telar.gui.core.json_writer;


export import telar.gui.presentation.activity_order;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;

// Interface: graphics/source_rect.cppm
export {
namespace telar::gui {

struct ImageSourceRect {
  std::uint32_t x = 0;
  std::uint32_t y = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;

  [[nodiscard]] inline static ImageSourceRect resolve(const GraphicsPlacement &placement, const ImageDescription &image) noexcept {
    const auto left = std::min(placement.source_x, image.width);
    const auto top = std::min(placement.source_y, image.height);
    const auto remaining_width = image.width - left;
    const auto remaining_height = image.height - top;

    return {.x = left, .y = top, .width = placement.source_width == 0 ? remaining_width : std::min(placement.source_width, remaining_width), .height = placement.source_height == 0 ? remaining_height : std::min(placement.source_height, remaining_height)};
  }

  [[nodiscard]] inline Rect pixels() const noexcept {
    return {.x = static_cast<float>(x), .y = static_cast<float>(y), .width = static_cast<float>(width), .height = static_cast<float>(height)};
  }
};

}
}

// Interface: graphics/display_box.cppm
export {
namespace telar::gui {

struct ImageDisplayBox {
  struct Cell {
    std::uint32_t width = 0;
    std::uint32_t height = 0;

    bool operator==(const Cell &) const noexcept = default;
  };

  std::int64_t x = 0;
  std::int64_t y = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;

  [[nodiscard]] inline static ImageDisplayBox resolve(const GraphicsPlacement &placement, ImageSourceRect source, Cell cell) noexcept {
    const auto offset_x = cell.width == 0 ? 0 : std::min(placement.offset_x, cell.width - 1);
    const auto offset_y = cell.height == 0 ? 0 : std::min(placement.offset_y, cell.height - 1);
    auto width = source.width;
    auto height = source.height;
    if (placement.columns != 0) {
      const auto filled = filledExtent(cell.width, placement.columns);
      width = filled - std::min(filled, offset_x);
    }

    if (placement.rows != 0) {
      const auto filled = filledExtent(cell.height, placement.rows);
      height = filled - std::min(filled, offset_y);
    }

    if (placement.columns != 0 && placement.rows == 0) {
      height = proportionalExtent(width, source.height, source.width);
    } else if (placement.columns == 0 && placement.rows != 0) {
      width = proportionalExtent(height, source.width, source.height);
    }

    return {.x = (static_cast<std::int64_t>(placement.x) * cell.width) + offset_x, .y = (static_cast<std::int64_t>(placement.y) * cell.height) + offset_y, .width = width, .height = height};
  }

private:
  [[nodiscard]] inline static std::uint32_t filledExtent(std::uint32_t cell, std::uint32_t count) noexcept {
    const auto extent = static_cast<std::uint64_t>(cell) * count;

    return static_cast<std::uint32_t>(std::min<std::uint64_t>(extent, std::numeric_limits<std::uint32_t>::max()));
  }

  [[nodiscard]] inline static std::uint32_t proportionalExtent(std::uint32_t value, std::uint32_t numerator, std::uint32_t denominator) noexcept {
    if (denominator == 0) {
      return 0;
    }

    const auto rounded = ((static_cast<std::uint64_t>(value) * numerator) + (denominator / 2)) / denominator;

    return static_cast<std::uint32_t>(std::min<std::uint64_t>(rounded, std::numeric_limits<std::uint32_t>::max()));
  }
};

}
}

// Interface: graphics/placement.cppm
export {
namespace telar::gui {

struct ImageGeometry {
  Rect source;
  Rect destination;

  [[nodiscard]] inline ImageGeometry clipped(Rect bounds) const noexcept {
    if (source.empty() || destination.empty()) {
      return {};
    }

    if (destination.x >= bounds.x && destination.y >= bounds.y && destination.right() <= bounds.right() && destination.bottom() <= bounds.bottom()) {
      return *this;
    }

    const auto visible = destination.intersect(bounds);
    if (visible.empty()) {
      return {};
    }

    const auto horizontal = source.width / destination.width;
    const auto vertical = source.height / destination.height;

    return {.source = {.x = source.x + ((visible.x - destination.x) * horizontal), .y = source.y + ((visible.y - destination.y) * vertical), .width = visible.width * horizontal, .height = visible.height * vertical}, .destination = visible};
  }

  [[nodiscard]] inline static Rect textureSource(Rect source, Rect texture) noexcept {
    const auto width = texture.width;
    const auto height = texture.height;
    if (source.x + source.width > width || source.y + source.height > height) {
      return {.width = width, .height = height};
    }

    return source;
  }

  [[nodiscard]] inline static Rect remapSource(Rect fragment, Rect original, Rect substitute) noexcept {
    if (original.empty()) {
      return {};
    }

    const auto horizontal = substitute.width / original.width;
    const auto vertical = substitute.height / original.height;

    return {.x = substitute.x + ((fragment.x - original.x) * horizontal), .y = substitute.y + ((fragment.y - original.y) * vertical), .width = fragment.width * horizontal, .height = fragment.height * vertical};
  }

  inline static ImageGeometry resolve(const GraphicsPlacement &placement, const ImageDescription &image, Point cell, float scale) noexcept {
    if (scale <= 0 || !std::isfinite(scale)) {
      return {};
    }

    const auto source = ImageSourceRect::resolve(placement, image);
    const auto box = ImageDisplayBox::resolve(placement, source, physicalCell(cell, scale));

    return {.source = source.pixels(), .destination = {.x = static_cast<float>(box.x) / scale, .y = static_cast<float>(box.y) / scale, .width = static_cast<float>(box.width) / scale, .height = static_cast<float>(box.height) / scale}};
  }

  [[nodiscard]] inline static ImageDisplayBox::Cell physicalCell(Point logical, float scale) noexcept {
    if (scale <= 0 || !std::isfinite(scale)) {
      return {};
    }

    return {.width = physicalExtent(logical.x, scale), .height = physicalExtent(logical.y, scale)};
  }

private:
  [[nodiscard]] inline static std::uint32_t physicalExtent(float logical, float scale) noexcept {
    if (!std::isfinite(logical) || logical <= 0) {
      return 0;
    }

    const auto pixels = std::round(static_cast<double>(logical) * scale);
    const auto bounded = std::clamp(pixels, 0.0, static_cast<double>(std::numeric_limits<std::uint32_t>::max()));

    return static_cast<std::uint32_t>(bounded);
  }
};

inline bool placementOrder(const GraphicsPlacement &left, const GraphicsPlacement &right) noexcept {
  if (left.z_index != right.z_index) {
    return left.z_index < right.z_index;
  }

  if (left.key.image_id != right.key.image_id) {
    return left.key.image_id < right.key.image_id;
  }

  return left.virtual_id < right.virtual_id;
}

}
}

// Interface: graphics/placeholder.cppm
export {
namespace telar::gui {

struct PlaceholderCell {
  std::uint32_t image_low = 0;
  std::uint32_t placement = 0;
  std::optional<std::uint32_t> row;
  std::optional<std::uint32_t> column;
  std::optional<std::uint32_t> image_high;
};

inline std::optional<std::uint32_t> placeholderMark(std::string_view &text) noexcept {
  if (text.empty()) {
    return {};
  }

  const auto first = static_cast<unsigned>(static_cast<unsigned char>(text.front()));
  constexpr unsigned two_byte_prefix = 0xc0;
  constexpr unsigned three_byte_prefix = 0xe0;
  constexpr unsigned four_byte_prefix = 0xf0;
  std::size_t length = 1;
  if (first >= four_byte_prefix) {
    length = 4;
  } else if (first >= three_byte_prefix) {
    length = 3;
  } else if (first >= two_byte_prefix) {
    length = 2;
  }
  if (text.size() < length) {
    text = {};

    return {};
  }

  constexpr unsigned continuation_mask = 0x3f;
  constexpr unsigned continuation_shift = 6;
  constexpr unsigned continuation_prefix_mask = 0xc0;
  constexpr unsigned continuation_prefix = 0x80;
  constexpr std::array<unsigned, 4> leading_masks{0x7f, 0x1f, 0x0f, 0x07};
  const auto first_mask = leading_masks[length - 1];
  auto codepoint = first & first_mask;
  for (std::size_t index = 1; index < length; ++index) {
    const auto continuation = static_cast<unsigned>(static_cast<unsigned char>(text[index]));
    if ((continuation & continuation_prefix_mask) != continuation_prefix) {
      text = {};

      return {};
    }

    codepoint = (codepoint << continuation_shift) | (continuation & continuation_mask);
  }

  text.remove_prefix(length);
  const auto *const found = std::ranges::lower_bound(placeholder_diacritics, codepoint);

  return found == placeholder_diacritics.end() || *found != codepoint ? std::nullopt : std::optional{static_cast<std::uint32_t>(found - placeholder_diacritics.begin())};
}

inline std::uint32_t placeholderColor(const CellColor &color) noexcept {
  constexpr unsigned channel_bits = 8;
  if (color.kind == CellColor::Kind::default_color) {
    return 0;
  }

  return color.kind == CellColor::Kind::indexed ? color.channels[0] : (static_cast<std::uint32_t>(color.channels[0]) << (channel_bits * 2)) | (static_cast<std::uint32_t>(color.channels[1]) << channel_bits) | color.channels[2];
}

inline std::optional<PlaceholderCell> parsePlaceholder(const CellValue &cell) noexcept {
  auto text = cell.utf8();
  if (!text.starts_with(placeholder_prefix)) {
    return {};
  }

  text.remove_prefix(placeholder_prefix.size());
  PlaceholderCell result;
  result.image_low = placeholderColor(cell.style.foreground);
  result.placement = placeholderColor(cell.style.underline_color);
  result.row = placeholderMark(text);
  result.column = placeholderMark(text);
  result.image_high = placeholderMark(text);
  constexpr unsigned maximum_image_high = 255;
  if (result.image_high && *result.image_high > maximum_image_high) {
    result.image_high.reset();
  }

  return result;
}

struct PlaceholderRun {
  std::uint32_t screen_column = 0;
  std::uint32_t image_id = 0;
  std::uint32_t placement_id = 0;
  std::uint32_t row = 0;
  std::uint32_t column = 0;
  std::uint32_t width = 1;
  std::uint32_t image_low = 0;
  std::optional<std::uint32_t> image_high;

  inline static PlaceholderRun begin(const PlaceholderCell &cell, std::uint32_t screen_column) noexcept {
    constexpr unsigned high_shift = 24;

    return {.screen_column = screen_column, .image_id = cell.image_low | (cell.image_high.value_or(0) << high_shift), .placement_id = cell.placement, .row = cell.row.value_or(0), .column = cell.column.value_or(0), .width = 1, .image_low = cell.image_low, .image_high = cell.image_high};
  }

  inline bool extend(const PlaceholderCell &cell) noexcept {
    if (cell.image_low != image_low || cell.placement != placement_id || (cell.row && *cell.row != row) || (cell.column && *cell.column != column + width) || (cell.image_high && cell.image_high != image_high)) {
      return false;
    }

    ++width;

    return true;
  }
};

inline ImageGeometry placeholderGeometry(const PlaceholderRun &run, const GraphicsPlacement &placement, ImageGeometry base, Point cell, float scale) noexcept {
  if (base.source.empty() || cell.x <= 0 || cell.y <= 0 || scale <= 0) {
    return {};
  }

  const auto columns = placement.columns == 0 ? std::ceil(base.source.width / (cell.x * scale)) : static_cast<float>(placement.columns);
  const auto rows = placement.rows == 0 ? std::ceil(base.source.height / (cell.y * scale)) : static_cast<float>(placement.rows);
  constexpr float maximum_grid_side = 65535;
  if (columns <= 0 || rows <= 0 || columns > maximum_grid_side || rows > maximum_grid_side) {
    return {};
  }

  const auto fitted_scale = std::min(columns * cell.x * scale / base.source.width, rows * cell.y * scale / base.source.height);
  const auto margin_x = ((columns * cell.x * scale) - (base.source.width * fitted_scale)) / 2 / fitted_scale;
  const auto margin_y = ((rows * cell.y * scale) - (base.source.height * fitted_scale)) / 2 / fitted_scale;
  const auto padded_width = base.source.width + (2 * margin_x);
  const auto padded_height = base.source.height + (2 * margin_y);
  const auto start_x = padded_width * static_cast<float>(run.column) / columns;
  const auto start_y = padded_height * static_cast<float>(run.row) / rows;
  const auto visible_x = std::max(start_x, margin_x);
  const auto visible_y = std::max(start_y, margin_y);
  const auto width = std::min(start_x + (padded_width * static_cast<float>(run.width) / columns), margin_x + base.source.width) - visible_x;
  const auto height = std::min(start_y + (padded_height / rows), margin_y + base.source.height) - visible_y;
  if (width <= 0 || height <= 0) {
    return {};
  }

  return {.source = {.x = base.source.x + std::round(visible_x - margin_x), .y = base.source.y + std::round(visible_y - margin_y), .width = std::round(width), .height = std::round(height)}, .destination = {.x = (static_cast<float>(run.screen_column) * cell.x) + (std::round((visible_x - start_x) * fitted_scale) / scale), .y = std::round((visible_y - start_y) * fitted_scale) / scale, .width = std::round(width * fitted_scale) / scale, .height = std::round(height * fitted_scale) / scale}};
}

inline ImageGeometry placeholderGeometry(const PlaceholderRun &run, const GraphicsPlacement &placement, const ImageDescription &image, Point cell, float scale) noexcept {
  return placeholderGeometry(run, placement, ImageGeometry::resolve(placement, image, cell, scale), cell, scale);
}

}
}

// Interface: graphics/rounded_rectangle.cppm
export {
namespace telar::gui {

struct RoundedRectangleStyle {
  Color fill{.a = 0};
  Color border{.a = 0};
  float radius = 0;
  float border_width = 0;
  Color backdrop{.a = 0};
  bool replace_background = false;
  bool square_bottom = false;

  bool operator==(const RoundedRectangleStyle &) const = default;
};

struct RoundedRectangle {
  Point size;
  RoundedRectangleStyle style;

  [[nodiscard]] inline static RoundedRectangle resolve(Point size, RoundedRectangleStyle style) noexcept {
    style.radius = std::min(style.radius, std::min(size.x, size.y) / 2);

    return {.size = size, .style = style};
  }

  [[nodiscard]] inline Color sample(Point local) const noexcept {
    if (style.radius == 0 && style.border_width == 0) {
      return style.fill;
    }

    constexpr float pixel_center = 0.5F;
    const Point half_size{.x = size.x * pixel_center, .y = size.y * pixel_center};
    const auto radius = style.square_bottom && local.y > half_size.y ? 0 : style.radius;
    const auto horizontal = std::abs(local.x - half_size.x) - half_size.x + radius;
    const auto vertical = std::abs(local.y - half_size.y) - half_size.y + radius;
    const auto outside_horizontal = std::max(horizontal, 0.0F);
    const auto outside_vertical = std::max(vertical, 0.0F);
    const auto distance = std::sqrt((outside_horizontal * outside_horizontal) + (outside_vertical * outside_vertical)) + std::min(std::max(horizontal, vertical), 0.0F) - radius;
    const auto outer = 1 - std::clamp(distance + pixel_center, 0.0F, 1.0F);
    const auto inner = 1 - std::clamp(distance + style.border_width + pixel_center, 0.0F, 1.0F);
    const auto fill_alpha = style.fill.a * inner;
    const auto border_alpha = style.border.a * (outer - inner);
    const auto backdrop_alpha = style.replace_background ? style.backdrop.a * (1 - outer) : 0;
    const auto alpha = fill_alpha + border_alpha + backdrop_alpha;
    if (alpha <= 0) {
      return {.a = 0};
    }

    return {.r = ((style.fill.r * fill_alpha) + (style.border.r * border_alpha) + (style.backdrop.r * backdrop_alpha)) / alpha, .g = ((style.fill.g * fill_alpha) + (style.border.g * border_alpha) + (style.backdrop.g * backdrop_alpha)) / alpha, .b = ((style.fill.b * fill_alpha) + (style.border.b * border_alpha) + (style.backdrop.b * backdrop_alpha)) / alpha, .a = alpha};
  }

  bool operator==(const RoundedRectangle &) const = default;
};

struct RoundedRectanglePaint {
  Point origin{};
  RoundedRectangle shape;

  [[nodiscard]] inline RoundedRectanglePaint clipped(Rect clip) const noexcept {
    const auto size = shape.size;
    if (origin.x >= clip.x && origin.y >= clip.y && origin.x + size.x <= clip.x + clip.width && origin.y + size.y <= clip.y + clip.height) {
      return *this;
    }

    const auto left = std::fmax(origin.x, clip.x);
    const auto top = std::fmax(origin.y, clip.y);
    const auto right = std::fmax(left, std::fmin(origin.x + size.x, clip.x + clip.width));
    const auto bottom = std::fmax(top, std::fmin(origin.y + size.y, clip.y + clip.height));
    auto paint = *this;
    paint.origin = {.x = left, .y = top};
    paint.shape.size = {.x = right - left, .y = bottom - top};

    return paint;
  }
};

}
}

// Interface: graphics/progress_ring.cppm
export {
namespace telar::gui {

struct ProgressRing {
  static constexpr std::size_t segments = 64;
  static constexpr std::size_t maximum_paints = segments + 2;
  static constexpr float stroke_ratio = 0.12F;
  static constexpr float track_alpha = 0.18F;
  Rect area;
  Color color;
  float fraction = 0;
  float rotation = 0;

  template <typename Visitor>
  inline void visit(Visitor visitor) const {
    const auto side = std::min(area.width, area.height);
    if (!std::isfinite(side) || side <= 0 || !std::isfinite(fraction) || !std::isfinite(rotation)) {
      return;
    }

    const auto stroke = std::min(side / 4, std::max(1.0F, side * stroke_ratio));
    const Point origin{.x = area.x + ((area.width - side) / 2), .y = area.y + ((area.height - side) / 2)};
    auto track = color;
    track.a *= track_alpha;
    visitor(RoundedRectanglePaint{.origin = origin, .shape = RoundedRectangle::resolve({.x = side, .y = side}, {.border = track, .radius = side / 2, .border_width = stroke})});
    const auto filled = std::clamp(fraction, 0.0F, 1.0F);
    if (filled == 0) {
      return;
    }

    const auto radius = (side - stroke) / 2;
    const auto axis = endpoint(rotation);
    const auto cosine = -axis.y;
    const auto sine = axis.x;
    const auto steps = static_cast<std::size_t>(std::ceil(filled * segments));
    for (std::size_t index = 0; index <= steps; ++index) {
      const auto point = index == steps ? endpoint(filled) : circle[index];
      const auto x = (point.x * cosine) - (point.y * sine);
      const auto y = (point.x * sine) + (point.y * cosine);
      visitor(RoundedRectanglePaint{.origin = {.x = origin.x + radius + (x * radius), .y = origin.y + radius + (y * radius)}, .shape = RoundedRectangle::resolve({.x = stroke, .y = stroke}, {.fill = color, .radius = stroke / 2})});
    }
  }

private:
  [[nodiscard]] inline static Point endpoint(float fraction) noexcept {
    const auto angle = static_cast<double>(fraction * (2 * std::numbers::pi_v<float>));

    return {.x = static_cast<float>(std::sin(angle)), .y = -static_cast<float>(std::cos(angle))};
  }

  inline static const auto circle = [] noexcept {
    std::array<Point, segments> points{};
    for (std::size_t index = 0; index < points.size(); ++index) {
      points[index] = endpoint(static_cast<float>(index) / segments);
    }

    return points;
  }();
};

}
}

// Interface: graphics/progress_capsule.cppm
export {
namespace telar::gui {

struct ProgressCapsule {
  static constexpr std::size_t maximum_paints = ProgressRing::maximum_paints + 3;
  Rect area;
  Color color;
  float ratio = 1;
  PaneProgressState state = PaneProgressState::remove;
  float fraction = 0;
  float rotation = 0;
  bool compact = true;

  template <typename Visitor>
  inline void visit(Visitor append) const {
    if (state == PaneProgressState::remove || area.empty()) {
      return;
    }

    const auto geometry = ProgressGeometry::derive(area, ratio, state, compact);
    const auto bounds = geometry.background;
    auto background = color;
    background.a *= ProgressGeometry::background_alpha;
    append(RoundedRectanglePaint{.origin = {.x = bounds.x, .y = bounds.y}, .shape = RoundedRectangle::resolve({.x = bounds.width, .y = bounds.height}, {.fill = background, .radius = bounds.height / 2})});
    if (geometry.ring.width <= 0) {
      return;
    }

    ProgressRing{.area = geometry.ring, .color = color, .fraction = fraction, .rotation = rotation}.visit(append);
    for (std::size_t index = 0; index < geometry.mark_count; ++index) {
      const auto mark = geometry.marks[index];
      append(RoundedRectanglePaint{.origin = {.x = mark.x, .y = mark.y}, .shape = RoundedRectangle::resolve({.x = mark.width, .y = mark.height}, {.fill = color, .radius = geometry.mark_radius})});
    }
  }
};

}
}
