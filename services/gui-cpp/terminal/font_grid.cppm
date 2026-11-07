module;
#include <compare>
#include <tuple>
#include <utility>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <cstring>
#include <exception>
#include <type_traits>
#include <cstdio>
#include <variant>
#include <bit>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

#include <concepts>
#include <limits>
#include <string_view>

#include <chrono>
#include <cmath>
#include <stdexcept>

export module telar.gui.terminal.font_grid;

export import telar.gui.core.metrics;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;

// Interface: terminal/copy_grid.cppm
export {
namespace telar::gui {

using CopyPoint = CellPosition;

enum class CopyDirection : std::uint8_t {
  forward,
  backward,
};
enum class CopyGranularity : std::uint8_t {
  character,
  word,
  line,
};
enum class CopyWordClass : std::uint8_t {
  space,
  word,
  punctuation,
};

struct CopyGrid {
  std::span<const CellValue> cells;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;
  Scroll scroll;

  [[nodiscard]] inline std::uint32_t maximumOffset() const noexcept {
    return scroll.total_rows - std::min<std::uint32_t>(scroll.total_rows, rows);
  }

  [[nodiscard]] inline std::uint32_t lastRow() const noexcept {
    return scroll.total_rows == 0 ? 0 : scroll.total_rows - 1;
  }

  [[nodiscard]] inline const CellValue *cell(CopyPoint point) const noexcept {
    if (point.x >= columns || point.y < scroll.offset || point.y - scroll.offset >= rows) {
      return nullptr;
    }

    const auto index = (static_cast<std::size_t>(point.y - scroll.offset) * columns) + point.x;

    return index < cells.size() ? &cells[index] : nullptr;
  }

  [[nodiscard]] inline static bool whitespace(char byte) noexcept {
    return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\x0b' || byte == '\x0c';
  }

  [[nodiscard]] inline std::optional<CopyWordClass> wordClass(CopyPoint point) const noexcept {
    const auto *value = cell(point);
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

  [[nodiscard]] inline CopyPoint step(CopyPoint point, CopyDirection direction) const noexcept {
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

  [[nodiscard]] inline bool blankRow(std::uint32_t absolute_row) const noexcept {
    for (std::uint16_t column = 0; column < columns; ++column) {
      const auto *value = cell({.x = column, .y = absolute_row});
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

  [[nodiscard]] inline std::array<CopyPoint, 2> pointerSpan(CopyPoint point, CopyGranularity granularity) const noexcept {
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

    const auto *first_cell = cell(first);
    const auto *last_cell = cell(last);
    if (first_cell != nullptr && first_cell->width == CellWidth::continuation && first.x != 0) {
      --first.x;
    }

    if (last_cell != nullptr && last_cell->width == CellWidth::wide && static_cast<unsigned>(last.x) + 1 < columns) {
      ++last.x;
    }

    return {first, last};
  }

private:
  [[nodiscard]] inline bool pointerWord(CopyPoint point) const noexcept {
    const auto *value = cell(point);
    if (value == nullptr) {
      return false;
    }

    const auto text = value->utf8();

    return value->width == CellWidth::continuation || (!text.empty() && text.front() != ' ');
  }
};

template <Allocator Memory>
CopyGrid copyGrid(const Screen<Memory> &screen) noexcept {
  return {screen.cells(), screen.columns(), screen.rows(), screen.scroll()};
}

}
}

// Interface: terminal/copy_range.cppm
export {
namespace telar::gui {

class CopyRangeParser {
public:
  inline static CopySelection parse(std::uint64_t pane_id, std::string_view text) {
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

private:
  template <std::unsigned_integral Coordinate>
  inline static Coordinate takeCoordinate(std::string_view &text, char separator) {
    const auto boundary = text.find(separator);
    if (boundary == std::string_view::npos) {
      throw EncodingError{"Invalid copy range separators"};
    }

    const auto result = coordinate<Coordinate>(text.substr(0, boundary));
    text.remove_prefix(boundary + 1);

    return result;
  }

  template <std::unsigned_integral Coordinate>
  inline static Coordinate coordinate(std::string_view text) {
    if (text.empty() || text.front() == '_' || text.back() == '_') {
      throw EncodingError{"Invalid copy range coordinate"};
    }

    constexpr std::uint64_t decimal_base = 10;
    constexpr std::uint64_t maximum = std::numeric_limits<Coordinate>::max();
    std::uint64_t result = 0;

    for (const char character : text) {
      if (character == '_') {
        continue;
      }

      if (character < '0' || character > '9') {
        throw EncodingError{"Invalid copy range digit"};
      }

      const auto digit = static_cast<std::uint64_t>(character - '0');
      if (result > (maximum - digit) / decimal_base) {
        throw EncodingError{"Copy range coordinate exceeds capacity"};
      }

      result = (result * decimal_base) + digit;
    }

    return static_cast<Coordinate>(result);
  }
};

}
}

// Interface: terminal/font_grid.cppm
export {
namespace telar::gui {

struct FontMetrics {
  std::int32_t ascender = 0;
  std::uint32_t line_height = 1;
  std::uint16_t maximum_advance = 1;
  float box_stroke = 1;

  [[nodiscard]] inline static std::int32_t roundFixed(std::int64_t value) {
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
};

struct FontGrid {
  std::uint16_t width = 1;
  std::uint16_t height = 1;
  std::uint16_t pixel_height = 1;
  float baseline = 0;
  float box_stroke = 1;

  [[nodiscard]] inline static std::uint16_t pixelHeight(const FontConfiguration &font, float scale) {
    if (!std::isfinite(scale) || scale <= 0 || scale > Viewport::maximum_scale) {
      throw std::invalid_argument{"InvalidDisplayScale"};
    }

    const auto height = std::round(font.size * scale);
    if (!std::isfinite(height) || height < 1 || height > std::numeric_limits<std::uint16_t>::max()) {
      throw std::invalid_argument{"InvalidPixelHeight"};
    }

    return static_cast<std::uint16_t>(height);
  }

  [[nodiscard]] inline static FontGrid resolve(const FontMetrics &metrics, const FontConfiguration &font, float scale) {
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
};

}
}

// Interface: terminal/glyphs/alpha_raster.cppm
export {
namespace telar::gui::glyphs {

struct AlphaRaster {
  std::span<std::uint8_t> pixels;
  std::size_t stride = 0;
  std::uint16_t width = 0;
  std::uint16_t height = 0;

  [[nodiscard]] inline bool empty() const noexcept {
    return width == 0 || height == 0;
  }

  inline void validate() const {
    if (empty()) {
      return;
    }

    if (width > stride || pixels.size() < width || static_cast<std::size_t>(height) - 1 > (pixels.size() - width) / stride) {
      throw std::invalid_argument{"InvalidGlyphRaster"};
    }
  }
};

}
}
