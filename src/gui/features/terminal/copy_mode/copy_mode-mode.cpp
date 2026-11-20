module telar.gui.features.terminal.copy_mode;

import std;
import telar.tbc;
import telar.gui.foundation.actions;
import telar.gui.foundation.keys;
import telar.gui.foundation.terminal;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::copy_mode {

  CopySearch::CopySearch(Memory& memory)
      : query(memory) {}

  CopyEffect CopyNavigation::apply(CopyState& state, const TerminalKey& key, const CopyGrid& grid, std::span<const PaneMatch> matches) noexcept {
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

  CopyNavigation::Command CopyNavigation::command(const TerminalKey& key) noexcept {
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

  CopyNavigation::Command CopyNavigation::characterCommand(const TerminalKey& key) noexcept {
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

    using CharacterCommand = std::pair<std::uint32_t, Command>;
    constexpr auto characters = ds::Array<CharacterCommand, 24>{
        CharacterCommand{'h', Command::left},
        CharacterCommand{'j', Command::down},
        CharacterCommand{'k', Command::up},
        CharacterCommand{'l', Command::right},
        CharacterCommand{'0', Command::first_column},
        CharacterCommand{'^', Command::first_nonblank},
        CharacterCommand{'$', Command::last_nonblank},
        CharacterCommand{'w', Command::word_forward},
        CharacterCommand{'e', Command::word_end},
        CharacterCommand{'b', Command::word_backward},
        CharacterCommand{'{', Command::paragraph_backward},
        CharacterCommand{'}', Command::paragraph_forward},
        CharacterCommand{'g', Command::top},
        CharacterCommand{'G', Command::bottom},
        CharacterCommand{'/', Command::search_forward},
        CharacterCommand{'?', Command::search_backward},
        CharacterCommand{'n', Command::match_next},
        CharacterCommand{'N', Command::match_previous},
        CharacterCommand{'o', Command::open_link},
        CharacterCommand{'v', Command::select},
        CharacterCommand{' ', Command::select},
        CharacterCommand{'V', Command::select_lines},
        CharacterCommand{'y', Command::copy},
        CharacterCommand{'q', Command::leave},
    };

    const auto* const found = std::ranges::find(characters, key.codepoint, &decltype(characters)::value_type::first);

    return found == characters.end() ? Command::none : found->second;
  }

  bool CopyNavigation::move(CopyState& state, Command action, const CopyGrid& grid) noexcept {
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

  void CopyNavigation::nonBlank(CopyState& state, const CopyGrid& grid, bool last) noexcept {
    const auto last_column = static_cast<std::uint16_t>(grid.columns == 0 ? 0 : grid.columns - 1);

    if (grid.cell({.x = 0, .y = state.cursor.y}) == nullptr) {
      state.cursor.x = last ? last_column : 0;

      return;
    }

    auto column = last ? last_column : std::uint16_t{0};

    while (true) {
      const auto* value = grid.cell({.x = column, .y = state.cursor.y});
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

  CopyPoint CopyNavigation::firstAfterClass(CopyPoint point, CopyWordClass category, const CopyGrid& grid) noexcept {
    while (grid.wordClass(point) == category) {
      const auto next = grid.step(point, CopyDirection::forward);
      if (next == point) {
        break;
      }

      point = next;
    }

    return point;
  }

  CopyPoint CopyNavigation::lastInClass(CopyPoint point, CopyWordClass category, const CopyGrid& grid, CopyDirection direction) noexcept {
    while (true) {
      const auto next = grid.step(point, direction);
      if (next == point || grid.wordClass(next) != category) {
        return point;
      }

      point = next;
    }
  }

  void CopyNavigation::wordForward(CopyState& state, const CopyGrid& grid, bool end) noexcept {
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
        point = lastInClass(point, grid.wordClass(point).valueOr(CopyWordClass::space), grid, CopyDirection::forward);
      }
    }

    state.cursor = point;
    state.reveal(grid);
  }

  void CopyNavigation::wordBackward(CopyState& state, const CopyGrid& grid) noexcept {
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

  void CopyNavigation::paragraph(CopyState& state, const CopyGrid& grid, CopyDirection direction) noexcept {
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

  void CopyNavigation::cycleMatch(CopyState& state, std::span<const PaneMatch> matches, const CopyGrid& grid, bool forward) noexcept {
    if (matches.empty()) {
      return;
    }

    const auto index = (state.match_index + matches.size() + (forward ? std::size_t{1} : matches.size() - 1)) % matches.size();

    state.gotoMatch(static_cast<std::uint16_t>(index), matches, grid);
  }

  const ds::Option<CopyState>& CopyMode::state() const noexcept {
    return state_;
  }

  bool CopyMode::active() const noexcept {
    return state_ && !state_->pointer;
  }

  std::uint64_t CopyMode::revision() const noexcept {
    return revision_;
  }

  ds::Option<CopyPointerOwner> CopyMode::pointerOwner() const noexcept {
    if (gesture_) {
      return CopyPointerOwner{.pane_id = *gesture_, .dragging = true};
    }

    if (state_ && state_->pointer) {
      return CopyPointerOwner{.pane_id = state_->pane_id};
    }

    return {};
  }

  bool CopyMode::beginPointer(CopyPress press, const CopyGrid& grid) noexcept {
    if (active() || press.position.x >= grid.columns || press.position.y >= grid.rows) {
      return false;
    }

    if (click_pane_ != press.pane_id) {
      clicks_ = {};
    }

    click_pane_ = press.pane_id;
    const auto granularity = clicks_.press(press.position, press.now_ns);

    state_ = CopyState{.pane_id = press.pane_id, .cursor = {.x = press.position.x, .y = grid.scroll.offset + press.position.y}, .entry_offset = grid.scroll.offset, .viewport_offset = grid.scroll.offset};
    state_.getMut().beginPointer(granularity, grid);
    gesture_ = press.pane_id;
    match_count_ = 0;
    ++revision_;

    return true;
  }

  tbc::val_static<ds::Option<CopyPlan>> CopyMode::pointer(CopyPoint local, const CopyGrid& grid, bool released) const noexcept {
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

    return next == *state_ && !released ? ds::none : ds::Option{result};
  }

  bool CopyMode::clearPointer() noexcept {
    if (!state_ || !state_->pointer) {
      return false;
    }

    reset();

    return true;
  }

  void CopyMode::finishPointer() noexcept {
    gesture_.reset();
  }

  std::span<const PaneMatch> CopyMode::matches() const noexcept {
    return std::span{matches_}.first(match_count_);
  }

  bool CopyMode::enter(std::uint64_t pane_id, const CopyGrid& grid, const Cursor& cursor) noexcept {
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

  bool CopyMode::enterAt(std::uint64_t pane_id, const CopyGrid& grid, CopyPoint cursor, ds::Option<CopyPoint> anchor, bool linewise) noexcept {
    if (active() || grid.columns == 0 || grid.rows == 0) {
      return false;
    }

    state_ = CopyState{.pane_id = pane_id, .cursor = cursor, .anchor = anchor, .linewise = linewise, .entry_offset = grid.scroll.offset, .viewport_offset = grid.scroll.offset};
    match_count_ = 0;
    ++revision_;

    return true;
  }

  tbc::val_static<ds::Option<CopyPlan>> CopyMode::key(const TerminalKey& key, const CopyGrid& grid) const noexcept {
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
          const auto& match = found[next.match_index];

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

  tbc::val_static<ds::Option<CopyPlan>> CopyMode::vertical(std::int32_t rows, const CopyGrid& grid) const noexcept {
    if (!state_) {
      return {};
    }

    auto next = *state_;

    next.vertical(rows, grid);

    return next == *state_ ? ds::none : ds::Option{plan(next, grid)};
  }

  tbc::val_static<CopyPlan> CopyMode::leave(const CopyGrid& grid) const noexcept {
    CopyPlan result{.revision = revision_, .effect = {.exit = true}};

    if (state_ && !state_->pointer) {
      result.viewport = viewport(std::min(state_->entry_offset, grid.maximumOffset()), grid);
    }

    return result;
  }

  bool CopyMode::current(const CopyPlan& plan) const noexcept {
    return state_.hasValue() && plan.revision == revision_;
  }

  bool CopyMode::commit(const CopyPlan& plan) noexcept {
    if (!current(plan) || (plan.replacement_matches && plan.replacement_matches->size() > matches_.size())) {
      return false;
    }

    state_ = plan.next;
    if (plan.replacement_matches) {
      std::ranges::copy(*plan.replacement_matches, matches_.viewMut().begin());
      match_count_ = plan.replacement_matches->size();
    }

    ++revision_;

    return true;
  }

  tbc::val_a<ds::Option<CopyPlan>> CopyMode::search(tbc::val_a<std::span<const PaneMatch>> results, const CopyGrid& grid, ds::Option<CopyPoint> origin) const {
    if (!state_ || state_->pointer) {
      return {};
    }

    if (results.size() > matches_.size()) {
      throw std::length_error{"Copy search exceeds match capacity"};
    }

    for (const auto& match : results) {
      static_cast<void>(BoundedInteger<u16, 1>::validate(match.len));
    }

    auto next = *state_;

    if (origin) {
      next.cursor = *origin;
      next.reveal(grid);
    }

    next.applyMatches(results, grid, origin.hasValue());
    auto result = plan(next, grid);

    result.replacement_matches = results;

    return result;
  }

  void CopyMode::onFrame(std::uint32_t previous_offset, const CopyGrid& grid) noexcept {
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

  void CopyMode::reset() noexcept {
    state_.reset();
    match_count_ = 0;
    ++revision_;
  }

  ds::Option<SetPaneViewport> CopyMode::viewport(std::uint32_t offset, const CopyGrid& grid) const noexcept {
    if (!state_ || offset == grid.scroll.offset) {
      return {};
    }

    return SetPaneViewport{.pane_id = state_->pane_id, .offset = offset};
  }

  tbc::val_static<CopyPlan> CopyMode::plan(CopyState next, const CopyGrid& grid, CopyEffect effect) const noexcept {
    return {.revision = revision_, .next = next, .effect = effect, .viewport = viewport(next.viewport_offset, grid)};
  }

}
