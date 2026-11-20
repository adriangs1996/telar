module;
#include "tbc/annotations.hpp"

// Copy mode's state machine: the keys that move its cursor and the plans it commits. Nothing
// here is exported: only the feature's own units name it, through State.
export module telar.gui.features.terminal.copy_mode:mode;

import std;
import telar.tbc;

import :state;
import :pointer;
import :plan;
import telar.gui.foundation.keys;
import telar.gui.foundation.terminal;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::features::terminal::copy_mode {

  class CopyNavigation {
  public:
    static CopyEffect apply(CopyState& state, const TerminalKey& key, const CopyGrid& grid, std::span<const PaneMatch> matches) noexcept;

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

    static Command command(const TerminalKey& key) noexcept;

    static Command characterCommand(const TerminalKey& key) noexcept;

    static bool move(CopyState& state, Command action, const CopyGrid& grid) noexcept;

    static void nonBlank(CopyState& state, const CopyGrid& grid, bool last) noexcept;

    static CopyPoint firstAfterClass(CopyPoint point, CopyWordClass category, const CopyGrid& grid) noexcept;

    static CopyPoint lastInClass(CopyPoint point, CopyWordClass category, const CopyGrid& grid, CopyDirection direction) noexcept;

    static void wordForward(CopyState& state, const CopyGrid& grid, bool end) noexcept;

    static void wordBackward(CopyState& state, const CopyGrid& grid) noexcept;

    static void paragraph(CopyState& state, const CopyGrid& grid, CopyDirection direction) noexcept;

    static void cycleMatch(CopyState& state, std::span<const PaneMatch> matches, const CopyGrid& grid, bool forward) noexcept;
  };

  class CopyMode {
  public:
    static constexpr std::size_t maximum_matches = 256;

    [[nodiscard]] const ds::Option<CopyState>& state() const noexcept;

    [[nodiscard]] bool active() const noexcept;

    [[nodiscard]] std::uint64_t revision() const noexcept;

    [[nodiscard]] ds::Option<CopyPointerOwner> pointerOwner() const noexcept;

    bool beginPointer(CopyPress press, const CopyGrid& grid) noexcept;

    [[nodiscard]] tbc::val_static<ds::Option<CopyPlan>> pointer(CopyPoint local, const CopyGrid& grid, bool released) const noexcept;

    bool clearPointer() noexcept;

    void finishPointer() noexcept;

    [[nodiscard]] std::span<const PaneMatch> matches() const noexcept;

    bool enter(std::uint64_t pane_id, const CopyGrid& grid, const Cursor& cursor) noexcept;

    // Enters at `cursor`, from the top of the scrollback, already selecting from `anchor` when
    // one is given: a command block's text, picked from telar's editor.
    bool enterAt(std::uint64_t pane_id, const CopyGrid& grid, CopyPoint cursor, ds::Option<CopyPoint> anchor, bool linewise) noexcept;

    [[nodiscard]] tbc::val_static<ds::Option<CopyPlan>> key(const TerminalKey& key, const CopyGrid& grid) const noexcept;

    [[nodiscard]] tbc::val_static<ds::Option<CopyPlan>> vertical(std::int32_t rows, const CopyGrid& grid) const noexcept;

    [[nodiscard]] tbc::val_static<CopyPlan> leave(const CopyGrid& grid) const noexcept;

    [[nodiscard]] bool current(const CopyPlan& plan) const noexcept;

    bool commit(const CopyPlan& plan) noexcept;

    // The plan's replacement matches view the results, region `a`, until it is applied. From
    // `origin`, a search typed a letter at a time starts where it began, and comes back there
    // when nothing matches.
    [[nodiscard]] tbc::val_a<ds::Option<CopyPlan>> search(tbc::val_a<std::span<const PaneMatch>> results, const CopyGrid& grid, ds::Option<CopyPoint> origin = ds::none) const;

    void onFrame(std::uint32_t previous_offset, const CopyGrid& grid) noexcept;

    void reset() noexcept;

  private:
    [[nodiscard]] ds::Option<SetPaneViewport> viewport(std::uint32_t offset, const CopyGrid& grid) const noexcept;

    [[nodiscard]] tbc::val_static<CopyPlan> plan(CopyState next, const CopyGrid& grid, CopyEffect effect = {}) const noexcept;

    ds::Option<CopyState> state_;
    ds::Array<PaneMatch, maximum_matches> matches_{};
    std::size_t match_count_ = 0;
    std::uint64_t revision_ = 0;
    ClickTracker clicks_;
    std::uint64_t click_pane_ = 0;
    ds::Option<std::uint64_t> gesture_;
  };

  // The search of copy mode: the request in flight, the command output it may be confined to,
  // where the search being typed began, what it looks for, and whether its answer kept fewer
  // matches than it found.
  struct CopySearch {
    explicit CopySearch(Memory& memory);

    std::uint64_t request = 0;
    ds::Option<CopySearchRows> rows;
    ds::Option<CopyPoint> origin;
    ds::String<Memory> query;
    bool truncated = false;
    bool scoped = false;
    // A command asked for the scrollback search.
    bool requested = false;
  };

}
