module;
#include "tbc/annotations.hpp"

// Copy mode in a terminal: entering it at the cursor or on a command's output, moving its cursor
// and selection with keys and the pointer, searching the scrollback, and leaving it.
export module telar.gui.features.terminal.copy_mode;

export import :state;
export import :pointer;
export import :plan;
// Exported as every interface partition must be; it exports nothing.
export import :mode;

import std;
import telar.tbc;

import telar.gui.foundation.keys;
import telar.gui.foundation.terminal;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::copy_mode {

  struct Access;

}

export namespace telar::gui::features::terminal::copy_mode {

  // Copy mode's state machine and its search: what is searched, from where, and the request in
  // flight. Opaque: only the use cases below reach it.
  class State {
    friend struct Access;

    CopyMode mode_;
    CopySearch search_;
  };

  // What ui reads of copy mode: a view of the state, valid until a use case changes it. Inline,
  // as a terminal reads it on every frame.
  class CopyModeView {
  public:
    static constexpr std::size_t maximum_matches = CopyMode::maximum_matches;

    inline explicit CopyModeView(const CopyMode& mode) noexcept
        : mode_(&mode) {}

    [[nodiscard]] TBC_HOT_PATH inline const ds::Option<CopyState>& state() const noexcept {
      return mode_->state();
    }

    [[nodiscard]] TBC_HOT_PATH inline bool active() const noexcept {
      return mode_->active();
    }

    [[nodiscard]] TBC_HOT_PATH inline std::uint64_t revision() const noexcept {
      return mode_->revision();
    }

    [[nodiscard]] TBC_HOT_PATH inline ds::Option<CopyPointerOwner> pointerOwner() const noexcept {
      return mode_->pointerOwner();
    }

    [[nodiscard]] TBC_HOT_PATH inline std::span<const PaneMatch> matches() const noexcept {
      return mode_->matches();
    }

  private:
    const CopyMode* mode_;
  };

  [[nodiscard]] inline CopyModeView view(const State& state) noexcept;

  // ---- entering and leaving ---------------------------------------------------------------------

  // Copy mode on pane `pane_id` at its cursor, or at the view's last row when the cursor hides;
  // false while it is on or the grid is empty.
  bool enter(State& state, std::uint64_t pane_id, const CopyGrid& grid, const Cursor& cursor) noexcept;

  // Copy mode at `cursor`, already selecting from `anchor` when one is given: a command block's
  // text, picked from telar's editor.
  bool select(State& state, std::uint64_t pane_id, const CopyGrid& grid, CopyPoint cursor, ds::Option<CopyPoint> anchor, bool linewise) noexcept;

  // Copy mode at the first row of a command's output, the scrollback search asked for and,
  // `scoped`, confined to `rows`.
  bool searchOutput(State& state, std::uint64_t pane_id, const CopyGrid& grid, CopySearchRows rows, bool scoped) noexcept;

  // The plan that leaves copy mode where it was entered.
  [[nodiscard]] CopyPlan leave(const State& state, const CopyGrid& grid) noexcept;

  // Copy mode ends without a pane to leave: its pane went away or another tab shows.
  void close(State& state) noexcept;

  // The search is forgotten, as leaving copy mode forgets it.
  void forget(State& state) noexcept;

  // ---- keys and the pointer ---------------------------------------------------------------------

  // The plan a key asks for; none when copy mode does not take keys. A key that begins a search
  // begins it from where the cursor is now.
  [[nodiscard]] TBC_HOT_PATH inline ds::Option<CopyPlan> key(State& state, const TerminalKey& key, const CopyGrid& grid);

  // A press at `press.position` selects from there, a word or a line on a second or third click.
  TBC_HOT_PATH inline bool press(State& state, CopyPress press, const CopyGrid& grid) noexcept;

  // The plan a drag to `local` asks for, ending the gesture when `released`.
  [[nodiscard]] TBC_HOT_PATH inline ds::Option<CopyPlan> drag(const State& state, CopyPoint local, const CopyGrid& grid, bool released) noexcept;

  // The plan a wheel step of `rows` asks for.
  [[nodiscard]] TBC_HOT_PATH inline ds::Option<CopyPlan> scroll(const State& state, std::int32_t rows, const CopyGrid& grid) noexcept;

  // Typing drops a selection the pointer made; false when there was none.
  TBC_HOT_PATH inline bool clearPointer(State& state) noexcept;

  // The pointer let go: its gesture ends.
  TBC_HOT_PATH inline void release(State& state) noexcept;

  // ---- plans --------------------------------------------------------------------------------------

  // Whether `plan` was made from copy mode as it stands.
  [[nodiscard]] TBC_HOT_PATH inline bool current(const State& state, const CopyPlan& plan) noexcept;

  // Copy mode becomes what `plan` leads to; false when it is no longer current.
  TBC_HOT_PATH inline bool commit(State& state, const CopyPlan& plan) noexcept;

  // A frame of copy mode's pane arrived, its view at `previous_offset` before it: the cursor and
  // selection follow the rows the scrollback dropped.
  TBC_HOT_PATH inline void follow(State& state, std::uint32_t previous_offset, const CopyGrid& grid) noexcept;

  // ---- the search ---------------------------------------------------------------------------------

  // The search typed so far is `needle`; it begins where the first letter found the cursor. With
  // nothing to look for, the plan back to where it began, and no answer awaited.
  [[nodiscard]] ds::Option<CopyPlan> type(State& state, std::string_view needle, const CopyGrid& grid);

  // The search of pane `pane_id` under `request_id`: through a command's output when it is
  // confined there and the runtime reads rows, else through the whole scrollback. The request
  // views the needle typed until the next use case.
  [[nodiscard]] std::variant<SearchPane, SearchPaneRows> request(State& state, std::uint64_t pane_id, std::uint64_t request_id, bool reads_rows) noexcept;

  // Request `request_id` could not be sent: no answer is awaited.
  void fail(State& state, std::uint64_t request_id) noexcept;

  // Whether `message` answers the search awaited for the pane copy mode is on.
  [[nodiscard]] bool awaits(const State& state, const PaneMatches& message) noexcept;

  // The matches arrived: the plan that takes the cursor to the first, which views them.
  [[nodiscard]] ds::Option<CopyPlan> receive(State& state, const PaneMatches& message, const CopyGrid& grid);

  // The search typed so far ends: its matches stay for n and N, from wherever they took the
  // cursor.
  void finishSearch(State& state) noexcept;

  [[nodiscard]] CopySearchState search(const State& state) noexcept;

  // The command whose output the search reads, while it reads only that output.
  [[nodiscard]] ds::Option<std::size_t> searchBlock(const State& state) noexcept;

  // Whether a search can be confined to a command's output, as one begun from a command can.
  [[nodiscard]] bool searchScopes(const State& state, bool reads_rows) noexcept;

  // Between that command's output and the whole scrollback.
  void toggleSearchScope(State& state, bool reads_rows) noexcept;

  // Whether a command asked for the scrollback search since the last call.
  [[nodiscard]] bool takeSearchRequest(State& state) noexcept;

}

namespace telar::gui::features::terminal::copy_mode {

  // The use cases' way into State.
  struct Access {
    [[nodiscard]] static constexpr CopyMode& mode(State& state) noexcept {
      return state.mode_;
    }

    [[nodiscard]] static constexpr const CopyMode& mode(const State& state) noexcept {
      return state.mode_;
    }

    [[nodiscard]] static constexpr CopySearch& search(State& state) noexcept {
      return state.search_;
    }

    [[nodiscard]] static constexpr const CopySearch& search(const State& state) noexcept {
      return state.search_;
    }
  };

  inline CopyModeView view(const State& state) noexcept {
    return CopyModeView{Access::mode(state)};
  }

  inline bool clearPointer(State& state) noexcept {
    return Access::mode(state).clearPointer();
  }

  inline void follow(State& state, std::uint32_t previous_offset, const CopyGrid& grid) noexcept {
    Access::mode(state).onFrame(previous_offset, grid);
  }

  inline ds::Option<CopyPlan> key(State& state, const TerminalKey& key, const CopyGrid& grid) {
    auto plan = Access::mode(state).key(key, grid);
    if (plan && plan->effect.search) {
      auto& search = Access::search(state);

      search.origin.reset();
      search.query.clear();
    }

    return plan;
  }

  inline bool press(State& state, CopyPress press, const CopyGrid& grid) noexcept {
    return Access::mode(state).beginPointer(press, grid);
  }

  inline ds::Option<CopyPlan> drag(const State& state, CopyPoint local, const CopyGrid& grid, bool released) noexcept {
    return Access::mode(state).pointer(local, grid, released);
  }

  inline ds::Option<CopyPlan> scroll(const State& state, std::int32_t rows, const CopyGrid& grid) noexcept {
    return Access::mode(state).vertical(rows, grid);
  }

  inline void release(State& state) noexcept {
    Access::mode(state).finishPointer();
  }

  inline bool current(const State& state, const CopyPlan& plan) noexcept {
    return Access::mode(state).current(plan);
  }

  inline bool commit(State& state, const CopyPlan& plan) noexcept {
    return Access::mode(state).commit(plan);
  }

}
