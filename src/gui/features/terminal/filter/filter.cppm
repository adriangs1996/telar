module;

// The filter of a command's output, as less's `&` and Warp's block filter: only the lines that
// match a pattern, and the lines around them, are shown. The rows are read once each as they
// settle, from the screen or asked of the runtime, and the last ones again whenever they change
// while the command still prints.
export module telar.gui.features.terminal.filter;

// Exported as every interface partition must be; it exports nothing.
export import :lines;

import std;
import telar.tbc;

import telar.gui.foundation.terminal;
import telar.base.text.pattern;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::filter {

  struct Access;
  struct Steps;

}

export namespace telar::gui::features::terminal::filter {

  inline constexpr std::size_t maximum_context = 20;
  inline constexpr std::size_t maximum_query_bytes = runtime::Pattern::maximum_pattern_bytes;

  // What a person asked to see: the lines `text` is found in, as a regular expression or as it
  // is, its letters in either case or not; or, inverted, the lines it is not found in; and
  // `context` lines around each.
  struct Query {
    std::string_view text;
    bool regex = false;
    bool ignore_case = false;
    bool invert = false;
    std::uint8_t context = 0;
  };

  // A block's output as the filter reads it, by stable row: from `first` up to `end`, the rows
  // before `settled` no longer changing, and those from `screen` on held by the pane's screen,
  // which the runtime is not asked for.
  struct Extent {
    std::uint64_t first = 0;
    std::uint64_t end = 0;
    std::uint64_t settled = 0;
    std::uint64_t screen = std::numeric_limits<std::uint64_t>::max();
  };

  // The rows a pane's screen holds, the first at stable row `first`; `revision` changes whenever
  // any of them does.
  struct ScreenRows {
    std::uint64_t first = 0;
    std::uint16_t columns = 0;
    std::span<const CellValue> cells;
    std::span<const Byte> flags;
    std::uint64_t revision = 0;
  };

  // Rows to ask the runtime for, from stable row `from`.
  struct RowRequest {
    std::uint64_t from = 0;
    std::uint16_t count = 0;
  };

  // A match drawn on a row: `length` columns from `column`.
  struct Mark {
    std::uint16_t column = 0;
    std::uint16_t length = 0;
  };

  // Where a filter stands, for the bar that shows it: its pane and block, what it was asked,
  // the lines that matched, whether every row is read, whether what it keeps was cut at its
  // bounds, and why a pattern does not compile.
  struct Status {
    std::uint64_t pane_id = 0;
    std::uint64_t block = 0;
    std::string_view text;
    bool regex = false;
    bool ignore_case = false;
    bool invert = false;
    std::uint8_t context = 0;
    std::size_t matches = 0;
    bool complete = false;
    bool truncated = false;
    std::string_view error;
    // Counts the times the filter was asked to open, on its block again too, for its bar to take
    // the keys each time.
    std::uint64_t opened = 0;
  };

  // The filter the session shows, on one block at a time. Opaque: only the use cases below
  // reach it.
  class State {
    friend struct Access;
    friend struct Steps;

  public:
    // What it keeps lives in `memory`.
    explicit State(Memory& memory);

  private:
    Memory* memory_;
    bool open_ = false;
    std::uint64_t pane_id_ = 0;
    std::uint64_t block_ = 0;
    std::uint64_t top_ = 0;
    std::uint64_t opened_ = 0;
    // The query: its text, and how it reads it, `text` left empty.
    runtime::FixedText<maximum_query_bytes> text_;
    Query query_;
    const char* error_ = nullptr;
    ds::Option<ds::Box<runtime::Pattern, Memory>> pattern_;
    // The rows read for good, and those read again while they may change.
    Lines settled_;
    Lines tail_;
    std::uint64_t frontier_ = 0;
    // What the tail was read from, so that the same rows are not read again.
    std::uint64_t tail_revision_ = 0;
    std::uint64_t tail_frontier_ = 0;
    std::uint64_t tail_end_ = 0;
    ds::Option<std::uint64_t> request_;
    RowRequest asked_;
    Extent extent_;
    std::uint64_t revision_ = 0;
    ds::String<Memory> row_;
    ds::Vec<std::uint16_t, Memory> columns_;
  };

  // ---- opening and asking ----------------------------------------------------------------------

  // Where a filter opens: on the block of pane `pane_id` that `block` names by stable key, with
  // `top`, the view's top by stable row, where closing it takes the view back.
  struct Opening {
    std::uint64_t pane_id = 0;
    std::uint64_t block = 0;
    std::uint64_t top = 0;
  };

  // Opens the filter at `opening`, the output shown whole until a query is typed. Open on that
  // block already, it keeps its query and where it goes back.
  void open(State& state, const Opening& opening);

  // Filters by `query`, reading the output again. An empty query shows it whole; one that does
  // not compile shows it whole and says why, and false.
  bool query(State& state, const Query& query);

  // Closes the filter: the view's top to go back to, none when it was not open.
  ds::Option<std::uint64_t> close(State& state) noexcept;

  [[nodiscard]] bool open(const State& state) noexcept;

  // Whether the filter hides rows of pane `pane_id`'s block `block`.
  [[nodiscard]] bool filters(const State& state, std::uint64_t pane_id, std::uint64_t block) noexcept;

  [[nodiscard]] Status status(const State& state) noexcept;

  // Changes whenever the rows shown do.
  [[nodiscard]] std::uint64_t revision(const State& state) noexcept;

  // ---- reading the rows ----------------------------------------------------------------------

  // The rows to ask the runtime for next, settled ones not on the screen; none while a request
  // is out or none is left.
  [[nodiscard]] ds::Option<RowRequest> wanted(const State& state, const Extent& extent) noexcept;

  // Request `request_id` asks for `rows`.
  void asked(State& state, std::uint64_t request_id, RowRequest rows) noexcept;

  // The runtime's rows: those of the filter's request are read, as far as they are settled.
  // False for a reply that is not the filter's.
  bool receive(State& state, const PaneRows& reply, const Extent& extent);

  // The request `request_id` failed; false when it is not the filter's.
  bool fail(State& state, std::uint64_t request_id) noexcept;

  // The rows the screen holds: the settled ones next in order are read for good, and the rest of
  // the output on it again whenever they changed. True when what is shown changed.
  bool screen(State& state, const ScreenRows& rows, const Extent& extent);

  // The output's rows moved to `extent`, as rows above it dropped or the command went on: what
  // is shown is the same rows, by stable number.
  void follow(State& state, const Extent& extent) noexcept;

  // ---- what is shown -------------------------------------------------------------------------

  // Calls `hide(first, end)` with each run of the output's rows, by stable row, that the filter
  // hides: the lines that do not match, past a match's context, and the rows not read yet.
  // Generic over the caller's callable, so it stays here.
  template <typename Hide>
  [[tbc::generic]] void hidden(const State& state, const Extent& extent, Hide hide);

  // The lines shown, one after another, for a copy of the output.
  void copy(const State& state, ds::String<Memory>& text);

  // The matches on a row of `cells`, into `marks`; how many. None while the filter is inverted.
  [[nodiscard]] std::size_t highlight(State& state, std::span<const CellValue> cells, std::span<Mark> marks);

}

namespace telar::gui::features::terminal::filter {

  struct Access {
    [[nodiscard]] [[tbc::hot_path]] static inline bool filtering(const State& state) noexcept {
      return state.open_ && state.pattern_.hasValue();
    }

    [[nodiscard]] [[tbc::hot_path]] static inline std::span<const ShownRun> settled(const State& state) noexcept {
      return state.settled_.runs();
    }

    [[nodiscard]] [[tbc::hot_path]] static inline std::span<const ShownRun> tail(const State& state) noexcept {
      return state.tail_.runs();
    }
  };

}

export namespace telar::gui::features::terminal::filter {

  template <typename Hide>
  [[tbc::generic]] void hidden(const State& state, const Extent& extent, Hide hide) {
    if (!Access::filtering(state)) {
      return;
    }

    auto cursor = extent.first;
    const auto shown = [&](std::span<const ShownRun> runs) {
      for (const auto& run : runs) {
        const auto first = std::max(run.first, extent.first);
        const auto end = std::min(run.end, extent.end);
        if (first >= end) {
          continue;
        }

        if (first > cursor) {
          hide(cursor, first);
        }

        cursor = std::max(cursor, end);
      }
    };

    shown(Access::settled(state));
    shown(Access::tail(state));
    if (cursor < extent.end) {
      hide(cursor, extent.end);
    }
  }

}
