#pragma once

#include "copy_grid.hpp"
#include "copy_state.hpp"
#include "input/binding.hpp"
#include "input/terminal_key.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <utility>

namespace telar::gui {

struct CopyEffect {
  bool handled = true;
  bool exit = false;
  bool copy = false;
  std::optional<CopyDirection> search = std::nullopt;
  bool open_link = false;
};

class CopyNavigation {
public:
  static CopyEffect apply(CopyState &state, const TerminalKey &key, const CopyGrid &grid, std::span<const PaneMatch> matches) noexcept {
    const auto action = command(key);
    if (move(state, action, grid)) {
      return {};
    }

    switch (action) {
    case Command::cancel:
      return {.exit = !state.clearSelection()};
    case Command::copy:
      return {.exit = true, .copy = true};
    case Command::leave:
      return {.exit = true};
    case Command::select:
    case Command::select_lines:
      state.toggleSelection(action == Command::select_lines);
      break;
    case Command::search_forward:
    case Command::search_backward:
      state.search_direction = action == Command::search_forward ? CopyDirection::forward : CopyDirection::backward;

      return {.search = state.search_direction};
    case Command::match_next:
    case Command::match_previous:
      cycleMatch(state, matches, grid, (action == Command::match_next) == (state.search_direction == CopyDirection::forward));
      break;
    case Command::open_link:
      return {.open_link = true};
    default:
      return {.handled = false};
    }

    return {};
  }

private:
  enum class Command : std::uint8_t {
    none,
    left,
    right,
    up,
    down,
    first_column,
    first_nonblank,
    last_nonblank,
    word_forward,
    word_end,
    word_backward,
    paragraph_forward,
    paragraph_backward,
    top,
    bottom,
    page_up,
    page_down,
    half_page_up,
    half_page_down,
    cancel,
    copy,
    leave,
    select,
    select_lines,
    search_forward,
    search_backward,
    match_next,
    match_previous,
    open_link,
  };

  static Command command(const TerminalKey &key) noexcept {
    using Code = KeyChord::Key;
    switch (key.code) {
    case Code::left:
      return Command::left;
    case Code::right:
      return Command::right;
    case Code::up:
      return Command::up;
    case Code::down:
      return Command::down;
    case Code::home:
      return Command::first_column;
    case Code::end:
      return Command::last_nonblank;
    case Code::page_up:
      return Command::page_up;
    case Code::page_down:
      return Command::page_down;
    case Code::escape:
      return Command::cancel;
    case Code::enter:
      return Command::copy;
    case Code::character:
      return characterCommand(key);
    default:
      return Command::none;
    }
  }

  static Command characterCommand(const TerminalKey &key) noexcept {
    if (key.has(KeyChord::Modifier::control)) {
      switch (key.codepoint) {
      case 'b':
        return Command::page_up;
      case 'f':
        return Command::page_down;
      case 'u':
        return Command::half_page_up;
      case 'd':
        return Command::half_page_down;
      default:
        return Command::none;
      }
    }

    constexpr auto characters = std::to_array<std::pair<std::uint32_t, Command>>({
        {'h', Command::left},
        {'j', Command::down},
        {'k', Command::up},
        {'l', Command::right},
        {'0', Command::first_column},
        {'^', Command::first_nonblank},
        {'$', Command::last_nonblank},
        {'w', Command::word_forward},
        {'e', Command::word_end},
        {'b', Command::word_backward},
        {'{', Command::paragraph_backward},
        {'}', Command::paragraph_forward},
        {'g', Command::top},
        {'G', Command::bottom},
        {'/', Command::search_forward},
        {'?', Command::search_backward},
        {'n', Command::match_next},
        {'N', Command::match_previous},
        {'o', Command::open_link},
        {'v', Command::select},
        {' ', Command::select},
        {'V', Command::select_lines},
        {'y', Command::copy},
        {'q', Command::leave},
    });
    const auto *const found = std::ranges::find(characters, key.codepoint, &decltype(characters)::value_type::first);

    return found == characters.end() ? Command::none : found->second;
  }

  static bool move(CopyState &state, Command action, const CopyGrid &grid) noexcept {
    const auto page = static_cast<std::int32_t>(std::max<unsigned>(1, grid.rows == 0 ? 0 : grid.rows - 1));
    switch (action) {
    case Command::left:
      state.horizontal(grid, -1);
      break;
    case Command::right:
      state.horizontal(grid, 1);
      break;
    case Command::up:
      state.vertical(-1, grid);
      break;
    case Command::down:
      state.vertical(1, grid);
      break;
    case Command::page_up:
      state.vertical(-page, grid);
      break;
    case Command::page_down:
      state.vertical(page, grid);
      break;
    case Command::half_page_up:
      state.vertical(-(page / 2), grid);
      break;
    case Command::half_page_down:
      state.vertical(page / 2, grid);
      break;
    case Command::first_column:
      state.cursor.x = 0;
      break;
    case Command::first_nonblank:
      nonBlank(state, grid, false);
      break;
    case Command::last_nonblank:
      nonBlank(state, grid, true);
      break;
    case Command::word_forward:
      wordForward(state, grid, false);
      break;
    case Command::word_end:
      wordForward(state, grid, true);
      break;
    case Command::word_backward:
      wordBackward(state, grid);
      break;
    case Command::paragraph_forward:
      paragraph(state, grid, CopyDirection::forward);
      break;
    case Command::paragraph_backward:
      paragraph(state, grid, CopyDirection::backward);
      break;
    case Command::top:
      state.cursor.y = state.viewport_offset = 0;
      break;
    case Command::bottom:
      state.cursor.y = grid.lastRow();
      state.viewport_offset = grid.maximumOffset();
      break;
    default:
      return false;
    }

    return true;
  }

  static void nonBlank(CopyState &state, const CopyGrid &grid, bool last) noexcept {
    const auto last_column = static_cast<std::uint16_t>(grid.columns == 0 ? 0 : grid.columns - 1);
    if (grid.cell({.x = 0, .y = state.cursor.y}) == nullptr) {
      state.cursor.x = last ? last_column : 0;

      return;
    }

    auto column = last ? last_column : std::uint16_t{0};
    while (true) {
      const auto *value = grid.cell({.x = column, .y = state.cursor.y});
      if (value != nullptr && !value->utf8().empty() && !CopyGrid::whitespace(value->utf8().front())) {
        break;
      }

      if ((last && column == 0) || (!last && column == last_column)) {
        break;
      }

      column = static_cast<std::uint16_t>(last ? column - 1 : column + 1);
    }

    state.cursor.x = column;
  }

  static CopyPoint firstAfterClass(CopyPoint point, CopyWordClass category, const CopyGrid &grid) noexcept {
    while (grid.wordClass(point) == category) {
      const auto next = grid.step(point, CopyDirection::forward);
      if (next == point) {
        break;
      }

      point = next;
    }

    return point;
  }

  static CopyPoint lastInClass(CopyPoint point, CopyWordClass category, const CopyGrid &grid, CopyDirection direction) noexcept {
    while (true) {
      const auto next = grid.step(point, direction);
      if (next == point || grid.wordClass(next) != category) {
        return point;
      }

      point = next;
    }
  }

  static void wordForward(CopyState &state, const CopyGrid &grid, bool end) noexcept {
    const auto initial = grid.wordClass(state.cursor);
    if (!initial) {
      state.vertical(1, grid);
      state.cursor.x = 0;

      return;
    }

    auto point = state.cursor;
    if (end && *initial != CopyWordClass::space) {
      point = lastInClass(point, *initial, grid, CopyDirection::forward);
    } else {
      point = firstAfterClass(point, *initial, grid);
      point = firstAfterClass(point, CopyWordClass::space, grid);
      if (end) {
        point = lastInClass(point, grid.wordClass(point).value_or(CopyWordClass::space), grid, CopyDirection::forward);
      }
    }

    state.cursor = point;
    state.reveal(grid);
  }

  static void wordBackward(CopyState &state, const CopyGrid &grid) noexcept {
    auto point = grid.step(state.cursor, CopyDirection::backward);
    while (grid.wordClass(point) == CopyWordClass::space) {
      const auto previous = grid.step(point, CopyDirection::backward);
      if (previous == point) {
        break;
      }

      point = previous;
    }

    const auto category = grid.wordClass(point);
    if (!category) {
      state.vertical(-1, grid);
      state.cursor.x = 0;

      return;
    }

    state.cursor = lastInClass(point, *category, grid, CopyDirection::backward);
    state.reveal(grid);
  }

  static void paragraph(CopyState &state, const CopyGrid &grid, CopyDirection direction) noexcept {
    auto row = state.cursor.y;
    while (true) {
      const auto next = direction == CopyDirection::backward ? row - std::min<std::uint32_t>(row, 1) : row + static_cast<std::uint32_t>(row < grid.lastRow());
      if (next == row) {
        break;
      }

      row = next;
      if (grid.cell({.x = 0, .y = row}) == nullptr || grid.blankRow(row)) {
        break;
      }
    }

    state.cursor = {.x = 0, .y = row};
    state.reveal(grid);
  }

  static void cycleMatch(CopyState &state, std::span<const PaneMatch> matches, const CopyGrid &grid, bool forward) noexcept {
    if (matches.empty()) {
      return;
    }

    const auto index = (state.match_index + matches.size() + (forward ? std::size_t{1} : matches.size() - 1)) % matches.size();
    state.gotoMatch(static_cast<std::uint16_t>(index), matches, grid);
  }
};

}
