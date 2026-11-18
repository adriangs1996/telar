module telar.gui.features.terminal.copy_mode;

import std;

import telar.gui.foundation.terminal;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::copy_mode {

  bool enter(State& state, std::uint64_t pane_id, const CopyGrid& grid, const Cursor& cursor) noexcept {
    const auto entered = Access::mode(state).enter(pane_id, grid, cursor);
    if (entered) {
      Access::search(state).request = 0;
    }

    return entered;
  }

  bool select(State& state, std::uint64_t pane_id, const CopyGrid& grid, CopyPoint cursor, ds::Option<CopyPoint> anchor, bool linewise) noexcept {
    const auto entered = Access::mode(state).enterAt(pane_id, grid, cursor, anchor, linewise);
    if (entered) {
      Access::search(state).request = 0;
    }

    return entered;
  }

  bool searchOutput(State& state, std::uint64_t pane_id, const CopyGrid& grid, CopySearchRows rows, bool scoped) noexcept {
    const CopyPoint first{.x = 0, .y = rows.first};
    if (!Access::mode(state).enterAt(pane_id, grid, first, ds::none, false)) {
      return false;
    }

    auto& search = Access::search(state);

    search.request = 0;
    search.rows = rows;
    search.origin = first;
    search.scoped = scoped;
    search.requested = true;

    return true;
  }

  CopyPlan leave(const State& state, const CopyGrid& grid) noexcept {
    return Access::mode(state).leave(grid);
  }

  void close(State& state) noexcept {
    Access::mode(state).reset();
    Access::search(state).request = 0;
  }

  void forget(State& state) noexcept {
    auto& search = Access::search(state);

    search.request = 0;
    search.rows.reset();
    search.origin.reset();
    search.query.clear();
  }

  ds::Option<CopyPlan> type(State& state, std::string_view needle, const CopyGrid& grid) {
    const auto& mode = Access::mode(state);
    auto& search = Access::search(state);

    // A search typed a letter at a time starts where the first letter found the cursor.
    if (!search.origin) {
      search.origin = mode.state()->cursor;
    }

    search.query.assign(needle);
    if (!needle.empty()) {
      return ds::none;
    }

    // Nothing to look for: no matches, and the cursor back where the search began.
    search.request = 0;
    search.truncated = false;

    return mode.search({}, grid, search.origin);
  }

  std::variant<SearchPane, SearchPaneRows> request(State& state, std::uint64_t pane_id, std::uint64_t request_id, bool reads_rows) noexcept {
    auto& search = Access::search(state);

    search.request = request_id;
    if (search.rows && search.scoped && reads_rows) {
      return SearchPaneRows{.request_id = request_id, .pane_id = pane_id, .needle = search.query, .first_row = search.rows->first, .last_row = search.rows->last};
    }

    return SearchPane{.request_id = request_id, .pane_id = pane_id, .needle = search.query};
  }

  void fail(State& state, std::uint64_t request_id) noexcept {
    auto& search = Access::search(state);

    if (search.request == request_id) {
      search.request = 0;
    }
  }

  bool awaits(const State& state, const PaneMatches& message) noexcept {
    const auto& current = Access::mode(state).state();

    return message.request_id == Access::search(state).request && current && !current->pointer && message.pane_id == current->pane_id;
  }

  ds::Option<CopyPlan> receive(State& state, const PaneMatches& message, const CopyGrid& grid) {
    auto& search = Access::search(state);
    auto plan = Access::mode(state).search(message.matches, grid, search.origin);

    search.truncated = message.truncated;
    search.request = 0;

    return plan;
  }

  void finishSearch(State& state) noexcept {
    Access::search(state).origin.reset();
  }

  CopySearchState search(const State& state) noexcept {
    const auto& mode = Access::mode(state);
    const auto& search = Access::search(state);
    const auto& current = mode.state();

    return {.query = search.query, .searching = search.request != 0, .count = mode.matches().size(), .index = current ? std::size_t{current->match_index} : std::size_t{0}, .truncated = search.truncated};
  }

  ds::Option<std::size_t> searchBlock(const State& state) noexcept {
    const auto& search = Access::search(state);

    return search.rows && search.scoped ? ds::Option{search.rows->block} : ds::none;
  }

  bool searchScopes(const State& state, bool reads_rows) noexcept {
    return Access::search(state).rows.hasValue() && reads_rows;
  }

  void toggleSearchScope(State& state, bool reads_rows) noexcept {
    if (searchScopes(state, reads_rows)) {
      auto& search = Access::search(state);

      search.scoped = !search.scoped;
    }
  }

  bool takeSearchRequest(State& state) noexcept {
    return std::exchange(Access::search(state).requested, false);
  }

}
