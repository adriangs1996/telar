module telar.gui.terminal.font_grid;

import std;

import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.base.text;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.wire.clipboard;
import telar.wire.vocabulary;

namespace telar::gui {

  namespace {

    template <std::unsigned_integral Coordinate>
    Coordinate coordinate(std::string_view text) {
      if (text.empty() || text.front() == '_' || text.back() == '_') {
        throw EncodingError{"Invalid copy range coordinate"};
      }

      const auto result = runtime::unsignedNumber<Coordinate>(text);
      if (!result) {
        throw EncodingError{result.error() == runtime::NumberError::overflow ? "Copy range coordinate exceeds capacity" : "Invalid copy range digit"};
      }

      return *result;
    }

    template <std::unsigned_integral Coordinate>
    Coordinate takeCoordinate(std::string_view& text, char separator) {
      const auto boundary = text.find(separator);
      if (boundary == std::string_view::npos) {
        throw EncodingError{"Invalid copy range separators"};
      }

      const auto result = coordinate<Coordinate>(text.substr(0, boundary));

      text.remove_prefix(boundary + 1);

      return result;
    }

  }

  std::uint32_t CopyGrid::maximumOffset() const noexcept {
    return scroll.total_rows - std::min<std::uint32_t>(scroll.total_rows, rows);
  }

  std::uint32_t CopyGrid::lastRow() const noexcept {
    return scroll.total_rows == 0 ? 0 : scroll.total_rows - 1;
  }

  const CellValue* CopyGrid::cell(CopyPoint point) const noexcept {
    if (point.x >= columns || point.y < scroll.offset || point.y - scroll.offset >= rows) {
      return nullptr;
    }

    const auto index = (static_cast<std::size_t>(point.y - scroll.offset) * columns) + point.x;

    return index < cells.size() ? &cells[index] : nullptr;
  }

  bool CopyGrid::whitespace(char byte) noexcept {
    return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\x0b' || byte == '\x0c';
  }

  std::optional<CopyWordClass> CopyGrid::wordClass(CopyPoint point) const noexcept {
    const auto* value = cell(point);
    if (value == nullptr) {
      return {};
    }

    const auto text = value->utf8();
    if (text.empty() || whitespace(text.front())) {
      return CopyWordClass::space;
    }

    const auto byte = text.front();
    const auto word = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_';

    return word ? CopyWordClass::word : CopyWordClass::punctuation;
  }

  CopyPoint CopyGrid::step(CopyPoint point, CopyDirection direction) const noexcept {
    if (direction == CopyDirection::forward) {
      if (static_cast<unsigned>(point.x) + 1 < columns) {
        ++point.x;
      } else if (point.y < lastRow()) {
        point.x = 0;
        ++point.y;
      }
    } else if (point.x != 0) {
      --point.x;
    } else if (point.y != 0) {
      point.x = columns == 0 ? 0 : columns - 1;
      --point.y;
    }

    return point;
  }

  bool CopyGrid::blankRow(std::uint32_t absolute_row) const noexcept {
    for (std::uint16_t column = 0; column < columns; ++column) {
      const auto* value = cell({.x = column, .y = absolute_row});
      if (value == nullptr) {
        return false;
      }

      const auto text = value->utf8();
      if (!text.empty() && !whitespace(text.front())) {
        return false;
      }
    }

    return true;
  }

  std::array<CopyPoint, 2> CopyGrid::pointerSpan(CopyPoint point, CopyGranularity granularity) const noexcept {
    auto first = point;
    auto last = point;

    if (granularity == CopyGranularity::line) {
      first.x = 0;
      last.x = columns == 0 ? 0 : columns - 1;
    } else if (granularity == CopyGranularity::word) {
      const auto word = pointerWord(point);

      while (first.x != 0 && pointerWord({.x = static_cast<std::uint16_t>(first.x - 1), .y = point.y}) == word) {
        --first.x;
      }

      while (static_cast<unsigned>(last.x) + 1 < columns && pointerWord({.x = static_cast<std::uint16_t>(last.x + 1), .y = point.y}) == word) {
        ++last.x;
      }
    }

    const auto* first_cell = cell(first);
    const auto* last_cell = cell(last);

    if (first_cell != nullptr && first_cell->width == CellWidth::continuation && first.x != 0) {
      --first.x;
    }

    if (last_cell != nullptr && last_cell->width == CellWidth::wide && static_cast<unsigned>(last.x) + 1 < columns) {
      ++last.x;
    }

    return {first, last};
  }

  bool CopyGrid::pointerWord(CopyPoint point) const noexcept {
    const auto* value = cell(point);
    if (value == nullptr) {
      return false;
    }

    const auto text = value->utf8();

    return value->width == CellWidth::continuation || (!text.empty() && text.front() != ' ');
  }

  template <Allocator Memory>
  CopyGrid copyGrid(const Screen<Memory>& screen) noexcept {
    return {screen.cells(), screen.columns(), screen.rows(), screen.scroll()};
  }

  template <Allocator Memory>
  WheelRoute wheelRoute(const Screen<Memory>& screen) noexcept {
    const auto& mouse = screen.mouse();
    if (mouse.sgr && (mouse.tracking == MouseTracking::normal || mouse.tracking == MouseTracking::button || mouse.tracking == MouseTracking::any)) {
      return WheelRoute::report;
    }

    const auto& modes = screen.modes();

    return modes.alternate_screen && modes.alternate_scroll && screen.scroll().offset == copyGrid(screen).maximumOffset() ? WheelRoute::keys : WheelRoute::scroll;
  }

  CopySelection CopyRangeParser::parse(std::uint64_t pane_id, std::string_view text) {
    if (pane_id == 0) {
      throw EncodingError{"Invalid copy pane identity"};
    }

    CopySelection selection;

    selection.pane_id = pane_id;
    selection.start_x = takeCoordinate<std::uint16_t>(text, ',');
    selection.start_y = takeCoordinate<std::uint32_t>(text, ':');
    selection.end_x = takeCoordinate<std::uint16_t>(text, ',');
    selection.end_y = coordinate<std::uint32_t>(text);

    return selection;
  }

  std::int32_t FontMetrics::roundFixed(std::int64_t value) {
    constexpr std::int64_t fixed_unit = 64;
    constexpr auto rounding_threshold = fixed_unit / 2;
    const auto integral = value / fixed_unit;
    const auto fraction = value % fixed_unit;
    const auto rounded = integral + (fraction >= rounding_threshold ? 1 : 0) - (fraction <= -rounding_threshold ? 1 : 0);
    if (rounded < std::numeric_limits<std::int32_t>::min() || rounded > std::numeric_limits<std::int32_t>::max()) {
      throw std::out_of_range{"FontMetricOutOfRange"};
    }

    return static_cast<std::int32_t>(rounded);
  }

  std::uint16_t FontGrid::pixelHeight(const FontConfiguration& font, float scale) {
    if (!std::isfinite(scale) || scale <= 0 || scale > Viewport::maximum_scale) {
      throw std::invalid_argument{"InvalidDisplayScale"};
    }

    const auto height = std::round(font.size * scale);
    if (!std::isfinite(height) || height < 1 || height > std::numeric_limits<std::uint16_t>::max()) {
      throw std::invalid_argument{"InvalidPixelHeight"};
    }

    return static_cast<std::uint16_t>(height);
  }

  FontGrid FontGrid::resolve(const FontMetrics& metrics, const FontConfiguration& font, float scale) {
    const auto pixels = pixelHeight(font, scale);
    const auto natural_height = static_cast<float>(metrics.line_height);
    const auto height = std::round(natural_height * font.line_height);
    const auto spacing = font.letter_spacing * scale;
    const auto width = std::round(static_cast<float>(metrics.maximum_advance) + spacing);
    constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();
    if (!std::isfinite(width) || !std::isfinite(height) || width < 1 || height < 1 || width > maximum_extent || height > maximum_extent) {
      throw std::invalid_argument{"InvalidFontSpacing"};
    }

    const auto leading = (height - natural_height) / 2;

    return {.width = static_cast<std::uint16_t>(width), .height = static_cast<std::uint16_t>(height), .pixel_height = pixels, .baseline = static_cast<float>(metrics.ascender) + leading, .box_stroke = metrics.box_stroke};
  }

  template CopyGrid copyGrid<Memory>(const Screen<Memory>& screen) noexcept;
  template CopyGrid copyGrid<ConcurrentMemory>(const Screen<ConcurrentMemory>& screen) noexcept;
  template WheelRoute wheelRoute<Memory>(const Screen<Memory>& screen) noexcept;
  template WheelRoute wheelRoute<ConcurrentMemory>(const Screen<ConcurrentMemory>& screen) noexcept;

}

namespace telar::gui::glyphs {

  bool AlphaRaster::empty() const noexcept {
    return width == 0 || height == 0;
  }

  void AlphaRaster::validate() const {
    if (empty()) {
      return;
    }

    if (width > stride || pixels.size() < width || static_cast<std::size_t>(height) - 1 > (pixels.size() - width) / stride) {
      throw std::invalid_argument{"InvalidGlyphRaster"};
    }
  }

}
