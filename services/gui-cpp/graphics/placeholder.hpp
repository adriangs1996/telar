#pragma once

#include "core/placeholder_prefix.hpp"
#include "placeholder_diacritics.hpp"
#include "placement.hpp"
#include "terminal/screen.hpp"
#include <algorithm>
#include <array>
#include <optional>

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

  static PlaceholderRun begin(const PlaceholderCell &cell, std::uint32_t screen_column) noexcept {
    constexpr unsigned high_shift = 24;

    return {.screen_column = screen_column, .image_id = cell.image_low | (cell.image_high.value_or(0) << high_shift), .placement_id = cell.placement, .row = cell.row.value_or(0), .column = cell.column.value_or(0), .width = 1, .image_low = cell.image_low, .image_high = cell.image_high};
  }

  bool extend(const PlaceholderCell &cell) noexcept {
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
