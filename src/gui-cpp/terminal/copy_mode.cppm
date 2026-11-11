module;
#include "tbc/view.hpp"
#include <cstdlib>
#include <new>
#include <cstring>
#include <cstdio>

#include <cstddef>

#include <cstdint>




#include <cmath>



export module telar.gui.terminal.copy_mode;

import std;

export import telar.gui.terminal.font_grid;


export import telar.gui.input.key_encoder;


export import telar.gui.input.copy_pointer;


export import telar.gui.core.unicode_scalar;


export import telar.gui.core.metrics;
export import telar.gui.fonts.face;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;

// Interface: terminal/selection.cppm
export {
namespace telar::gui {

struct CellSelection {
  int anchor = -1;
  int head = -1;

  bool operator==(const CellSelection &) const = default;

  [[nodiscard]] inline CellSelection within(std::size_t first, std::size_t count) const noexcept {
    if (anchor < 0 || head < 0 || count == 0) {
      return {};
    }

    const auto beginning = static_cast<std::size_t>(std::min(anchor, head));
    const auto ending = static_cast<std::size_t>(std::max(anchor, head));
    const auto last = first + count - 1;
    if (ending < first || beginning > last) {
      return {};
    }

    return {.anchor = static_cast<int>(std::max(first, beginning)), .head = static_cast<int>(std::min(last, ending))};
  }

  [[nodiscard]] inline bool contains(std::size_t cell) const noexcept {
    return anchor >= 0 && head >= 0 && std::cmp_greater_equal(cell, std::min(anchor, head)) && std::cmp_less_equal(cell, std::max(anchor, head));
  }
};

}
}

// Interface: terminal/copy_state.cppm
export {
namespace telar::gui {

struct CopyPointer {
  CopyPoint start;
  CopyPoint end;
  CopyGranularity granularity = CopyGranularity::character;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;

  bool operator==(const CopyPointer &) const = default;
};

struct CopyState {
  std::uint64_t pane_id = 0;
  CopyPoint cursor;
  std::optional<CopyPointer> pointer = std::nullopt;
  std::optional<CopyPoint> anchor = std::nullopt;
  bool linewise = false;
  std::uint32_t entry_offset = 0;
  std::uint32_t viewport_offset = 0;
  CopyDirection search_direction = CopyDirection::forward;
  std::uint16_t match_index = 0;

  bool operator==(const CopyState &) const = default;

  [[nodiscard]] inline std::optional<CopySelection> selectionRequest() const noexcept {
    if (!anchor) {
      return {};
    }

    return CopySelection{.pane_id = pane_id, .start_x = anchor->x, .start_y = anchor->y, .end_x = cursor.x, .end_y = cursor.y, .linewise = linewise};
  }

  inline void horizontal(const CopyGrid &grid, std::int32_t delta) noexcept {
    const auto columns = grid.columns;
    const auto last = columns == 0 ? 0 : columns - 1;
    cursor.x = static_cast<std::uint16_t>(std::clamp<std::int64_t>(static_cast<std::int64_t>(cursor.x) + delta, 0, last));
  }

  inline void vertical(std::int32_t delta, const CopyGrid &grid) noexcept {
    cursor.y = static_cast<std::uint32_t>(std::clamp<std::int64_t>(static_cast<std::int64_t>(cursor.y) + delta, 0, grid.lastRow()));
    reveal(grid);
  }

  inline void reveal(const CopyGrid &grid) noexcept {
    if (cursor.y < viewport_offset) {
      viewport_offset = cursor.y;
    } else if (static_cast<std::uint64_t>(cursor.y) >= static_cast<std::uint64_t>(viewport_offset) + grid.rows) {
      viewport_offset = cursor.y - std::min<std::uint32_t>(cursor.y, grid.rows == 0 ? 0 : grid.rows - 1);
    }

    viewport_offset = std::min(viewport_offset, grid.maximumOffset());
  }

  inline void toggleSelection(bool whole_lines) noexcept {
    if (anchor && linewise == whole_lines) {
      static_cast<void>(clearSelection());

      return;
    }

    anchor = cursor;
    linewise = whole_lines;
  }

  inline bool clearSelection() noexcept {
    if (!anchor) {
      return false;
    }

    anchor.reset();
    linewise = false;

    return true;
  }

  inline void beginPointer(CopyGranularity granularity, const CopyGrid &grid) noexcept {
    const auto span = grid.pointerSpan(cursor, granularity);
    pointer = CopyPointer{.start = span[0], .end = span[1], .granularity = granularity, .columns = grid.columns, .rows = grid.rows};
    anchor = granularity == CopyGranularity::character ? std::nullopt : std::optional{span[0]};
    cursor = span[1];
    linewise = granularity == CopyGranularity::line;
  }

  inline void movePointer(CopyPoint point, const CopyGrid &grid) noexcept {
    if (!pointer || grid.columns == 0 || grid.rows == 0) {
      return;
    }

    point.x = std::min<std::uint16_t>(point.x, grid.columns - 1);
    point.y = std::clamp(point.y, grid.scroll.offset, grid.scroll.offset + grid.rows - 1);
    const auto span = grid.pointerSpan(point, pointer->granularity);
    const auto backwards = point < pointer->start;
    anchor = backwards ? pointer->end : pointer->start;
    cursor = backwards ? span[0] : span[1];
    if (pointer->granularity == CopyGranularity::character && span[0] == pointer->start && span[1] == pointer->end) {
      anchor.reset();
    }
  }

  inline void onFrame(std::uint32_t previous_offset, Scroll scroll) noexcept {
    if (scroll.offset < previous_offset && viewport_offset == previous_offset) {
      const auto pruned = previous_offset - scroll.offset;
      cursor.y -= std::min(cursor.y, pruned);
      if (anchor) {
        anchor->y -= std::min(anchor->y, pruned);
      }

      if (pointer) {
        pointer->start.y -= std::min(pointer->start.y, pruned);
        pointer->end.y -= std::min(pointer->end.y, pruned);
      }
    }

    const auto last = scroll.total_rows == 0 ? 0 : scroll.total_rows - 1;
    cursor.y = std::min(cursor.y, last);
    if (anchor) {
      anchor->y = std::min(anchor->y, last);
    }

    if (pointer) {
      pointer->start.y = std::min(pointer->start.y, last);
      pointer->end.y = std::min(pointer->end.y, last);
    }

    viewport_offset = scroll.offset;
  }

  // To match `index`, the cursor on its first cell as vim's search puts it, a selection under
  // way stretched there and none begun; the view centred on it unless it is well inside.
  inline void gotoMatch(std::uint16_t index, std::span<const PaneMatch> matches, const CopyGrid &grid) noexcept {
    if (index >= matches.size() || matches[index].len == 0) {
      return;
    }

    const auto &match = matches[index];
    match_index = index;
    cursor = {.x = match.x, .y = std::min(match.y, grid.lastRow())};
    revealWithMargin(grid);
  }

  // Shows the cursor clear of the view's edges, where a pinned separator and a docked line
  // cover rows: a row outside the middle of the view, a fifth of it from each edge and at least
  // two rows, comes to the view's middle.
  inline void revealWithMargin(const CopyGrid &grid) noexcept {
    const auto rows = static_cast<std::uint32_t>(grid.rows);
    const auto margin = std::min<std::uint32_t>(std::max<std::uint32_t>(2, rows / 5), rows / 2);
    const auto top = static_cast<std::uint64_t>(viewport_offset) + margin;
    const auto bottom = static_cast<std::uint64_t>(viewport_offset) + rows - margin;
    if (cursor.y < top || cursor.y >= bottom) {
      viewport_offset = cursor.y - std::min<std::uint32_t>(cursor.y, rows / 2);
    }
    viewport_offset = std::min(viewport_offset, grid.maximumOffset());
  }

  // To the first match past the cursor that way, or, `inclusive`, from the cursor's own cell.
  inline void applyMatches(std::span<const PaneMatch> matches, const CopyGrid &grid, bool inclusive = false) noexcept {
    if (matches.empty()) {
      return;
    }

    std::size_t selected = search_direction == CopyDirection::forward ? 0 : matches.size() - 1;
    if (search_direction == CopyDirection::forward) {
      for (std::size_t index = 0; index < matches.size(); ++index) {
        const CopyPoint start{.x = matches[index].x, .y = matches[index].y};
        if (cursor < start || (inclusive && cursor == start)) {
          selected = index;
          break;
        }
      }
    } else {
      for (std::size_t index = matches.size(); index-- > 0;) {
        const CopyPoint start{.x = matches[index].x, .y = matches[index].y};
        if (start < cursor || (inclusive && start == cursor)) {
          selected = index;
          break;
        }
      }
    }

    gotoMatch(static_cast<std::uint16_t>(selected), matches, grid);
  }

  [[nodiscard]] inline CellSelection selection(const CopyGrid &grid) const noexcept {
    if (!anchor || grid.columns == 0 || grid.rows == 0) {
      return {};
    }

    auto first = std::min(*anchor, cursor);
    auto last = std::max(*anchor, cursor);
    const auto viewport_last = static_cast<std::uint64_t>(grid.scroll.offset) + grid.rows - 1;
    if (last.y < grid.scroll.offset || first.y > viewport_last) {
      return {};
    }

    if (linewise || first.y < grid.scroll.offset) {
      first.x = 0;
    }

    if (linewise || last.y > viewport_last) {
      last.x = grid.columns - 1;
    }

    first.y = std::max(first.y, grid.scroll.offset) - grid.scroll.offset;
    last.y = static_cast<std::uint32_t>(std::min<std::uint64_t>(last.y, viewport_last)) - grid.scroll.offset;

    return {.anchor = static_cast<int>((first.y * grid.columns) + first.x), .head = static_cast<int>((last.y * grid.columns) + last.x)};
  }
};

}
}

// Interface: terminal/copy_navigation.cppm
export {
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
  inline static CopyEffect apply(CopyState &state, const TerminalKey &key, const CopyGrid &grid, std::span<const PaneMatch> matches) noexcept {
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

  inline static Command command(const TerminalKey &key) noexcept {
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

  inline static Command characterCommand(const TerminalKey &key) noexcept {
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

  inline static bool move(CopyState &state, Command action, const CopyGrid &grid) noexcept {
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

  inline static void nonBlank(CopyState &state, const CopyGrid &grid, bool last) noexcept {
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

  inline static CopyPoint firstAfterClass(CopyPoint point, CopyWordClass category, const CopyGrid &grid) noexcept {
    while (grid.wordClass(point) == category) {
      const auto next = grid.step(point, CopyDirection::forward);
      if (next == point) {
        break;
      }

      point = next;
    }

    return point;
  }

  inline static CopyPoint lastInClass(CopyPoint point, CopyWordClass category, const CopyGrid &grid, CopyDirection direction) noexcept {
    while (true) {
      const auto next = grid.step(point, direction);
      if (next == point || grid.wordClass(next) != category) {
        return point;
      }

      point = next;
    }
  }

  inline static void wordForward(CopyState &state, const CopyGrid &grid, bool end) noexcept {
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

  inline static void wordBackward(CopyState &state, const CopyGrid &grid) noexcept {
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

  inline static void paragraph(CopyState &state, const CopyGrid &grid, CopyDirection direction) noexcept {
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

  inline static void cycleMatch(CopyState &state, std::span<const PaneMatch> matches, const CopyGrid &grid, bool forward) noexcept {
    if (matches.empty()) {
      return;
    }

    const auto index = (state.match_index + matches.size() + (forward ? std::size_t{1} : matches.size() - 1)) % matches.size();
    state.gotoMatch(static_cast<std::uint16_t>(index), matches, grid);
  }
};

}
}

// Interface: terminal/copy_mode.cppm
export {
namespace telar::gui {

struct CopyPlan {
  std::uint64_t revision = 0;
  std::optional<CopyState> next = std::nullopt;
  CopyEffect effect{};
  std::optional<CopySelection> selection = std::nullopt;
  std::optional<SetPaneViewport> viewport = std::nullopt;
  std::optional<std::span<const PaneMatch>> replacement_matches = std::nullopt;
};

class CopyMode {
public:
  static constexpr std::size_t maximum_matches = 256;

  [[nodiscard]] inline const std::optional<CopyState> &state() const noexcept {
    return state_;
  }

  [[nodiscard]] inline bool active() const noexcept {
    return state_ && !state_->pointer;
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline std::optional<CopyPointerOwner> pointerOwner() const noexcept {
    if (gesture_) {
      return CopyPointerOwner{.pane_id = *gesture_, .dragging = true};
    }

    if (state_ && state_->pointer) {
      return CopyPointerOwner{.pane_id = state_->pane_id};
    }

    return {};
  }

  inline bool beginPointer(CopyPress press, const CopyGrid &grid) noexcept {
    if (active() || press.position.x >= grid.columns || press.position.y >= grid.rows) {
      return false;
    }

    if (click_pane_ != press.pane_id) {
      clicks_ = {};
    }

    click_pane_ = press.pane_id;
    const auto granularity = clicks_.press(press.position, press.now_ns);
    state_ = CopyState{.pane_id = press.pane_id, .cursor = {.x = press.position.x, .y = grid.scroll.offset + press.position.y}, .entry_offset = grid.scroll.offset, .viewport_offset = grid.scroll.offset};
    state_->beginPointer(granularity, grid);
    gesture_ = press.pane_id;
    match_count_ = 0;
    ++revision_;

    return true;
  }

  [[nodiscard]] inline std::optional<CopyPlan> pointer(CopyPoint local, const CopyGrid &grid, bool released) const noexcept {
    if (!state_ || !state_->pointer || gesture_ != state_->pane_id) {
      return {};
    }

    auto next = *state_;
    next.movePointer({.x = local.x, .y = grid.scroll.offset + std::min<std::uint32_t>(local.y, grid.rows == 0 ? 0 : grid.rows - 1)}, grid);
    if (released && !next.anchor) {
      return leave(grid);
    }

    auto result = plan(next, grid);
    if (released) {
      result.selection = next.selectionRequest();
    }

    return next == *state_ && !released ? std::nullopt : std::optional{result};
  }

  inline bool clearPointer() noexcept {
    if (!state_ || !state_->pointer) {
      return false;
    }

    reset();

    return true;
  }

  inline void finishPointer() noexcept {
    gesture_.reset();
  }

  [[nodiscard]] inline std::span<const PaneMatch> matches() const noexcept {
    return std::span{matches_}.first(match_count_);
  }

  inline bool enter(std::uint64_t pane_id, const CopyGrid &grid, const Cursor &cursor) noexcept {
    if (active() || grid.columns == 0 || grid.rows == 0) {
      return false;
    }

    state_ = CopyState{
        .pane_id = pane_id,
        .cursor = cursor.visible ? CopyPoint{.x = cursor.x, .y = grid.scroll.offset + cursor.y} : CopyPoint{.x = 0, .y = grid.scroll.offset + grid.rows - 1},
        .entry_offset = grid.scroll.offset,
        .viewport_offset = grid.scroll.offset,
    };
    match_count_ = 0;
    ++revision_;

    return true;
  }

  // Enters at `cursor`, from the top of the scrollback, already selecting from `anchor` when
  // one is given: a command block's text, picked from telar's editor.
  inline bool enterAt(std::uint64_t pane_id, const CopyGrid &grid, CopyPoint cursor, std::optional<CopyPoint> anchor, bool linewise) noexcept {
    if (active() || grid.columns == 0 || grid.rows == 0) {
      return false;
    }

    state_ = CopyState{.pane_id = pane_id, .cursor = cursor, .anchor = anchor, .linewise = linewise, .entry_offset = grid.scroll.offset, .viewport_offset = grid.scroll.offset};
    match_count_ = 0;
    ++revision_;

    return true;
  }

  [[nodiscard]] inline std::optional<CopyPlan> key(const TerminalKey &key, const CopyGrid &grid) const noexcept {
    if (!state_ || state_->pointer) {
      return {};
    }

    const auto previous = *state_;
    auto next = previous;
    const auto effect = CopyNavigation::apply(next, key, grid, matches());
    if (!effect.handled) {
      return {};
    }

    if (effect.exit) {
      auto plan = leave(grid);
      plan.effect = effect;
      if (effect.copy) {
        plan.selection = next.selectionRequest();
        // Without a selection, the match the cursor stands on is what y copies.
        const auto found = matches();
        if (!plan.selection && next.match_index < found.size() && next.cursor == CopyPoint{.x = found[next.match_index].x, .y = found[next.match_index].y}) {
          const auto &match = found[next.match_index];
          plan.selection = CopySelection{.pane_id = next.pane_id, .start_x = match.x, .start_y = match.y, .end_x = static_cast<std::uint16_t>(static_cast<std::uint32_t>(match.x) + match.len - 1), .end_y = match.y, .linewise = false};
        }
      }

      return plan;
    }

    if (next == previous && !effect.search && !effect.open_link) {
      return {};
    }

    return plan(next, grid, effect);
  }

  [[nodiscard]] inline std::optional<CopyPlan> vertical(std::int32_t rows, const CopyGrid &grid) const noexcept {
    if (!state_) {
      return {};
    }

    auto next = *state_;
    next.vertical(rows, grid);

    return next == *state_ ? std::nullopt : std::optional{plan(next, grid)};
  }

  [[nodiscard]] inline CopyPlan leave(const CopyGrid &grid) const noexcept {
    CopyPlan result{.revision = revision_, .effect = {.exit = true}};
    if (state_ && !state_->pointer) {
      result.viewport = viewport(std::min(state_->entry_offset, grid.maximumOffset()), grid);
    }

    return result;
  }

  [[nodiscard]] inline bool current(const CopyPlan &plan) const noexcept {
    return state_.has_value() && plan.revision == revision_;
  }

  inline bool commit(const CopyPlan &plan) noexcept {
    if (!current(plan) || (plan.replacement_matches && plan.replacement_matches->size() > matches_.size())) {
      return false;
    }

    state_ = plan.next;
    if (plan.replacement_matches) {
      std::ranges::copy(*plan.replacement_matches, matches_.begin());
      match_count_ = plan.replacement_matches->size();
    }

    ++revision_;

    return true;
  }

  // The plan's replacement matches view the results, region `a`, until it is applied. From
  // `origin`, a search typed a letter at a time starts where it began, and comes back there
  // when nothing matches.
  [[nodiscard]] inline tbc::view<std::optional<CopyPlan>, tbc::lt::a> search(tbc::view<std::span<const PaneMatch>, tbc::lt::a> results, const CopyGrid &grid, std::optional<CopyPoint> origin = std::nullopt) const {
    if (!state_ || state_->pointer) {
      return {};
    }

    if (results.size() > matches_.size()) {
      throw std::length_error{"Copy search exceeds match capacity"};
    }

    for (const auto &match : results) {
      static_cast<void>(BoundedInteger<u16, 1>::validate(match.len));
    }

    auto next = *state_;
    if (origin) {
      next.cursor = *origin;
      next.reveal(grid);
    }
    next.applyMatches(results, grid, origin.has_value());
    auto result = plan(next, grid);
    result.replacement_matches = results;

    return result;
  }

  inline void onFrame(std::uint32_t previous_offset, const CopyGrid &grid) noexcept {
    if (!state_) {
      return;
    }

    if (state_->pointer && (state_->pointer->columns != grid.columns || state_->pointer->rows != grid.rows)) {
      reset();

      return;
    }

    auto next = *state_;
    next.onFrame(previous_offset, grid.scroll);
    if (next != *state_) {
      state_ = next;
      ++revision_;
    }
  }

  inline void reset() noexcept {
    state_.reset();
    match_count_ = 0;
    ++revision_;
  }

private:
  [[nodiscard]] inline std::optional<SetPaneViewport> viewport(std::uint32_t offset, const CopyGrid &grid) const noexcept {
    if (!state_ || offset == grid.scroll.offset) {
      return {};
    }

    return SetPaneViewport{.pane_id = state_->pane_id, .offset = offset};
  }

  [[nodiscard]] inline CopyPlan plan(CopyState next, const CopyGrid &grid, CopyEffect effect = {}) const noexcept {
    return {.revision = revision_, .next = next, .effect = effect, .viewport = viewport(next.viewport_offset, grid)};
  }

  std::optional<CopyState> state_;
  std::array<PaneMatch, maximum_matches> matches_{};
  std::size_t match_count_ = 0;
  std::uint64_t revision_ = 0;
  ClickTracker clicks_;
  std::uint64_t click_pane_ = 0;
  std::optional<std::uint64_t> gesture_;
};

}
}

// Interface: terminal/glyphs/box_edges.cppm
export {
namespace telar::gui::glyphs {

enum class BoxWeight : std::uint8_t {
  none,
  light,
  heavy,
  double_line,
};

struct BoxEdges {
  BoxWeight up = BoxWeight::none;
  BoxWeight right = BoxWeight::none;
  BoxWeight down = BoxWeight::none;
  BoxWeight left = BoxWeight::none;

  [[nodiscard]] inline bool empty() const noexcept {
    return up == BoxWeight::none && right == BoxWeight::none && down == BoxWeight::none && left == BoxWeight::none;
  }

  inline void simplifyDoubles() noexcept {
    for (auto *edge : {&up, &right, &down, &left}) {
      if (*edge == BoxWeight::double_line) {
        *edge = BoxWeight::light;
      }
    }
  }
};

}
}

// Interface: terminal/glyphs/box_stroke.cppm
export {
namespace telar::gui::glyphs {

struct BoxStroke {
  std::uint16_t units_per_em = 0;
  std::int16_t underline_thickness = 0;

  [[nodiscard]] inline float pixels(std::uint16_t pixel_height) const noexcept {
    constexpr float fallback_divisor = 16;
    const auto height = static_cast<float>(pixel_height);
    const auto thickness = units_per_em == 0 || underline_thickness <= 0 ? height / fallback_divisor : static_cast<float>(underline_thickness) * height / static_cast<float>(units_per_em);

    return std::max(1.0F, std::ceil(thickness));
  }
};

}
}

// Interface: terminal/glyphs/symbol.cppm
export {
namespace telar::gui::glyphs {

enum class SymbolKind : std::uint8_t {
  box,
  block,
  braille,
};

struct Symbol {
  static constexpr std::uint32_t first_box = 0x2500;
  static constexpr std::uint32_t last_box = 0x257f;
  static constexpr std::uint32_t first_box_curve = 0x256d;
  static constexpr std::uint32_t last_box_curve = 0x2573;
  static constexpr std::uint32_t first_block = 0x2580;
  static constexpr std::uint32_t last_block = 0x259f;
  static constexpr std::uint32_t first_braille = 0x2800;
  static constexpr std::uint32_t last_braille = 0x28ff;

  SymbolKind kind = SymbolKind::box;
  std::uint32_t codepoint = 0;

  [[nodiscard]] inline static std::optional<Symbol> parse(std::string_view text) noexcept {
    constexpr std::uint8_t symbol_prefix = 0xe2;
    constexpr unsigned continuation_prefix_mask = 0xc0;
    constexpr std::size_t symbol_bytes = 3;
    if (text.size() != symbol_bytes || static_cast<std::uint8_t>(text[0]) != symbol_prefix) {
      return {};
    }

    const auto middle = static_cast<std::uint8_t>(text[1]);
    const auto last = static_cast<std::uint8_t>(text[2]);
    if ((middle & continuation_prefix_mask) != Utf8Scalar::continuation_prefix || (last & continuation_prefix_mask) != Utf8Scalar::continuation_prefix) {
      return {};
    }

    const auto codepoint = ((symbol_prefix & Utf8Scalar::leading_masks[symbol_bytes - 1]) << (2 * Utf8Scalar::continuation_bits)) | ((middle & Utf8Scalar::continuation_mask) << Utf8Scalar::continuation_bits) | (last & Utf8Scalar::continuation_mask);
    if (codepoint >= first_box && codepoint <= last_box) {
      return Symbol{.kind = SymbolKind::box, .codepoint = codepoint};
    }

    if (codepoint >= first_block && codepoint <= last_block) {
      return Symbol{.kind = SymbolKind::block, .codepoint = codepoint};
    }

    if (codepoint >= first_braille && codepoint <= last_braille) {
      return Symbol{.kind = SymbolKind::braille, .codepoint = codepoint};
    }

    return {};
  }
};

}
}

// Interface: terminal/text_runs.cppm
export {
namespace telar::gui {

template <typename Coverage>
concept LigatureRoles = requires(const Coverage &coverage, std::string_view text) {
  { coverage.role(text) } -> std::same_as<fonts::LigatureRole>;
};

struct TextRun {
  std::size_t count = 1;
  bool together = false;
};

template <Allocator Memory>
class TextRuns {
public:
  static constexpr std::size_t maximum_cells = 128;
  static constexpr std::size_t maximum_bytes = maximum_cells * CellValue::text_capacity;
  static constexpr std::size_t maximum_glyphs = 2 * maximum_cells;

  inline explicit TextRuns(Memory &memory)
      : columns_(AllocatorRef<Column, Memory>{memory}) {}

  inline void reserve(std::size_t columns) {
    columns_.reserve(columns);
  }

  inline void clear() noexcept {
    columns_.clear();
    inputs_ = 0;
  }

  template <LigatureRoles Coverage>
  inline void append(const Coverage &coverage, const CellValue &cell, bool alone) {
    const auto role = alone || !shapeable(cell) ? fonts::LigatureRole::none : coverage.role(cell.utf8());
    const auto joins = role != fonts::LigatureRole::none && !columns_.empty() && columns_.back().role != fonts::LigatureRole::none && inkStyle(previous_.style) == inkStyle(cell.style) && !typographic(previous_, cell);
    columns_.push_back({.role = role, .joins = joins});
    previous_ = cell;
    inputs_ += static_cast<std::size_t>(role == fonts::LigatureRole::input);
  }

  inline void close(std::uint16_t reach) noexcept {
    if (inputs_ == 0) {
      return;
    }

    const auto limit = reach == 0 || reach > maximum_cells ? maximum_cells : reach;
    auto since = far;
    for (auto &column : columns_) {
      if (!column.joins) {
        since = far;
      }

      since = distanceFromInput(column.role, since);
      column.since = since;
    }

    auto until = far;
    for (auto iterator = columns_.rbegin(); iterator != columns_.rend(); ++iterator) {
      auto &column = *iterator;
      until = distanceFromInput(column.role, until);
      column.kept = column.role != fonts::LigatureRole::none && std::min(column.since, until) < limit;
      if (!column.joins) {
        until = far;
      }
    }
  }

  [[nodiscard]] inline TextRun at(std::size_t start) const noexcept {
    if (!columns_[start].kept) {
      return {};
    }

    auto end = start + 1;
    while (end < columns_.size() && columns_[end].kept && columns_[end].joins) {
      ++end;
    }

    const auto count = end - start;

    return {.count = count, .together = count > 1 && count <= maximum_cells};
  }

private:
  static constexpr auto far = std::numeric_limits<std::uint16_t>::max();

  struct Column {
    fonts::LigatureRole role = fonts::LigatureRole::none;
    bool joins = false;
    bool kept = false;
    std::uint16_t since = far;
  };

  [[nodiscard]] inline static std::uint16_t distanceFromInput(fonts::LigatureRole role, std::uint16_t distance) noexcept {
    if (role == fonts::LigatureRole::input) {
      return 0;
    }

    return distance == far ? far : static_cast<std::uint16_t>(distance + 1);
  }

  [[nodiscard]] inline static bool shapeable(const CellValue &cell) noexcept {
    return cell.width == CellWidth::single && !hasAttribute(cell.style, CellAttribute::invisible) && (cell.length == 1 || !glyphs::Symbol::parse(cell.utf8()));
  }

  [[nodiscard]] inline static CellStyle inkStyle(CellStyle style) noexcept {
    if (hasAttribute(style, CellAttribute::inverse)) {
      style.foreground = {};
    } else {
      style.background = {};
    }

    constexpr unsigned underline_shift = 8;
    constexpr unsigned underline_width = 7;
    constexpr auto decorations = (underline_width << underline_shift) | static_cast<unsigned>(CellAttribute::overline) | static_cast<unsigned>(CellAttribute::strikethrough);
    style.underline_color = {};
    style.flags &= static_cast<std::uint16_t>(~decorations);

    return style;
  }

  [[nodiscard]] inline static bool typographic(const CellValue &previous, const CellValue &next) noexcept {
    if (previous.length != 1 || next.length != 1) {
      return false;
    }

    return (previous.text[0] == 'f' && (next.text[0] == 'i' || next.text[0] == 'l')) || (previous.text[0] == 's' && next.text[0] == 't');
  }

  Vector<Column, Memory> columns_;
  CellValue previous_;
  std::size_t inputs_ = 0;
};

}
}
