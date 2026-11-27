module telar.gui.foundation.terminal;

import std;

import telar.base.memory.allocators;
import telar.base.text;
import telar.wire.clipboard;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::inline foundation::inline terminal {

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

  ds::Option<CopyWordClass> CopyGrid::wordClass(CopyPoint point) const noexcept {
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

  ds::Array<CopyPoint, 2> CopyGrid::pointerSpan(CopyPoint point, CopyGranularity granularity) const noexcept {
    // Words are read from the screen's cells: on a row it does not hold, a word is its cell.
    if (granularity == CopyGranularity::word && cell(point) == nullptr) {
      granularity = CopyGranularity::character;
    }

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

  template CopyGrid copyGrid<Memory>(const Screen<Memory>& screen) noexcept;
  template CopyGrid copyGrid<ConcurrentMemory>(const Screen<ConcurrentMemory>& screen) noexcept;
  template WheelRoute wheelRoute<Memory>(const Screen<Memory>& screen) noexcept;
  template WheelRoute wheelRoute<ConcurrentMemory>(const Screen<ConcurrentMemory>& screen) noexcept;

}
